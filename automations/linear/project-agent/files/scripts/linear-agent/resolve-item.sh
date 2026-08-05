#!/usr/bin/env bash
# Decide which playbook (if any) applies to a Linear item by diffing the API
# against saved state. Fully implemented: issues. Other resource types the
# relay forwards (Project/Cycle/Document) skip cleanly until their playbooks land.
# Usage: resolve-item.sh <item_id> [item_type]   → prints a one-line decision JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ITEM_ID="$1"
TYPE_HINT="${2:-Issue}"
STATE_FILE="$STATE_DIR/state/$ITEM_ID.json"

skip() { # skip <item_type> <reason>
  jq -cn --arg id "$ITEM_ID" --arg t "$1" --arg r "$2" \
    '{item_id: $id, item_type: $t, decision: "skip", reason: $r}'
  exit 0
}

case "$TYPE_HINT" in
  Issue) ;;
  Project|Cycle|Document) skip "$TYPE_HINT" "handler not implemented yet" ;;
  *) skip "$TYPE_HINT" "no handler for type" ;;
esac
[[ ",$ENABLED_HANDLERS," == *",issues,"* ]] || skip "Issue" "handler 'issues' disabled"

state='{}'
[[ -f "$STATE_FILE" ]] && state=$(cat "$STATE_FILE")
prev_state=$(jq -r '.state_name // ""' <<<"$state")
last_comment_at=$(jq -r '.last_comment_at // "1970-01-01T00:00:00.000Z"' <<<"$state")
phase=$(jq -r '.phase // "new"' <<<"$state")

issue_json=$("$SCRIPT_DIR/api.sh" \
  'query($id: String!) { issue(id: $id) {
      id identifier title url
      state { name type }
      team { key }
      comments(first: 100) { nodes { id body createdAt } }
  } }' "$(jq -cn --arg id "$ITEM_ID" '{id: $id}')" 2>/dev/null) || skip "Issue" "issue not fetchable"

issue=$(jq '.data.issue' <<<"$issue_json")
[[ "$issue" == "null" ]] && skip "Issue" "issue not found"

team_key=$(jq -r '.team.key // ""' <<<"$issue")
if [[ -n "$LINEAR_TEAM_KEY" && "$team_key" != "$LINEAR_TEAM_KEY" ]]; then
  skip "Issue" "outside watched team"
fi

state_name=$(jq -r '.state.name // ""' <<<"$issue")
state_type=$(jq -r '.state.type // ""' <<<"$issue")
identifier=$(jq -r '.identifier // ""' <<<"$issue")
title=$(jq -r '.title // ""' <<<"$issue")
[[ "$state_type" == "completed" || "$state_type" == "canceled" ]] && skip "Issue" "issue $state_type"

# Linear comment ids are UUIDs, so "newer" is tracked by createdAt (ISO-8601
# strings compare correctly as text). Marker-prefixed bodies are the agent's own.
latest_comment_at=$(jq -r '[.comments.nodes[].createdAt] | max // "1970-01-01T00:00:00.000Z"' <<<"$issue")
new_human_count=$(jq --arg last "$last_comment_at" --arg marker "$AGENT_MARKER" \
  '[.comments.nodes[] | select(.createdAt > $last)
     | select(((.body // "") | .[0:120] | contains($marker)) | not)
   ] | length' <<<"$issue")

decision="skip"
reason="nothing new"
if [[ "$state_name" == "$STATE_ANALYZE" && "$prev_state" != "$STATE_ANALYZE" ]]; then
  decision="analyze"; reason="issue entered the analyze state"
elif [[ "$state_name" == "$STATE_IMPLEMENT" && "$prev_state" != "$STATE_IMPLEMENT" ]]; then
  decision="implement"; reason="issue entered the implement state"
elif [[ "$new_human_count" -gt 0 && "$state_name" == "$STATE_ANALYZE" ]]; then
  decision="respond"; reason="new human comment in the analyze state"
elif [[ "$new_human_count" -gt 0 && "$state_name" == "$STATE_IMPLEMENT" ]]; then
  decision="implement"; reason="new human comment in the implement state"
fi

jq -cn \
  --arg item_id "$ITEM_ID" \
  --arg decision "$decision" \
  --arg reason "$reason" \
  --arg identifier "$identifier" \
  --arg title "$title" \
  --arg state_name "$state_name" \
  --arg prev_state "$prev_state" \
  --arg prev_phase "$phase" \
  --arg latest_comment_at "$latest_comment_at" \
  --argjson new_human_count "$new_human_count" \
  '{item_id: $item_id, item_type: "Issue", decision: $decision, reason: $reason,
    identifier: $identifier, title: $title, state_name: $state_name,
    prev_state: $prev_state, prev_phase: $prev_phase,
    latest_comment_at: $latest_comment_at, new_human_count: $new_human_count}'
