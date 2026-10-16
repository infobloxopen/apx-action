#!/usr/bin/env bats
#
# Unit tests for scripts/apx-publish.sh — the publish-on-change engine.
#
# They exercise per-module format resolution, per-format emit dispatch, and the
# per-concern/format/module gate resolution, with apx / openapiv2to3 / make / curl
# replaced by the recording stubs under tests/stubs. Tests run against an empty
# canonical clone (drift = absent), mostly in `check` mode; the branch-routing
# tests also drive `publish` (github forge), where the stubs stand in for
# `apx release prepare/submit` and the GitHub REST calls, so nothing is published.
# We assert on which tools ran (and with what args), on the summary table, and on
# where each spec was staged.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$ROOT/scripts/apx-publish.sh"

  # Stub bin ahead of PATH so apx/openapiv2to3/make resolve to the recorders;
  # yq/jq/git stay real.
  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  local s
  for s in apx openapiv2to3 make curl; do
    install -m 0755 "$ROOT/tests/stubs/$s" "$BIN/$s"
  done
  export PATH="$BIN:$PATH"

  export APX_TEST_LOG="$BATS_TEST_TMPDIR/tools.log"; : > "$APX_TEST_LOG"
  SUMMARY="$BATS_TEST_TMPDIR/summary.md"

  # Empty canonical clone: only needs a .git dir for the branch-routing probe.
  CANON="$BATS_TEST_TMPDIR/canon"
  git init -q "$CANON"

  # Deterministic branch routing (main channel, no pre-release ratchet).
  unset GITHUB_BASE_REF GITHUB_REF_NAME GITHUB_STEP_SUMMARY

  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK"
  cd "$WORK"
}

# --- helpers ----------------------------------------------------------------

run_check() {
  run "$SCRIPT" --mode check --config .apx-publish.yaml \
    --canonical-dir "$CANON" --summary "$SUMMARY" "$@"
}

# touch a file, creating parent dirs
mksrc() { mkdir -p "$(dirname "$1")"; : > "$1"; }

staged()  { echo "$WORK/build/apx-modules/$1"; }          # staged spec path for an id/name
log_has() { grep -Fq -- "$1" "$APX_TEST_LOG"; }
log_count() { grep -Fc -- "$1" "$APX_TEST_LOG" || true; }
summary_has() { grep -Fq -- "$1" "$SUMMARY"; }

assert_ok() {
  [ "$status" -eq 0 ] || { echo "expected exit 0, got $status"; echo "--- output ---"; echo "$output"; return 1; }
}

# --- tests ------------------------------------------------------------------

@test "openapi: format inferred from id; converts and stages, make skipped on cache hit" {
  cat > .apx-publish.yaml <<'YAML'
canonical_repo: github.com/example/apis
modules:
  - id: openapi/csp.infoblox.com/identity/v2
    swagger: pkg/v2/identity.swagger.json
    fds: api-v2.binpb
    audience: public
YAML
  mksrc pkg/v2/identity.swagger.json
  mksrc api-v2.binpb          # FDS present → cache hit → make must NOT run

  run_check --verify-clients warn
  assert_ok

  log_has "openapiv2to3 -descriptor"                       # emit converted
  [ ! -f .make-ran ]                                       # make skipped (fds cached)
  [ -f "$(staged openapi/csp.infoblox.com/identity/v2/identity.yaml)" ]
  summary_has "| openapi |"
}

@test "openapi back-compat: missing FDS triggers make, then converts" {
  cat > .apx-publish.yaml <<'YAML'
canonical_repo: github.com/example/apis
modules:
  - id: openapi/csp.infoblox.com/identity/v2
    swagger: pkg/v2/identity.swagger.json
    fds: api-v2.binpb
    audience: public
YAML
  mksrc pkg/v2/identity.swagger.json
  # FDS intentionally absent → make stub runs and creates it

  run_check --verify-clients warn
  assert_ok

  [ -f .make-ran ]                                         # make ran (cache miss)
  log_has "make fds"
  log_has "openapiv2to3 -descriptor"
  [ -f "$(staged openapi/csp.infoblox.com/identity/v2/identity.yaml)" ]
}

@test "explicit format: overrides the id root segment" {
  cat > .apx-publish.yaml <<'YAML'
canonical_repo: github.com/example/apis
modules:
  - id: openapi/csp.infoblox.com/thing/v1     # id root says openapi …
    format: jsonschema                        # … but the explicit format wins
    jsonschema: schema/thing.json
YAML
  mksrc schema/thing.json

  run_check --verify-clients warn
  assert_ok

  [ -z "$(log_count 'openapiv2to3')" ] || [ "$(log_count 'openapiv2to3')" -eq 0 ]  # no conversion
  [ ! -f .make-ran ]                                       # no make
  [ -f "$(staged openapi/csp.infoblox.com/thing/v1/thing.json)" ]   # staged as jsonschema
  summary_has "| jsonschema |"
}

@test "crd: no make/convert, staged verbatim, verify runs (client format)" {
  cat > .apx-publish.yaml <<'YAML'
canonical_repo: github.com/example/apis
modules:
  - id: crd/csp.platform.infoblox.com/cspaccountclaim/v1alpha1
    crd: config/crd/bases/cspaccountclaim.yaml
YAML
  mksrc config/crd/bases/cspaccountclaim.yaml

  run_check --verify-clients warn
  assert_ok

  [ ! -f .make-ran ]                                       # crd never compiles an FDS
  [ "$(log_count 'openapiv2to3')" -eq 0 ]                  # no conversion
  [ -f "$(staged crd/csp.platform.infoblox.com/cspaccountclaim/v1alpha1/cspaccountclaim.yaml)" ]
  log_has "client verify"                                  # crd IS a client format → gate runs
  summary_has "| crd |"
}

@test "jsonschema: no convert, staged as .json, verify skipped by default" {
  cat > .apx-publish.yaml <<'YAML'
canonical_repo: github.com/example/apis
modules:
  - id: jsonschema/csp.infoblox.com/audit-log/v1
    jsonschema: schema/AuditLog.json
YAML
  mksrc schema/AuditLog.json

  run_check --verify-clients warn
  assert_ok

  [ "$(log_count 'openapiv2to3')" -eq 0 ]
  [ ! -f .make-ran ]
  [ -f "$(staged jsonschema/csp.infoblox.com/audit-log/v1/audit-log.json)" ]
  [ "$(log_count 'client verify')" -eq 0 ]                 # non-client format → gate off by default
  summary_has "| jsonschema |"
}

@test "verify-clients precedence: module field beats formats.<fmt> default" {
  cat > .apx-publish.yaml <<'YAML'
canonical_repo: github.com/example/apis
formats:
  jsonschema:
    verify_clients: warn        # turn the gate ON for all jsonschema modules …
modules:
  - id: jsonschema/csp.infoblox.com/on-schema/v1
    jsonschema: schema/on.json
  - id: jsonschema/csp.infoblox.com/off-schema/v1
    jsonschema: schema/off.json
    verify_clients: off         # … except this one (module overrides format)
YAML
  mksrc schema/on.json
  mksrc schema/off.json

  run_check --verify-clients warn
  assert_ok

  log_has "on-schema/v1/on-schema.json"                    # format-level warn → verify ran
  run grep -F "off-schema/v1/off-schema.json" "$APX_TEST_LOG"
  [ "$status" -ne 0 ]                                      # module-level off → verify did NOT run
}

@test "mixed-format repo: one run emits each format; make once, verify only where applicable" {
  cat > .apx-publish.yaml <<'YAML'
canonical_repo: github.com/example/apis
modules:
  - id: openapi/csp.infoblox.com/identity/v2
    swagger: pkg/v2/identity.swagger.json
    fds: api-v2.binpb
    audience: public
  - id: crd/csp.platform.infoblox.com/cspaccountclaim/v1alpha1
    crd: config/crd/bases/cspaccountclaim.yaml
  - id: jsonschema/csp.infoblox.com/audit-log/v1
    jsonschema: schema/AuditLog.json
YAML
  mksrc pkg/v2/identity.swagger.json
  mksrc config/crd/bases/cspaccountclaim.yaml
  mksrc schema/AuditLog.json
  # openapi FDS absent → make runs exactly once for the whole run

  run_check --verify-clients warn
  assert_ok

  [ "$(log_count 'make fds')" -eq 1 ]                      # a single make for the fds-bearing module
  [ "$(log_count 'openapiv2to3 -descriptor')" -eq 1 ]      # only the openapi module converts
  [ -f "$(staged openapi/csp.infoblox.com/identity/v2/identity.yaml)" ]
  [ -f "$(staged crd/csp.platform.infoblox.com/cspaccountclaim/v1alpha1/cspaccountclaim.yaml)" ]
  [ -f "$(staged jsonschema/csp.infoblox.com/audit-log/v1/audit-log.json)" ]
  log_has "identity/v2/identity.yaml"                      # openapi client verified
  log_has "cspaccountclaim/v1alpha1/cspaccountclaim.yaml" # crd client verified
  [ "$(log_count 'audit-log/v1/audit-log.json')" -eq 0 ]  # jsonschema client gate off
}

@test "unknown format is rejected" {
  cat > .apx-publish.yaml <<'YAML'
canonical_repo: github.com/example/apis
modules:
  - id: bogus/csp.infoblox.com/thing/v1
    bogus: thing.dat
YAML
  run_check
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "unknown format 'bogus'"
}

# --- branch routing: .apx-publish.yaml branch_targets drives apx --------------

@test "publish (github): prepare targets the engine's branch_targets base, not apx's own default" {
  # main → develop: the engine compares/versions against develop, so the release
  # manifest (and thus `apx release submit`) must target develop too.
  cat > .apx-publish.yaml <<'YAML'
canonical_repo: github.com/example/apis
branch_targets:
  main: develop
modules:
  - id: jsonschema/csp.infoblox.com/audit-log/v1
    jsonschema: schema/AuditLog.json
YAML
  mksrc schema/AuditLog.json

  GITHUB_REF_NAME=main GITHUB_TOKEN=test-token \
    run "$SCRIPT" --mode publish --config .apx-publish.yaml \
      --canonical-dir "$CANON" --summary "$SUMMARY" --verify-clients off
  assert_ok

  log_has "apx release prepare jsonschema/csp.infoblox.com/audit-log/v1 --version v1.0.0-beta.1 --lifecycle beta"
  log_has "--source-branch main --base-branch develop"
  log_has "apx release submit"
  summary_has "base \`develop\`"
}

@test "publish (github): default routing passes base main for a main push" {
  cat > .apx-publish.yaml <<'YAML'
canonical_repo: github.com/example/apis
modules:
  - id: jsonschema/csp.infoblox.com/audit-log/v1
    jsonschema: schema/AuditLog.json
YAML
  mksrc schema/AuditLog.json

  GITHUB_REF_NAME=main GITHUB_TOKEN=test-token \
    run "$SCRIPT" --mode publish --config .apx-publish.yaml \
      --canonical-dir "$CANON" --summary "$SUMMARY" --verify-clients off
  assert_ok

  log_has "apx release prepare jsonschema/csp.infoblox.com/audit-log/v1 --version v1.0.0 --lifecycle stable"
  log_has "--source-branch main --base-branch main"
  run grep -F -- "--encode-commit-hash" "$APX_TEST_LOG"
  [ "$status" -ne 0 ]                                      # stable channel: no hash encoding
}

@test "check: the pre-release ratchet dry-run uses the engine's branch_targets base" {
  cat > .apx-publish.yaml <<'YAML'
canonical_repo: github.com/example/apis
branch_targets:
  main: develop
modules:
  - id: jsonschema/csp.infoblox.com/audit-log/v1
    jsonschema: schema/AuditLog.json
YAML
  mksrc schema/AuditLog.json

  GITHUB_BASE_REF=main run_check --verify-clients off
  assert_ok

  log_has "--source-branch main --base-branch develop --encode-commit-hash"
  log_has "--dry-run"
}
