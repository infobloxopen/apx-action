#!/usr/bin/env bash
#
# Unit test for scripts/supersede.sh (CICD-1378). Sources the helper, stubs `curl`
# so no network is touched, and asserts that opening a new beta PR closes ONLY the
# prior open PRs for the SAME module id + base branch — never the new PR, never a
# different module's PR — with a comment, label, and branch delete on each.
#
# Run: bash tests/supersede_test.sh   (needs bash + jq; no network)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/supersede.sh
source "$HERE/../scripts/supersede.sh"

command -v jq >/dev/null || { echo "jq is required for this test" >&2; exit 2; }

CALLS=""           # mutating calls recorded by the curl stub
PULLS_JSON=""      # canned GET /pulls response

# Stub curl: record mutating calls; answer GET /pulls with $PULLS_JSON; report the
# label as missing (404 → exit 1) so the create path is exercised too.
curl() {
  local method="GET" url="" data=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -X) method="$2"; shift 2 ;;
      -d) data="$2"; shift 2 ;;
      https://*) url="$1"; shift ;;
      *) shift ;;
    esac
  done
  # bodies are piped as `-d @-`; read them from stdin so assertions can see them.
  [[ "$data" == "@-" ]] && data="$(cat)"
  [[ "$method" == "GET" ]] || echo "${method} ${url} ${data}" >> "$CALLS"
  case "${method}:${url}" in
    GET:*/labels/*)  return 1 ;;                 # label absent → trigger create
    GET:*/pulls*)    printf '%s' "$PULLS_JSON" ;;
    *) : ;;
  esac
  return 0
}

# ── Fixture ───────────────────────────────────────────────────────────────────
export CANON_NWO="Infoblox-CTO/apis"
export BASE_BRANCH="develop"
export GITHUB_TOKEN="stub-token"
export SUPERSEDE_LABEL="superseded"
A="apx/release/openapi-csp.infoblox.com-iam-identity-internal-v2"   # module under test
B="apx/release/openapi-csp.infoblox.com-dashboard-api-v1"           # unrelated module
PULLS_JSON=$(cat <<JSON
[
  {"number":135,"head":{"ref":"$A/v2.0.0-beta.1.g18b79fb19e61"},"created_at":"2026-07-16T17:06:26Z"},
  {"number":137,"head":{"ref":"$A/v2.1.0-beta.1.g4307b0128079"},"created_at":"2026-07-22T00:09:51Z"},
  {"number":200,"head":{"ref":"$A/v2.1.0-beta.1.gNEWCOMMIT00"},"created_at":"2026-07-22T09:30:00Z"},
  {"number":136,"head":{"ref":"$B/v1.0.0-beta.1"},"created_at":"2026-07-22T09:45:30Z"}
]
JSON
)

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_has()  { grep -qF -- "$1" "$CALLS" || fail "expected call: $1"; }
assert_lacks(){ ! grep -qF -- "$1" "$CALLS" || fail "unexpected call: $1"; }

# ── Case 1: keeper = new_branch (#200); close #135 + #137; leave #136 + #200 ────
CALLS="$(mktemp)"; SUPERSEDE=on
supersede_prs "openapi/csp.infoblox.com/iam-identity-internal/v2" "v2.1.0-beta.1.gNEWCOMMIT00"

assert_has "POST https://api.github.com/repos/Infoblox-CTO/apis/labels"          # label created
for n in 135 137; do
  assert_has "POST https://api.github.com/repos/Infoblox-CTO/apis/issues/${n}/comments"
  assert_has "POST https://api.github.com/repos/Infoblox-CTO/apis/issues/${n}/labels"
  assert_has "PATCH https://api.github.com/repos/Infoblox-CTO/apis/pulls/${n} {\"state\":\"closed\"}"
done
assert_has "DELETE https://api.github.com/repos/Infoblox-CTO/apis/git/refs/heads/$A/v2.0.0-beta.1.g18b79fb19e61"
assert_has "DELETE https://api.github.com/repos/Infoblox-CTO/apis/git/refs/heads/$A/v2.1.0-beta.1.g4307b0128079"
# never touch the new PR or the unrelated module's PR
assert_lacks "pulls/200"
assert_lacks "pulls/136"
assert_lacks "issues/200"
assert_lacks "issues/136"
# comment references the keeper PR number
grep -qF 'Superseded by #200.' "$CALLS" || fail "comment should reference keeper #200"
echo "ok: case 1 — closed #135 #137, kept #200 (new) and #136 (other module)"

# ── Case 2: keeper falls back to newest-by-created_at when new_ver has no branch ─
# (apx named the branch differently) — #200 is newest, so it is still kept.
CALLS="$(mktemp)"; SUPERSEDE=on
supersede_prs "openapi/csp.infoblox.com/iam-identity-internal/v2" "v9.9.9-does-not-match"
assert_has "PATCH https://api.github.com/repos/Infoblox-CTO/apis/pulls/135 {\"state\":\"closed\"}"
assert_has "PATCH https://api.github.com/repos/Infoblox-CTO/apis/pulls/137 {\"state\":\"closed\"}"
assert_lacks "pulls/200"
assert_lacks "pulls/136"
echo "ok: case 2 — no branch match, newest-by-date (#200) kept"

# ── Case 3: toggle off → no mutating calls at all ──────────────────────────────
CALLS="$(mktemp)"; SUPERSEDE=off
supersede_prs "openapi/csp.infoblox.com/iam-identity-internal/v2" "v2.1.0-beta.1.gNEWCOMMIT00"
[[ ! -s "$CALLS" ]] || fail "supersede off must make no mutating calls"
echo "ok: case 3 — --supersede off is a no-op"

# ── Case 4: only the new PR exists → nothing to close ──────────────────────────
CALLS="$(mktemp)"; SUPERSEDE=on
PULLS_JSON='[{"number":200,"head":{"ref":"'"$A"'/v2.1.0-beta.1.gNEWCOMMIT00"},"created_at":"2026-07-22T09:30:00Z"}]'
supersede_prs "openapi/csp.infoblox.com/iam-identity-internal/v2" "v2.1.0-beta.1.gNEWCOMMIT00"
[[ ! -s "$CALLS" ]] || fail "single PR must not close anything"
echo "ok: case 4 — sole PR left untouched"

echo "ALL PASS"
