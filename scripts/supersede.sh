#!/usr/bin/env bash
#
# supersede.sh — close prior open apx/release PRs superseded by a newer one (CICD-1378).
#
# When publish-on-change opens a new release PR for a module, any EARLIER open PR
# for the SAME module id on the SAME base branch is stale: only the newest belongs
# in review. Left alone they pile up (and each recomputes -beta.1 because the base
# never advances). This closes each stale PR, labels it, comments "Superseded by
# #<new>", and deletes its head branch.
#
# Scoped by the deterministic branch name apx uses for a module's release PR:
#   apx/release/<module-id-with-slashes-as-dashes>/<version>
# so every release PR for one module shares a prefix and differs only by version.
#
# This file contains ONLY functions (no top-level execution): apx-publish.sh
# sources it, and tests/supersede_test.sh exercises it with a stubbed `curl`.
#
# Reads from the sourcing script's environment:
#   CANON_NWO        owner/name of the canonical repo (e.g. Infoblox-CTO/apis)
#   BASE_BRANCH      the base branch this run targets (e.g. develop)
#   GITHUB_TOKEN     the least-privilege submit-App token (pull_requests + issues write)
#   SUPERSEDE        on|off — master toggle (default on)
#   SUPERSEDE_LABEL  label applied to the closed PRs (default superseded)
#
# Uses log()/note() from the sourcing script; falls back to sane defaults so the
# file works stand-alone (e.g. under test). Every network call is best-effort —
# a failure here logs and returns 0, so PR cleanup can never fail a publish run.

declare -F log  >/dev/null 2>&1 || log()  { echo "==> $*" >&2; }
declare -F note >/dev/null 2>&1 || note() { :; }

# module_branch_prefix <module-id> -> apx/release/<id-with-slashes-as-dashes>/
module_branch_prefix() { printf 'apx/release/%s/' "$(echo "$1" | tr '/' '-')"; }

# supersede_ensure_label — create $SUPERSEDE_LABEL in the canonical repo if absent.
supersede_ensure_label() {
  local api="https://api.github.com/repos/${CANON_NWO}"
  local -a auth=(-H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json")
  if curl -fsS "${auth[@]}" "$api/labels/${SUPERSEDE_LABEL}" >/dev/null 2>&1; then
    return 0
  fi
  jq -nc --arg n "$SUPERSEDE_LABEL" --arg c "ededed" \
       --arg d "Closed by apx publish-on-change: superseded by a newer release PR" \
       '{name:$n, color:$c, description:$d}' \
    | curl -fsS -X POST "${auth[@]}" "$api/labels" -d @- >/dev/null 2>&1 || true
}

# supersede_prs <module-id> <new-version>
# Close every OTHER open apx/release PR for <module-id> on $BASE_BRANCH in favour
# of the one just opened. The PR to KEEP is the one whose head branch is
# apx/release/<id>/<new-version>, or — if apx named it differently — the newest by
# created_at (which is the just-opened PR). That two-way rule guarantees the fresh
# PR is never the one closed.
supersede_prs() {
  local id="$1" new_ver="$2"
  [[ "${SUPERSEDE:-on}" == "on" ]] || { log "supersede: disabled (--supersede off) — skipping"; return 0; }
  [[ -n "${GITHUB_TOKEN:-}" ]]     || { log "supersede: no GITHUB_TOKEN — skipping"; return 0; }
  [[ -n "${CANON_NWO:-}" ]]        || { log "supersede: no CANON_NWO — skipping"; return 0; }

  local label="${SUPERSEDE_LABEL:-superseded}"
  local api="https://api.github.com/repos/${CANON_NWO}"
  local -a auth=(-H "Authorization: token ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json")
  local prefix new_branch
  prefix="$(module_branch_prefix "$id")"
  new_branch="${prefix}${new_ver}"

  # One list of this base's open PRs; do all selection locally.
  local all=""
  all=$(curl -fsS "${auth[@]}" "$api/pulls?state=open&base=${BASE_BRANCH}&per_page=100" 2>/dev/null) || true
  [[ -n "$all" ]] || { log "supersede: could not list PRs for ${CANON_NWO} — skipping"; return 0; }

  # Keeper = new_branch match, else newest-by-created_at among this module's PRs.
  local keeper=""
  keeper=$(printf '%s' "$all" | jq -r --arg pre "$prefix" --arg nb "$new_branch" '
      [ .[] | select(.head.ref | startswith($pre)) ] as $m
      | ( ( $m[] | select(.head.ref == $nb) | .number )
          // ( $m | sort_by(.created_at) | last | .number )
          // empty )
    ' 2>/dev/null) || true
  [[ -n "$keeper" ]] || { log "supersede: no open PRs for $id on $BASE_BRANCH"; return 0; }

  # Every other open PR for this module id → victims (number<TAB>head-ref).
  local victims=""
  victims=$(printf '%s' "$all" | jq -r --arg pre "$prefix" --argjson keep "$keeper" '
      .[] | select(.head.ref | startswith($pre)) | select(.number != $keep)
          | "\(.number)\t\(.head.ref)"
    ' 2>/dev/null) || true
  [[ -n "$victims" ]] || { log "supersede: no prior open PRs for $id (keeper #$keeper)"; return 0; }

  supersede_ensure_label

  local num ref
  while IFS=$'\t' read -r num ref; do
    [[ -n "$num" ]] || continue
    jq -nc --arg b "Superseded by #${keeper}. Closed automatically by apx publish-on-change." \
        '{body:$b}' \
      | curl -fsS -X POST "${auth[@]}" "$api/issues/${num}/comments" -d @- >/dev/null 2>&1 || true
    jq -nc --arg l "$label" '{labels:[$l]}' \
      | curl -fsS -X POST "${auth[@]}" "$api/issues/${num}/labels" -d @- >/dev/null 2>&1 || true
    curl -fsS -X PATCH "${auth[@]}" "$api/pulls/${num}" -d '{"state":"closed"}' >/dev/null 2>&1 || true
    curl -fsS -X DELETE "${auth[@]}" "$api/git/refs/heads/${ref}" >/dev/null 2>&1 || true
    log "supersede: closed PR #${num} ($ref) — superseded by #${keeper}"
    note "- \`$id\` → closed superseded PR #${num} (superseded by #${keeper})"
  done <<< "$victims"
}
