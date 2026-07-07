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

# ── Config ──────────────────────────────────────────────────────────────────
CANONICAL_REPO=$(yq -r '.canonical_repo' "$CONFIG")
FORGE=$(yq -r '.forge // "github"' "$CONFIG")
FDS_TARGET=$(yq -r '.fds_target // "fds"' "$CONFIG")
CONVERTER_VERSION=$(yq -r '.converter_version // "v0.60.0"' "$CONFIG")
VERSION_BUMP=$(yq -r '.version_bump // "minor"' "$CONFIG")
PATHLINT_CHART=$(yq -r '.pathlint.chart // ""' "$CONFIG")
PATHLINT_RELEASE=$(yq -r '.pathlint.release_name // "release"' "$CONFIG")
NMODULES=$(yq -r '.modules | length' "$CONFIG")

# github.com-style NWO used by apx for identity/go-module derivation (even on gitea).
CANON_NWO=$(echo "$CANONICAL_REPO" | sed -E 's#^https?://##; s#\.git$##; s#^[^/]+/##')

log "mode=$MODE forge=$FORGE canonical=$CANONICAL_REPO modules=$NMODULES"
note "## apx publish-on-change ($MODE)"
note ""
note "Canonical: \`$CANONICAL_REPO\` · forge: \`$FORGE\` · modules: $NMODULES"
note ""

# ── openapiv2to3 (converter) ──────────────────────────────────────────────────
if ! command -v openapiv2to3 >/dev/null; then
  log "installing openapiv2to3 $CONVERTER_VERSION"
  go install "github.com/infobloxopen/devedge-sdk/cmd/openapiv2to3@${CONVERTER_VERSION}"
fi

# ── FileDescriptorSet(s) via the repo's own gentool ───────────────────────────
log "make $FDS_TARGET (FileDescriptorSet)"
make "$FDS_TARGET"

# module name = the <name> segment of format/domain/name/line
module_name() { echo "$1" | awk -F/ '{print $(NF-1)}'; }

# next_version <published-version-or-empty> <line>
next_version() {
  local pub="$1" line="$2" major
  major="${line#v}"
  if [[ -z "$pub" ]]; then echo "v${major}.0.0"; return; fi
  IFS='.' read -r a b c <<<"${pub#v}"
  case "$VERSION_BUMP" in
    major) echo "v$((a+1)).0.0" ;;
    patch) echo "v${a}.${b}.$((c+1))" ;;
    *)     echo "v${a}.$((b+1)).0" ;;
  esac
}

# Staged converted specs, and per-module status, collected for the summary + publish.
declare -a IDS NAMES LIFECYCLES SPECFILES STATUSES PUBVERS BLOCKED
SPEC_ARGS=()

# ── Convert + analyze each module ─────────────────────────────────────────────
note "| module | audience | drift | published | breaking |"
note "|--------|----------|-------|-----------|----------|"

for ((i=0; i<NMODULES; i++)); do
  ID=$(yq -r ".modules[$i].id" "$CONFIG")
  SWAGGER=$(yq -r ".modules[$i].swagger" "$CONFIG")
  FDS=$(yq -r ".modules[$i].fds" "$CONFIG")
  AUD=$(yq -r ".modules[$i].audience // \"public\"" "$CONFIG")
  LC=$(yq -r ".modules[$i].lifecycle // \"stable\"" "$CONFIG")
  NAME=$(module_name "$ID")
  LINE=$(echo "$ID" | awk -F/ '{print $NF}')

  DEST="$MODULE_ROOT/$ID"
  SPEC="$DEST/$NAME.yaml"
  mkdir -p "$DEST"

  [[ -f "$SWAGGER" ]] || { echo "swagger not found for $ID: $SWAGGER" >&2; exit 1; }
  [[ -f "$FDS" ]]     || { echo "FDS not found for $ID: $FDS (did '$FDS_TARGET' run?)" >&2; exit 1; }
  log "convert $SWAGGER -> $SPEC (fds=$FDS)"
  tmpout=$(mktemp -d)
  openapiv2to3 -descriptor "$FDS" "$SWAGGER" "$tmpout"
  # converter writes <name>.openapi.yaml (+ a .coverage.json sidecar); publish the
  # single spec under the catalog name. Fail loudly on 0 or >1 matches rather than
  # silently mv-ing the wrong/first file.
  _specs=$(find "$tmpout" -maxdepth 1 -name '*.openapi.yaml')
  _n=$(printf '%s\n' "$_specs" | grep -c .)
  [[ "$_n" -eq 1 ]] || { echo "convert produced $_n specs for $ID (expected 1)" >&2; rm -rf "$tmpout"; exit 1; }
  mv "$_specs" "$SPEC"
  rm -rf "$tmpout"

  # Drift vs the catalog's live content.
  DRIFT_JSON=$(apx release status "$ID" --canonical-dir "$CANONICAL_DIR" --format json)
  STATUS=$(echo "$DRIFT_JSON" | yq -r '.status')
  PUBVER=$(echo "$DRIFT_JSON" | yq -r '.published_version // ""')

  # Breaking vs the published spec (if any). Detect via exit code, then gate:
  # public blocks (unless --breaking-gate advisory), internal is advisory (R: the
  # public module carries the strict customer-facing gate; -internal is relaxed).
  BREAKING="n/a"; blocked=0
  PUBLISHED_SPEC="$CANONICAL_DIR/$ID/$NAME.yaml"
  if [[ -f "$PUBLISHED_SPEC" ]]; then
    if apx breaking "$SPEC" --against "$PUBLISHED_SPEC" --format openapi >"/tmp/breaking.$i" 2>&1; then
      BREAKING="ok"
    elif [[ "$BREAKING_GATE" == "blocking" ]] || { [[ "$BREAKING_GATE" == "auto" ]] && [[ "$AUD" == "public" ]]; }; then
      BREAKING="**BREAKING (blocking)**"; blocked=1
    else
      BREAKING="breaking (advisory)"
    fi
  fi

  note "| \`$ID\` | $AUD | $STATUS | ${PUBVER:-–} | $BREAKING |"

  IDS[$i]="$ID"; NAMES[$i]="$NAME"; LIFECYCLES[$i]="$LC"
  SPECFILES[$i]="$SPEC"; STATUSES[$i]="$STATUS"; PUBVERS[$i]="$PUBVER"; BLOCKED[$i]="$blocked"
  SPEC_ARGS+=(--spec "$SPEC")
done
note ""

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
  log "check complete (no blocking issues)"
  exit 0
fi

# ── Mode: publish (on merge) — open PR + drift issue per changed/absent module ─
publish_gitea() {
  # Ports ws035 release-into-canonical.sh, but OPENS the PR (no auto-merge unless
  # --auto-merge) and files a drift issue. Requires GITEA_* env.
  local id="$1" ver="$2" lc="$3" name="$4" spec="$5"
  : "${GITEA_URL:?}" "${GITEA_ORG:?}" "${GITEA_TOKEN:?}"
  local repo="${CANONICAL_REPO##*/}"; repo="${repo%.git}"
  local origin="http://${GITEA_URL#http*://}/${GITEA_ORG}/${repo}.git"
  # Auth via a per-invocation Authorization header — never a credential in the
  # clone/push URL argv (which git prints on error and would leak to logs).
  local -a gauth=(-c "http.extraHeader=Authorization: token ${GITEA_TOKEN}")
  local api="$GITEA_URL/api/v1/repos/$GITEA_ORG/$repo"

  apx release prepare "$id" --version "$ver" --lifecycle "$lc" \
    --canonical-repo="github.com/${GITEA_ORG}/${repo}" >/dev/null
  local tag gomod gomod_dir branch
  tag=$(yq -r '.tag' .apx-release.yaml)
  gomod=$(yq -r '.languages.go.module' .apx-release.yaml)
  gomod_dir="${gomod#github.com/${GITEA_ORG}/${repo}/}"
  branch="apx/release/$(echo "$id" | tr '/' '-')/$ver"

  ( cd "$CANONICAL_DIR"
    git checkout -q main >/dev/null 2>&1 || true
    git "${gauth[@]}" pull -q "$origin" main >/dev/null 2>&1 || true
    git branch -D "$branch" >/dev/null 2>&1 || true
    git checkout -q -b "$branch"
    mkdir -p "$id"; cp "$OLDPWD/$spec" "$id/$name.yaml"
    mkdir -p "$gomod_dir"; printf 'module %s\n\ngo 1.21\n' "$gomod" > "$gomod_dir/go.mod"
    git add -A && git commit -q -m "release: ${id}@${ver}"
    git "${gauth[@]}" push -q -f "$origin" "$branch" >/dev/null 2>&1 )

  local pr prnum pr_body
  pr_body=$(jq -nc --arg t "release: ${id}@${ver}" --arg h "$branch" \
    --arg b "Automated API republish (apx publish-on-change)." \
    '{title:$t, head:$h, base:"main", body:$b}')
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
      git checkout -q main >/dev/null 2>&1 || true
      git "${gauth[@]}" pull -q "$origin" main >/dev/null 2>&1 || true
      CI=true apx release finalize --api "$id" --version "$ver" --lifecycle "$lc" --local >&2 || true
      cp catalog.yaml catalog/catalog.yaml 2>/dev/null || true
      git add -A && git commit -q -m "catalog: record ${id}@${ver}" || true
      git "${gauth[@]}" push -q "$origin" main >/dev/null 2>&1 || true
      git "${gauth[@]}" push -q "$origin" "$tag" >/dev/null 2>&1 || true )
    log "merged + finalized $id@$ver (sandbox demo)"
  fi
}

publish_github() {
  local id="$1" ver="$2" lc="$3"
  : "${GITHUB_TOKEN:?GITHUB_TOKEN required for github publish}"
  apx release prepare "$id" --version "$ver" --lifecycle "$lc" --canonical-repo="$CANONICAL_REPO" >/dev/null
  apx release submit   # native PR on GitHub
  note "- \`$id\` → submitted publish PR ($ver)"
  # Drift issue via GitHub REST.
  jq -nc --arg t "catalog drift: ${id} needs publish (${ver})" \
    --arg b "Automated publish PR opened by apx publish-on-change." \
    '{title:$t, body:$b}' \
  | curl -s -X POST "https://api.github.com/repos/${CANON_NWO}/issues" \
    -H "Authorization: token $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" \
    -d @- -o /dev/null || true
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
  ID="${IDS[$i]}"; LINE=$(echo "$ID" | awk -F/ '{print $NF}')
  VER=$(next_version "${PUBVERS[$i]}" "$LINE")
  log "publish $ID ($ST) -> $VER"
  if [[ "$FORGE" == "gitea" ]]; then
    publish_gitea "$ID" "$VER" "${LIFECYCLES[$i]}" "${NAMES[$i]}" "${SPECFILES[$i]}"
  else
    publish_github "$ID" "$VER" "${LIFECYCLES[$i]}"
  fi
done
[[ "$published_any" == "0" ]] && note "- all modules in sync — nothing to publish"
log "publish complete"
