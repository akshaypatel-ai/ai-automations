#!/usr/bin/env bash
# Decide which playbook (if any) applies to a Vercel deployment by checking the
# API against saved state. Fully implemented: deployments.
# Usage: resolve-item.sh <deployment_id> [item_type]   → prints a one-line decision JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ITEM_ID="$1"
TYPE_HINT="${2:-Deployment}"
STATE_FILE="$STATE_DIR/state/$ITEM_ID.json"

skip() { # skip <reason>
  jq -cn --arg id "$ITEM_ID" --arg t "$TYPE_HINT" --arg r "$1" \
    '{item_id: $id, item_type: $t, decision: "skip", reason: $r}'
  exit 0
}

[[ "$TYPE_HINT" == "Deployment" ]] || skip "handler not implemented yet"
[[ ",$ENABLED_HANDLERS," == *",deployments,"* ]] || skip "handler 'deployments' disabled"

state='{}'
[[ -f "$STATE_FILE" ]] && state=$(cat "$STATE_FILE")
phase=$(jq -r '.phase // "new"' <<<"$state")

deploy_json=$("$SCRIPT_DIR/api.sh" GET "/v13/deployments/$ITEM_ID" 2>/dev/null) || skip "deployment not fetchable"

# Only failed builds are triage material — READY/BUILDING/CANCELED are not our business.
ready_state=$(jq -r '.readyState // ""' <<<"$deploy_json")
[[ "$ready_state" == "ERROR" ]] || skip "deployment not in error state"

# A deployment errors exactly once — a tracked one means a retrigger or a
# duplicate delivery, and the sha-search dedupe already ran when it was filed.
[[ -f "$STATE_FILE" && "$phase" == "filed" ]] && skip "already processed"

url=$(jq -r '.url // ""' <<<"$deploy_json")
[[ -n "$url" && "$url" != http* ]] && url="https://$url"
# target is "production" or null (preview deploys) — keep it readable downstream.
target=$(jq -r '.target // "preview"' <<<"$deploy_json")
project_id=$(jq -r '.projectId // ""' <<<"$deploy_json")
commit_sha=$(jq -r '.meta.githubCommitSha // ""' <<<"$deploy_json")
commit_ref=$(jq -r '.meta.githubCommitRef // ""' <<<"$deploy_json")
commit_message=$(jq -r '.meta.githubCommitMessage // ""' <<<"$deploy_json")
inspector_url=$(jq -r '.inspectorUrl // ""' <<<"$deploy_json")

jq -cn \
  --arg item_id "$ITEM_ID" \
  --arg decision "analyze" \
  --arg reason "failed deployment" \
  --arg url "$url" \
  --arg target "$target" \
  --arg project_id "$project_id" \
  --arg commit_sha "$commit_sha" \
  --arg commit_ref "$commit_ref" \
  --arg commit_message "$commit_message" \
  --arg inspector_url "$inspector_url" \
  --arg prev_phase "$phase" \
  '{item_id: $item_id, item_type: "Deployment", decision: $decision, reason: $reason,
    url: $url, target: $target, project_id: $project_id,
    commit_sha: $commit_sha, commit_ref: $commit_ref, commit_message: $commit_message,
    inspector_url: $inspector_url, prev_phase: $prev_phase}'
