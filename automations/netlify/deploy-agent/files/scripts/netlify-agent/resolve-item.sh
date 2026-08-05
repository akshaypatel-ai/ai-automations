#!/usr/bin/env bash
# Decide which playbook (if any) applies to a Netlify deploy by checking the
# API against saved state. Fully implemented: deploys.
# Usage: resolve-item.sh <deploy_id> [item_type]   → prints a one-line decision JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ITEM_ID="$1"
TYPE_HINT="${2:-Deploy}"
STATE_FILE="$STATE_DIR/state/$ITEM_ID.json"

skip() { # skip <reason>
  jq -cn --arg id "$ITEM_ID" --arg t "$TYPE_HINT" --arg r "$1" \
    '{item_id: $id, item_type: $t, decision: "skip", reason: $r}'
  exit 0
}

[[ "$TYPE_HINT" == "Deploy" ]] || skip "handler not implemented yet"
[[ ",$ENABLED_HANDLERS," == *",deploys,"* ]] || skip "handler 'deploys' disabled"

state='{}'
[[ -f "$STATE_FILE" ]] && state=$(cat "$STATE_FILE")
phase=$(jq -r '.phase // "new"' <<<"$state")

deploy_json=$("$SCRIPT_DIR/api.sh" GET "/deploys/$ITEM_ID" 2>/dev/null) || skip "deploy not fetchable"

# Only failed deploys are triage material — ready/building/enqueued are not our business.
deploy_state=$(jq -r '.state // ""' <<<"$deploy_json")
[[ "$deploy_state" == "error" ]] || skip "deploy not in error state"

# A deploy errors exactly once — a tracked one means a retrigger or a
# duplicate delivery, and the sha-search dedupe already ran when it was filed.
[[ -f "$STATE_FILE" && "$phase" == "filed" ]] && skip "already processed"

# Link fields vary across deploy payloads — read defensively.
deploy_url=$(jq -r '.deploy_url // .links.permalink // ""' <<<"$deploy_json")
branch=$(jq -r '.branch // ""' <<<"$deploy_json")
site_name=$(jq -r '.name // ""' <<<"$deploy_json")
commit_sha=$(jq -r '.commit_ref // ""' <<<"$deploy_json")
commit_url=$(jq -r '.commit_url // ""' <<<"$deploy_json")
# error_message often carries the failing step + last lines — Netlify has no
# public build-log API, so this is the decision-sized excerpt (full text goes
# into the prompt via the context file).
error_message=$(jq -r '(.error_message // "")[:500]' <<<"$deploy_json")

jq -cn \
  --arg item_id "$ITEM_ID" \
  --arg decision "analyze" \
  --arg reason "failed deploy" \
  --arg deploy_url "$deploy_url" \
  --arg branch "$branch" \
  --arg site_name "$site_name" \
  --arg commit_sha "$commit_sha" \
  --arg commit_url "$commit_url" \
  --arg error_message "$error_message" \
  --arg prev_phase "$phase" \
  '{item_id: $item_id, item_type: "Deploy", decision: $decision, reason: $reason,
    deploy_url: $deploy_url, branch: $branch, site_name: $site_name,
    commit_sha: $commit_sha, commit_url: $commit_url, error_message: $error_message,
    prev_phase: $prev_phase}'
