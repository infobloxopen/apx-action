#!/usr/bin/env bash
#
# apx-publish.sh — orchestrate the apx publish-on-change pipeline for one repo.
#
# This is the reusable engine behind .github/workflows/apx-publish.yml. It runs
# identically in GitHub CI and locally (the pilot exercises it against a local
# Gitea sandbox). It ONLY orchestrates — apx owns the lifecycle, devedge-sdk owns
# the conversion. Pipeline per the WS-035 / ARCH-271 design:
#
#   make <fds_target>                       # repo's own gentool: --descriptor_set_out --include_imports
#   openapiv2to3 -descriptor <fds> <swagger> <out>   # enriched OpenAPI v3 (tolerant matching = default)
#   apx release status <id> --canonical-dir <clone>  # drift: unchanged | changed | absent
#   apx breaking <new> --against <published> [--advisory]  # public=blocking, internal=advisory
#   apx pathlint --ingress <rendered> --spec <specs> --warn-only    # R4 metric, never a gate
#   (publish mode) apx release prepare/submit -> open PR + drift issue
#
# Config is the repo's .apx-publish.yaml (see the pilot at athena-identity-service).
#
# Usage:
#   apx-publish.sh --mode check|publish [options]
#
# Options:
#   --mode check|publish     check = PR CI (report only); publish = on-merge (open PR+issue). Required.
#   --config <path>          per-repo config (default .apx-publish.yaml)
#   --module-root <dir>      where converted specs are staged; must be an apx.yaml
#                            module_root so `apx release status` resolves them
#                            (default build/apx-modules)
#   --canonical-dir <dir>    a local clone of the canonical catalog (read for drift/
#                            breaking, written for a gitea publish). Required.
#   --breaking-gate MODE     auto|advisory|blocking (default auto: public blocks,
#                            internal advisory)
#   --pathlint-ingress <f>   pre-rendered ingress manifest for pathlint (optional)
#   --auto-merge             (gitea, sandbox only) merge the publish PR + finalize,
#                            to demonstrate the catalog updating end to end
#   --summary <file>         markdown summary sink (default $GITHUB_STEP_SUMMARY or stdout)
#
# Gitea publish reads these env vars (as the ws035 runbook did):
#   GITEA_URL GITEA_ORG GITEA_USER GITEA_PASSWORD GITEA_TOKEN
# GitHub publish uses GITHUB_TOKEN via `apx release submit`.
set -euo pipefail

MODE=""
CONFIG=".apx-publish.yaml"
MODULE_ROOT="build/apx-modules"
CANONICAL_DIR=""
BREAKING_GATE="auto"
VERIFY_CLIENTS="fail"
SUPERSEDE="on"
PATHLINT_INGRESS=""
AUTO_MERGE=0
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --module-root) MODULE_ROOT="$2"; shift 2 ;;
    --canonical-dir) CANONICAL_DIR="$2"; shift 2 ;;
    --breaking-gate) BREAKING_GATE="$2"; shift 2 ;;
    --verify-clients) VERIFY_CLIENTS="$2"; shift 2 ;;
    --supersede) SUPERSEDE="$2"; shift 2 ;;
    --pathlint-ingress) PATHLINT_INGRESS="$2"; shift 2 ;;
    --auto-merge) AUTO_MERGE=1; shift ;;
    --summary) SUMMARY="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ "$MODE" == "check" || "$MODE" == "publish" ]] || { echo "--mode check|publish is required" >&2; exit 2; }
[[ -n "$CANONICAL_DIR" ]] || { echo "--canonical-dir is required" >&2; exit 2; }
[[ -f "$CONFIG" ]] || { echo "config not found: $CONFIG" >&2; exit 2; }
command -v yq  >/dev/null || { echo "yq (mikefarah v4) is required" >&2; exit 2; }
command -v jq  >/dev/null || { echo "jq is required" >&2; exit 2; }
command -v apx >/dev/null || { echo "apx is required on PATH" >&2; exit 2; }

log()  { echo "==> $*" >&2; }
note() { echo "$*" >> "$SUMMARY"; }

# Superseded-PR cleanup (CICD-1378) lives in a sibling helper so it can be unit-
# tested in isolation. Source it after log()/note() so it reuses them.
_APX_PUBLISH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/supersede.sh
source "$_APX_PUBLISH_DIR/supersede.sh"

# ── Config ──────────────────────────────────────────────────────────────────
CANONICAL_REPO=$(yq -r '.canonical_repo' "$CONFIG")
FORGE=$(yq -r '.forge // "github"' "$CONFIG")
FDS_TARGET=$(yq -r '.fds_target // "fds"' "$CONFIG")
CONVERTER_VERSION=$(yq -r '.converter_version // "v0.60.0"' "$CONFIG")
VERSION_BUMP=$(yq -r '.version_bump // "minor"' "$CONFIG")
PATHLINT_CHART=$(yq -r '.pathlint.chart // ""' "$CONFIG")
PATHLINT_RELEASE=$(yq -r '.pathlint.release_name // "release"' "$CONFIG")
NMODULES=$(yq -r '.modules | length' "$CONFIG")

# Superseded-PR cleanup (CICD-1378): the label applied to auto-closed prior PRs.
SUPERSEDE_LABEL=$(yq -r '.supersede.label // "superseded"' "$CONFIG")

# Client-build gate (apx client verify): which generators to build+compile per
# module. Default: go (the SDK the reserved-identifier / redundant-param hazards
# break). Override per repo via .apx-publish.yaml `verify_clients.generators`.
mapfile -t VERIFY_GENERATORS < <(yq -r '.verify_clients.generators[]?' "$CONFIG")
[[ ${#VERIFY_GENERATORS[@]} -gt 0 ]] || VERIFY_GENERATORS=(go)

# ── Formats ───────────────────────────────────────────────────────────────────
# apx models six schema formats; publish-on-change emits, validates, and publishes
# each module per its own format. A module's format is inferred from its id's first
# segment (openapi/csp.infoblox.com/… → openapi) unless it declares `format:`.
# Only `openapi` runs the OpenAPI toolchain (make fds → openapiv2to3); the others
# use their source files directly. The catalog path is the id, so a module lands
# under its format's subtree (/openapi, /crd, /jsonschema, …) by construction.
KNOWN_FORMATS="openapi proto crd avro jsonschema parquet"
is_known_format() { case " $KNOWN_FORMATS " in *" $1 "*) return 0;; *) return 1;; esac; }

# module_format <id> <explicit-or-empty> — explicit `format:` wins; else infer from
# the id's first segment.
module_format() {
  local id="$1" explicit="$2"
  if [[ -n "$explicit" && "$explicit" != "null" ]]; then echo "$explicit"; return; fi
  echo "${id%%/*}"
}

# format_needs_fds <fmt> — the emit step compiles a FileDescriptorSet (openapi's
# converter reads it; proto publishes it). crd/avro/jsonschema/parquet do not, so a
# repo without them never runs `make <fds_target>`.
format_needs_fds() { case "$1" in openapi|proto) return 0;; *) return 1;; esac; }

# format_generates_client <fmt> — an SDK is generated from this format, so it is a
# candidate for the verify-clients gate. Non-client formats default that gate off.
format_generates_client() { case "$1" in openapi|crd|proto) return 0;; *) return 1;; esac; }

# format_ext <fmt> — extension of the staged spec (and of the published spec the
# breaking check compares against). openapi/crd stage YAML; the rest keep native.
format_ext() {
  case "$1" in
    openapi|crd) echo yaml ;;
    jsonschema)  echo json ;;
    avro)        echo avsc ;;
    proto)       echo binpb ;;
    parquet)     echo parquet ;;
    *)           echo yaml ;;
  esac
}

# format_source_field <fmt> — the .apx-publish.yaml module field naming the format's
# source file (openapi additionally needs `swagger`; proto/openapi use `fds`).
format_source_field() {
  case "$1" in
    openapi)    echo swagger ;;
    crd)        echo crd ;;
    jsonschema) echo jsonschema ;;
    avro)       echo avro ;;
    parquet)    echo parquet ;;
    proto)      echo fds ;;
    *)          echo "" ;;
  esac
}

# has_format <fmt> — true if any configured module resolves to <fmt>.
has_format() {
  local want="$1" j id
  for ((j=0; j<NMODULES; j++)); do
    id=$(yq -r ".modules[$j].id" "$CONFIG")
    [[ "$(module_format "$id" "$(yq -r ".modules[$j].format // \"\"" "$CONFIG")")" == "$want" ]] && return 0
  done
  return 1
}

# resolve_gate <concern> <fmt> <module-index> — resolve a gate mode with precedence
#   module field  >  formats.<fmt>.<concern>  >  gates.<concern>  >  run default
# — configurable per concern / format / module, with good global defaults.
# For verify_clients the built-in default is client-aware: client-generating formats
# inherit the run default ($VERIFY_CLIENTS); non-client formats resolve to `off`
# unless explicitly overridden somewhere up the chain.
resolve_gate() {
  local concern="$1" fmt="$2" i="$3" v
  v=$(yq -r ".modules[$i].$concern // \"\"" "$CONFIG")
  [[ -n "$v" && "$v" != "null" ]] || v=$(yq -r ".formats.$fmt.$concern // \"\"" "$CONFIG")
  [[ -n "$v" && "$v" != "null" ]] || v=$(yq -r ".gates.$concern // \"\"" "$CONFIG")
  if [[ -z "$v" || "$v" == "null" ]]; then
    case "$concern" in
      breaking)       v="$BREAKING_GATE" ;;
      verify_clients) if format_generates_client "$fmt"; then v="$VERIFY_CLIENTS"; else v="off"; fi ;;
    esac
  fi
  echo "$v"
}

# resolve_generators <fmt> <module-index> — verify-clients generator matrix with the
# same precedence: module > formats.<fmt> > global verify_clients.generators (go).
resolve_generators() {
  local fmt="$1" i="$2"; local -a g
  mapfile -t g < <(yq -r ".modules[$i].generators[]?" "$CONFIG")
  [[ ${#g[@]} -gt 0 ]] || mapfile -t g < <(yq -r ".formats.$fmt.generators[]?" "$CONFIG")
  [[ ${#g[@]} -gt 0 ]] || g=("${VERIFY_GENERATORS[@]}")
  printf '%s\n' "${g[@]}"
}

# github.com-style NWO used by apx for identity/go-module derivation (even on gitea).
CANON_NWO=$(echo "$CANONICAL_REPO" | sed -E 's#^https?://##; s#\.git$##; s#^[^/]+/##')

# ── Branch routing (ARCH-271) ─────────────────────────────────────────────────
# Resolve the service repo's source branch → the canonical-repo base branch this
# run publishes to, from `.apx-publish.yaml` `branch_targets` (default:
# main/master→main, develop→develop; tweakable). A resolved base branch other
# than "main" is a PRE-RELEASE channel: apx publishes vX.Y.Z-beta.N versions that
# carry a short commit hash, and its ratchet keeps them above the line's GA.
default_base() { case "$1" in main|master) echo main;; develop) echo develop;; *) echo main;; esac; }
# Which branch drives channel routing depends on the event:
#   push (publish): GITHUB_REF_NAME is the pushed branch (develop/master) — the
#     branch whose merge just happened, so route on it directly.
#   pull_request (check): GITHUB_REF_NAME is the merge ref "<PR#>/merge", which
#     maps to no channel and would wrongly fall back to main — so prefer
#     GITHUB_BASE_REF, the branch the PR MERGES INTO. That is precisely the
#     branch whose post-merge push will trigger publish, so the check runs the
#     SAME channel (and, for develop, the AC-1 pre-release ratchet) as the
#     eventual publish — a true pre-merge gate rather than an always-main report.
SRC_BRANCH="${GITHUB_BASE_REF:-${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)}}"
BASE_BRANCH=$(yq -r ".branch_targets.\"$SRC_BRANCH\" // \"\"" "$CONFIG")
[[ -n "$BASE_BRANCH" && "$BASE_BRANCH" != "null" ]] || BASE_BRANCH=$(default_base "$SRC_BRANCH")
PRERELEASE=0; [[ "$BASE_BRANCH" != "main" ]] && PRERELEASE=1

# Compare drift/breaking against — and, on publish, target — the resolved base
# branch of the canonical clone. Best-effort: fall back to the default branch
# (with a warning) if the base branch does not exist there yet.
if [[ -n "$CANONICAL_DIR" && -d "$CANONICAL_DIR/.git" ]]; then
  if git -C "$CANONICAL_DIR" rev-parse --verify --quiet "origin/$BASE_BRANCH" >/dev/null 2>&1; then
    git -C "$CANONICAL_DIR" checkout -q -B "$BASE_BRANCH" "origin/$BASE_BRANCH" 2>/dev/null || \
      git -C "$CANONICAL_DIR" checkout -q "$BASE_BRANCH" 2>/dev/null || true
  elif [[ "$BASE_BRANCH" != "main" ]]; then
    log "WARNING: base branch '$BASE_BRANCH' not found in canonical clone — comparing/publishing against its default branch"
  fi
fi

log "mode=$MODE forge=$FORGE canonical=$CANONICAL_REPO modules=$NMODULES source=$SRC_BRANCH base=$BASE_BRANCH prerelease=$PRERELEASE"
note "## apx publish-on-change ($MODE)"
note ""
note "Canonical: \`$CANONICAL_REPO\` · forge: \`$FORGE\` · modules: $NMODULES"
note "Source branch: \`$SRC_BRANCH\` → base branch: \`$BASE_BRANCH\`$([[ "$PRERELEASE" == "1" ]] && echo ' (pre-release / beta channel)')"
note ""

# ── Client-build gate mode ────────────────────────────────────────────────────
# fail (default): generate an SDK from each converted spec and compile it; a spec
#   whose client does not build FAILS the run (in check AND publish) before any
#   publish PR is opened. warn: report only. off: skip. This makes an apx that
#   ships `apx client verify` a hard prerequisite of the toolchain image.
case "$VERIFY_CLIENTS" in
  fail|warn|off) : ;;
  "") VERIFY_CLIENTS="fail" ;;
  *) echo "invalid --verify-clients: $VERIFY_CLIENTS (fail|warn|off)" >&2; exit 2 ;;
esac
log "verify-clients=$VERIFY_CLIENTS generators=${VERIFY_GENERATORS[*]}"

# ── Superseded-PR cleanup mode (CICD-1378) ────────────────────────────────────
# on (default): after opening a new beta PR for a module, close any prior open
#   apx/release PR for the same module id + base branch (label + comment + delete
#   branch). off: leave prior PRs alone. github forge only; best-effort.
case "$SUPERSEDE" in
  on|off) : ;;
  *) echo "invalid --supersede: $SUPERSEDE (on|off)" >&2; exit 2 ;;
esac
log "supersede=$SUPERSEDE label=$SUPERSEDE_LABEL"

# ── openapiv2to3 (converter) ──────────────────────────────────────────────────
# Only the openapi emit step needs it — a crd/message-schema-only repo skips it.
if has_format openapi && ! command -v openapiv2to3 >/dev/null; then
  log "installing openapiv2to3 $CONVERTER_VERSION"
  go install "github.com/infobloxopen/devedge-sdk/cmd/openapiv2to3@${CONVERTER_VERSION}"
fi

# ── FileDescriptorSet(s) via the repo's own gentool ───────────────────────────
# The FDS is a pure function of the committed protos + the pinned gentool, so it
# is treated as a cached CI artifact (the caller keys a cache on the proto/Makefile
# hash), never committed to git. The repo's atlas-gentool `docker run` — the slow
# step — runs only when the cache did not restore every FDS the modules reference,
# i.e. only when a proto actually changed. On a cache hit this is skipped entirely.
# Only fds-bearing formats (openapi/proto) need it: a repo with just crd/message
# schemas never compiles a FileDescriptorSet, so `make <fds_target>` is skipped.
fds_needed=0 fds_missing=0
for ((i=0; i<NMODULES; i++)); do
  id=$(yq -r ".modules[$i].id" "$CONFIG")
  fmt=$(module_format "$id" "$(yq -r ".modules[$i].format // \"\"" "$CONFIG")")
  format_needs_fds "$fmt" || continue
  fds_needed=1
  f=$(yq -r ".modules[$i].fds // \"\"" "$CONFIG")
  [[ -n "$f" && "$f" != "null" && -f "$f" ]] || { fds_missing=1; break; }
done
if [[ "$fds_needed" -eq 0 ]]; then
  log "no fds-bearing modules (crd/message-schema only) — skipping 'make $FDS_TARGET'"
elif [[ "$fds_missing" -eq 1 ]]; then
  log "make $FDS_TARGET (FileDescriptorSet — cache miss / proto changed)"
  make "$FDS_TARGET"
else
  log "FileDescriptorSet(s) present (restored from cache) — skipping 'make $FDS_TARGET'"
fi

# module name = the <name> segment of format/domain/name/line
module_name() { echo "$1" | awk -F/ '{print $(NF-1)}'; }

# is_semver_line <line> — true for a plain major line like v1/v2 (openapi + message
# formats version with SemVer). K8s crd lines (v1alpha1/v1beta1) are NOT SemVer and
# version by their K8s API-version identity instead (see module_version).
is_semver_line() { [[ "$1" =~ ^v[0-9]+$ ]]; }

# next_version <published-version-or-empty> <line>
# Computes the next STABLE version by bumping the published version per
# VERSION_BUMP. Any pre-release/build suffix on the published version is stripped
# first so a develop clone's beta tags don't corrupt the arithmetic.
next_version() {
  local pub="$1" line="$2" major
  major="${line#v}"
  if [[ -z "$pub" ]]; then echo "v${major}.0.0"; return; fi
  pub="${pub%%-*}"; pub="${pub%%+*}"   # strip -prerelease / +build
  IFS='.' read -r a b c <<<"${pub#v}"
  case "$VERSION_BUMP" in
    major) echo "v$((a+1)).0.0" ;;
    patch) echo "v${a}.${b}.$((c+1))" ;;
    *)     echo "v${a}.$((b+1)).0" ;;
  esac
}

# channel_version <published-version-or-empty> <line>
# The version to publish for the current channel: on the stable channel this is
# the plain next_version; on a pre-release channel it is that base tagged
# -beta.1 (apx encodes the commit hash and ratchets it above the line's GA).
channel_version() {
  local base; base=$(next_version "$1" "$2")
  if [[ "$PRERELEASE" == "1" ]]; then echo "${base}-beta.1"; else echo "$base"; fi
}

# channel_lifecycle <module-declared-lifecycle>
# The pre-release channel always publishes beta; the stable channel uses the
# module's declared lifecycle.
channel_lifecycle() { if [[ "$PRERELEASE" == "1" ]]; then echo beta; else echo "$1"; fi; }

# crd_lifecycle <line> — a CRD's K8s API-version stability maps to an apx lifecycle
# (v1alpha1→experimental, v1beta1→beta, v1→stable). Used only when a crd module
# does not declare an explicit `lifecycle:`.
crd_lifecycle() {
  case "$1" in
    *alpha*) echo experimental ;;
    *beta*)  echo beta ;;
    *)       echo stable ;;
  esac
}

# module_version <fmt> <published-version-or-empty> <line>
# The version to publish for a module. SemVer formats bump per
# VERSION_BUMP via channel_version. A crd's version identity IS its K8s API version
# (the line, e.g. v1alpha1): content changes republish in place — no numeric bump.
module_version() {
  local fmt="$1" pub="$2" line="$3"
  if [[ "$fmt" == "crd" ]] || ! is_semver_line "$line"; then echo "$line"; return; fi
  channel_version "$pub" "$line"
}

# Staged specs, and per-module status, collected for the summary + publish.
declare -a IDS NAMES LIFECYCLES FORMATS EXTS SPECFILES STATUSES PUBVERS BLOCKED SDK_BAD VCGATE
SPEC_ARGS=()

# ── Emit + analyze each module (per-format emit, common validate tail) ────────
note "| module | format | audience | drift | published | breaking | sdk |"
note "|--------|--------|----------|-------|-----------|----------|-----|"

for ((i=0; i<NMODULES; i++)); do
  ID=$(yq -r ".modules[$i].id" "$CONFIG")
  FMT=$(module_format "$ID" "$(yq -r ".modules[$i].format // \"\"" "$CONFIG")")
  is_known_format "$FMT" || { echo "unknown format '$FMT' for $ID (want: $KNOWN_FORMATS)" >&2; exit 2; }
  AUD=$(yq -r ".modules[$i].audience // \"public\"" "$CONFIG")
  NAME=$(module_name "$ID")
  LINE=$(echo "$ID" | awk -F/ '{print $NF}')
  EXT=$(format_ext "$FMT")

  # Resolved lifecycle: explicit `lifecycle:` wins; else crd derives it from its
  # K8s API-version suffix, and every other format defaults to stable.
  LC=$(yq -r ".modules[$i].lifecycle // \"\"" "$CONFIG")
  if [[ -z "$LC" || "$LC" == "null" ]]; then
    if [[ "$FMT" == "crd" ]]; then LC=$(crd_lifecycle "$LINE"); else LC="stable"; fi
  fi

  DEST="$MODULE_ROOT/$ID"
  SPEC="$DEST/$NAME.$EXT"
  mkdir -p "$DEST"

  # ── Emit: per-format production of the staged spec apx ingests ──────────────
  # Only openapi runs the OpenAPI toolchain (make fds already done → openapiv2to3);
  # every other format uses its committed source file verbatim.
  case "$FMT" in
    openapi)
      SWAGGER=$(yq -r ".modules[$i].swagger" "$CONFIG")
      FDS=$(yq -r ".modules[$i].fds" "$CONFIG")
      [[ -f "$SWAGGER" ]] || { echo "swagger not found for $ID: $SWAGGER" >&2; exit 1; }
      [[ -f "$FDS" ]]     || { echo "FDS not found for $ID: $FDS (did '$FDS_TARGET' run?)" >&2; exit 1; }
      log "convert $SWAGGER -> $SPEC (fds=$FDS)"
      tmpout=$(mktemp -d)
      openapiv2to3 -descriptor "$FDS" "$SWAGGER" "$tmpout"
      # converter writes <name>.openapi.yaml (+ a .coverage.json sidecar); publish
      # the single spec under the catalog name. Fail loudly on 0 or >1 matches
      # rather than silently mv-ing the wrong/first file.
      _specs=$(find "$tmpout" -maxdepth 1 -name '*.openapi.yaml')
      _n=$(printf '%s\n' "$_specs" | grep -c .)
      [[ "$_n" -eq 1 ]] || { echo "convert produced $_n specs for $ID (expected 1)" >&2; rm -rf "$tmpout"; exit 1; }
      mv "$_specs" "$SPEC"
      rm -rf "$tmpout"
      ;;
    proto)
      FDS=$(yq -r ".modules[$i].fds" "$CONFIG")
      [[ -f "$FDS" ]] || { echo "FDS not found for $ID: $FDS (did '$FDS_TARGET' run?)" >&2; exit 1; }
      log "stage proto FDS $FDS -> $SPEC (no conversion)"
      cp "$FDS" "$SPEC"
      ;;
    crd|avro|jsonschema|parquet)
      field=$(format_source_field "$FMT")
      src=$(yq -r ".modules[$i].$field // \"\"" "$CONFIG")
      [[ -n "$src" && "$src" != "null" ]] || { echo "missing '$field:' source for $FMT module $ID" >&2; exit 1; }
      [[ -f "$src" ]] || { echo "$field source not found for $ID: $src" >&2; exit 1; }
      log "stage $FMT $src -> $SPEC (no conversion)"
      cp "$src" "$SPEC"
      ;;
  esac

  # ── Drift vs the catalog's live content (schema-scoped, format-agnostic) ────
  DRIFT_JSON=$(apx release status "$ID" --canonical-dir "$CANONICAL_DIR" --format json)
  STATUS=$(echo "$DRIFT_JSON" | yq -r '.status')
  PUBVER=$(echo "$DRIFT_JSON" | yq -r '.published_version // ""')

  # ── Breaking vs the published spec (if any), gated per module/format/global ──
  # public blocks (unless the gate is advisory), internal is advisory. Gate mode
  # resolves module > formats.<fmt> > gates > run default (--breaking-gate).
  BR_GATE=$(resolve_gate breaking "$FMT" "$i")
  BREAKING="n/a"; blocked=0
  PUBLISHED_SPEC="$CANONICAL_DIR/$ID/$NAME.$EXT"
  if [[ -f "$PUBLISHED_SPEC" ]]; then
    if apx breaking "$SPEC" --against "$PUBLISHED_SPEC" --format "$FMT" >"/tmp/breaking.$i" 2>&1; then
      BREAKING="ok"
    elif [[ "$BR_GATE" == "blocking" ]] || { [[ "$BR_GATE" == "auto" ]] && [[ "$AUD" == "public" ]]; }; then
      BREAKING="**BREAKING (blocking)**"; blocked=1
    else
      BREAKING="breaking (advisory)"
    fi
  fi

  # ── SDK build gate, gated per module/format/global ─────────────────────────
  # Client-generating formats (openapi/crd/proto) default to the run's
  # --verify-clients mode; non-client formats (avro/jsonschema/parquet) default
  # `off`. Any level can override: module field > formats.<fmt> > gates > default.
  VC_GATE=$(resolve_gate verify_clients "$FMT" "$i")
  SDK="n/a"; sdk_bad=0
  if [[ "$VC_GATE" != "off" ]]; then
    mapfile -t gens < <(resolve_generators "$FMT" "$i")
    verify_args=(client verify --input "$SPEC")
    for g in "${gens[@]}"; do verify_args+=(--generator "$g"); done
    if apx "${verify_args[@]}" >"/tmp/verify.$i" 2>&1; then
      SDK="ok"
    else
      SDK="**does not build**"; sdk_bad=1
    fi
  fi

  note "| \`$ID\` | $FMT | $AUD | $STATUS | ${PUBVER:-–} | $BREAKING | $SDK |"

  IDS[$i]="$ID"; NAMES[$i]="$NAME"; LIFECYCLES[$i]="$LC"; FORMATS[$i]="$FMT"; EXTS[$i]="$EXT"
  SPECFILES[$i]="$SPEC"; STATUSES[$i]="$STATUS"; PUBVERS[$i]="$PUBVER"
  BLOCKED[$i]="$blocked"; SDK_BAD[$i]="$sdk_bad"; VCGATE[$i]="$VC_GATE"
  # pathlint reconciles HTTP paths — an openapi concern; only feed it openapi specs.
  [[ "$FMT" == "openapi" ]] && SPEC_ARGS+=(--spec "$SPEC")
done
note ""

# ── Client-build gate outcome (per-module gated) ──────────────────────────────
# A spec can pass lint/breaking yet generate a client that does not compile
# (e.g. a reserved-identifier path param shadowing an import, or redundant params
# colliding on one field). Each module carries its own resolved gate: a module
# gated `fail` stops the whole run before any publish; `warn` reports only; `off`
# was skipped at emit time. See infobloxopen/apx#42.
anybad=0 anyfail=0
for ((i=0; i<NMODULES; i++)); do
  [[ "${SDK_BAD[$i]:-0}" == "1" ]] || continue
  anybad=1
  note "<details><summary>SDK build report — <code>${IDS[$i]}</code> (gate: ${VCGATE[$i]})</summary>"
  note ""; note '```'; cat "/tmp/verify.$i" >> "$SUMMARY"; note '```'; note "</details>"; note ""
  [[ "${VCGATE[$i]}" == "fail" ]] && anyfail=1
done
if [[ "$anyfail" == "1" ]]; then
  note "> :x: Generated client does not build for a module gated \`verify_clients: fail\` — failing the run."
  log "FAILED: generated client does not build (see SDK build report)"
  exit 1
elif [[ "$anybad" == "1" ]]; then
  note "> :warning: Generated client does not build (advisory — gated \`warn\`)."
  note ""
fi

# ── Path-reconciliation lint (R4: metric, not a gate) ─────────────────────────
render_ingress() {
  if [[ -n "$PATHLINT_INGRESS" ]]; then echo "$PATHLINT_INGRESS"; return; fi
  [[ -n "$PATHLINT_CHART" ]] || return 1
  local out; out=$(mktemp)
  helm template "$PATHLINT_RELEASE" "$PATHLINT_CHART" > "$out" 2>/dev/null || return 1
  echo "$out"
}
if ING=$(render_ingress); then
  log "pathlint (ingress=$ING)"
  note "### Path reconciliation (warning-only)"
  note '```'
  apx pathlint --ingress "$ING" "${SPEC_ARGS[@]}" --warn-only 2>&1 | tee -a "$SUMMARY" >&2 || true
  note '```'
  note ""
fi

# ── Mode: check (PR) — report only, but fail on a blocking breaking change ─────
if [[ "$MODE" == "check" ]]; then
  anyblocked=0
  for ((i=0; i<NMODULES; i++)); do [[ "${BLOCKED[$i]}" == "1" ]] && anyblocked=1; done
  if [[ "$anyblocked" == "1" ]]; then
    note "> :x: Blocking breaking change on a public module — see the breaking report above."
    log "check FAILED: blocking breaking change on a public module"
    exit 1
  fi
  # AC-1 (fail-closed ratchet) on the pre-release channel: for each changed/absent
  # module, dry-run prepare against the canonical clone so a PR targeting develop
  # fails when its beta would land at/below the line's highest GA. prepare also
  # validates the commit-hash-encoded version is legal SemVer.
  if [[ "$PRERELEASE" == "1" ]]; then
    for ((i=0; i<NMODULES; i++)); do
      [[ "${STATUSES[$i]}" == "unchanged" ]] && continue
      id="${IDS[$i]}"; line=$(echo "$id" | awk -F/ '{print $NF}')
      # The beta ratchet is SemVer-ordered; K8s crd versions (v1alpha1…) don't
      # participate — skip non-SemVer lines.
      is_semver_line "$line" || { log "skip pre-release ratchet for $id (non-semver line $line)"; continue; }
      ver=$(channel_version "${PUBVERS[$i]}" "$line")
      if ! apx release prepare "$id" --version "$ver" --lifecycle beta \
             --source-branch "$SRC_BRANCH" --encode-commit-hash \
             --canonical-repo="$CANONICAL_REPO" --canonical-dir "$CANONICAL_DIR" \
             --dry-run >"/tmp/ratchet.$i" 2>&1; then
        note "> :x: Pre-release version gate failed for \`$id\` (base branch \`$BASE_BRANCH\`):"
        note '```'; cat "/tmp/ratchet.$i" >> "$SUMMARY"; note '```'
        log "check FAILED: pre-release gate for $id"; cat "/tmp/ratchet.$i" >&2
        exit 1
      fi
    done
  fi
  log "check complete (no blocking issues)"
  exit 0
fi

# ── Mode: publish (on merge) — open PR + drift issue per changed/absent module ─
publish_gitea() {
  # Ports ws035 release-into-canonical.sh, but OPENS the PR (no auto-merge unless
  # --auto-merge) and files a drift issue. Requires GITEA_* env.
  local id="$1" ver="$2" lc="$3" name="$4" spec="$5" ext="${6:-yaml}"
  : "${GITEA_URL:?}" "${GITEA_ORG:?}" "${GITEA_TOKEN:?}"
  local repo="${CANONICAL_REPO##*/}"; repo="${repo%.git}"
  local origin="http://${GITEA_URL#http*://}/${GITEA_ORG}/${repo}.git"
  local base="$BASE_BRANCH"   # ARCH-271: target the resolved base branch
  # Auth via a per-invocation Authorization header — never a credential in the
  # clone/push URL argv (which git prints on error and would leak to logs).
  local -a gauth=(-c "http.extraHeader=Authorization: token ${GITEA_TOKEN}")
  local api="$GITEA_URL/api/v1/repos/$GITEA_ORG/$repo"

  local -a prep=(release prepare "$id" --version "$ver" --lifecycle "$lc"
    --canonical-repo="github.com/${GITEA_ORG}/${repo}" --source-branch "$SRC_BRANCH")
  [[ "$PRERELEASE" == "1" ]] && prep+=(--encode-commit-hash --canonical-dir "$CANONICAL_DIR")
  apx "${prep[@]}" >/dev/null
  local tag gomod gomod_dir branch
  # prepare may rewrite the version (commit-hash encoding) — read the final one.
  ver=$(yq -r '.requested_version' .apx-release.yaml)
  tag=$(yq -r '.tag' .apx-release.yaml)
  gomod=$(yq -r '.languages.go.module' .apx-release.yaml)
  gomod_dir="${gomod#github.com/${GITEA_ORG}/${repo}/}"
  branch="apx/release/$(echo "$id" | tr '/' '-')/$ver"

  ( cd "$CANONICAL_DIR"
    git checkout -q "$base" >/dev/null 2>&1 || git checkout -q -b "$base" "origin/$base" >/dev/null 2>&1 || true
    git "${gauth[@]}" pull -q "$origin" "$base" >/dev/null 2>&1 || true
    git branch -D "$branch" >/dev/null 2>&1 || true
    git checkout -q -b "$branch"
    mkdir -p "$id"; cp "$OLDPWD/$spec" "$id/$name.$ext"
    mkdir -p "$gomod_dir"; printf 'module %s\n\ngo 1.21\n' "$gomod" > "$gomod_dir/go.mod"
    git add -A && git commit -q -m "release: ${id}@${ver}"
    git "${gauth[@]}" push -q -f "$origin" "$branch" >/dev/null 2>&1 )

  local pr prnum pr_body
  pr_body=$(jq -nc --arg t "release: ${id}@${ver}" --arg h "$branch" --arg base "$base" \
    --arg b "Automated API republish (apx publish-on-change)." \
    '{title:$t, head:$h, base:$base, body:$b}')
  pr=$(curl -s -X POST "$api/pulls" -H "Authorization: token $GITEA_TOKEN" \
    -H "Content-Type: application/json" -d "$pr_body")
  prnum=$(echo "$pr" | jq -r '.number // empty')
  [[ -n "$prnum" ]] || { echo "gitea PR create failed for $id@$ver: $pr" >&2; return 1; }
  log "opened gitea PR #$prnum for $id@$ver"
  note "- \`$id\` → **PR #$prnum** ($ver)"

  # Drift issue.
  jq -nc --arg t "catalog drift: ${id} needs publish (${ver})" \
    --arg b "The service API changed and is not yet in the catalog. Publish PR #${prnum} opened automatically." \
    '{title:$t, body:$b}' \
  | curl -s -X POST "$api/issues" -H "Authorization: token $GITEA_TOKEN" \
    -H "Content-Type: application/json" -d @- -o /dev/null

  if [[ "$AUTO_MERGE" == "1" ]]; then
    local code
    for _ in $(seq 1 60); do
      code=$(curl -s -X POST "$api/pulls/$prnum/merge" -H "Authorization: token $GITEA_TOKEN" \
        -H "Content-Type: application/json" -d '{"Do":"merge"}' -o /dev/null -w "%{http_code}")
      [[ "$code" == "200" ]] && break
      curl -s "$api/pulls/$prnum" -H "Authorization: token $GITEA_TOKEN" -o /dev/null
    done
    ( cd "$CANONICAL_DIR"
      git checkout -q "$base" >/dev/null 2>&1 || true
      git "${gauth[@]}" pull -q "$origin" "$base" >/dev/null 2>&1 || true
      CI=true apx release finalize --api "$id" --version "$ver" --lifecycle "$lc" \
        --base-branch "$base" --local >&2 || true
      cp catalog.yaml catalog/catalog.yaml 2>/dev/null || true
      git add -A && git commit -q -m "catalog: record ${id}@${ver}" || true
      git "${gauth[@]}" push -q "$origin" "$base" >/dev/null 2>&1 || true
      git "${gauth[@]}" push -q "$origin" "$tag" >/dev/null 2>&1 || true )
    log "merged + finalized $id@$ver on $base (sandbox demo)"
  fi
}

publish_github() {
  local id="$1" ver="$2" lc="$3"
  : "${GITHUB_TOKEN:?GITHUB_TOKEN required for github publish}"
  local -a prep=(release prepare "$id" --version "$ver" --lifecycle "$lc"
    --canonical-repo="$CANONICAL_REPO" --source-branch "$SRC_BRANCH")
  # ARCH-271 pre-release channel: encode the commit hash and run the ratchet
  # against the canonical clone at prepare time.
  [[ "$PRERELEASE" == "1" ]] && prep+=(--encode-commit-hash --canonical-dir "$CANONICAL_DIR")
  apx "${prep[@]}" >/dev/null
  ver=$(yq -r '.requested_version' .apx-release.yaml)   # may be hash-encoded
  apx release submit   # native PR on GitHub → targets the manifest's base branch
  note "- \`$id\` → submitted publish PR ($ver, base \`$BASE_BRANCH\`)"
  # Drift issue via GitHub REST.
  jq -nc --arg t "catalog drift: ${id} needs publish (${ver})" \
    --arg b "Automated publish PR opened by apx publish-on-change." \
    '{title:$t, body:$b}' \
  | curl -s -X POST "https://api.github.com/repos/${CANON_NWO}/issues" \
    -H "Authorization: token $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" \
    -d @- -o /dev/null || true
  # CICD-1378: this new PR supersedes any earlier open PR for the same module id
  # on this base branch — close them so stale betas don't pile up. Best-effort.
  supersede_prs "$id" "$ver" || true
}

note "### Publish"
published_any=0
for ((i=0; i<NMODULES; i++)); do
  ST="${STATUSES[$i]}"
  [[ "$ST" == "unchanged" ]] && continue
  if [[ "${BLOCKED[$i]}" == "1" ]]; then
    note "- \`${IDS[$i]}\` **skipped** — blocking breaking change on a public module"
    log "skip publish ${IDS[$i]} — blocking breaking change"; continue
  fi
  published_any=1
  ID="${IDS[$i]}"; FMT="${FORMATS[$i]}"; LINE=$(echo "$ID" | awk -F/ '{print $NF}')
  VER=$(module_version "$FMT" "${PUBVERS[$i]}" "$LINE")
  LC=$(channel_lifecycle "${LIFECYCLES[$i]}")
  log "publish $ID [$FMT] ($ST) -> $VER [$LC, base $BASE_BRANCH]"
  if [[ "$FORGE" == "gitea" ]]; then
    publish_gitea "$ID" "$VER" "$LC" "${NAMES[$i]}" "${SPECFILES[$i]}" "${EXTS[$i]}"
  else
    publish_github "$ID" "$VER" "$LC"
  fi
done
[[ "$published_any" == "0" ]] && note "- all modules in sync — nothing to publish"
log "publish complete"
