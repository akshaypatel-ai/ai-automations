#!/usr/bin/env bash
# Decide which playbook (if any) applies to a Shortcut story by diffing the API
# against saved state. Fully implemented: stories. Other families the relay
# forwards (epics/iterations) skip cleanly until their playbooks land.
# Usage: resolve-item.sh <story_id> [item_type]   → prints a one-line decision JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ITEM_ID="$1"
TYPE_HINT="${2:-Story}"
STATE_FILE="$STATE_DIR/state/$ITEM_ID.json"

skip() { # skip <reason>
  jq -cn --arg id "$ITEM_ID" --arg t "$TYPE_HINT" --arg r "$1" \
    '{item_id: $id, item_type: $t, decision: "skip", reason: $r}'
  exit 0
}

[[ "$TYPE_HINT" == "Story" ]] || skip "handler not implemented yet"
[[ ",$ENABLED_HANDLERS," == *",stories,"* ]] || skip "handler 'stories' disabled"

state='{}'
[[ -f "$STATE_FILE" ]] && state=$(cat "$STATE_FILE")
prev_state=$(jq -r '.state_name // ""' <<<"$state")
last_comment_id=$(jq -r '.last_comment_id // 0' <<<"$state")
phase=$(jq -r '.phase // "new"' <<<"$state")

story_json=$("$SCRIPT_DIR/api.sh" GET "/stories/$ITEM_ID" 2>/dev/null) || skip "story not fetchable"

[[ "$(jq -r '.archived // false' <<<"$story_json")" == "true" ]] && skip "story archived"
[[ "$(jq -r '.completed // false' <<<"$story_json")" == "true" ]] && skip "story completed"

# Stories carry a numeric workflow_state_id — map it to its NAME via /workflows
# (workflow states are Shortcut's board columns; matching is case-insensitive).
workflow_state_id=$(jq -r '.workflow_state_id // ""' <<<"$story_json")
workflows_json=$("$SCRIPT_DIR/api.sh" GET /workflows 2>/dev/null || echo '[]')
state_name=$(jq -r --argjson id "${workflow_state_id:-0}" \
  '[.[].states[] | select(.id == $id) | .name][0] // "" | ascii_downcase' <<<"$workflows_json")
[[ -n "$state_name" ]] || skip "workflow state unknown"

title=$(jq -r '.name // ""' <<<"$story_json")
want_analyze=$(printf '%s' "$STATE_ANALYZE" | tr '[:upper:]' '[:lower:]')
want_implement=$(printf '%s' "$STATE_IMPLEMENT" | tr '[:upper:]' '[:lower:]')

# Comments ride inline on the story fetch; ids are numeric and increasing —
# track the max like Jira/Basecamp.
latest_comment_id=$(jq -r '[.comments[]?.id] | max // 0' <<<"$story_json")
new_human_count=$(jq --argjson last "$last_comment_id" --arg marker "$AGENT_MARKER" \
  '[.comments[]? | select(.id > $last)
     | select(((.text // "") | .[0:120] | contains($marker)) | not)
   ] | length' <<<"$story_json")

decision="skip"
reason="nothing new"
if [[ "$state_name" == "$want_analyze" && "$prev_state" != "$want_analyze" ]]; then
  decision="analyze"; reason="story entered the analyze state"
elif [[ "$state_name" == "$want_implement" && "$prev_state" != "$want_implement" ]]; then
  decision="implement"; reason="story entered the implement state"
elif [[ "$new_human_count" -gt 0 && "$state_name" == "$want_analyze" ]]; then
  decision="respond"; reason="new human comment in the analyze state"
elif [[ "$new_human_count" -gt 0 && "$state_name" == "$want_implement" ]]; then
  decision="implement"; reason="new human comment in the implement state"
fi

jq -cn \
  --arg item_id "$ITEM_ID" \
  --arg decision "$decision" \
  --arg reason "$reason" \
  --arg title "$title" \
  --arg state_name "$state_name" \
  --arg prev_state "$prev_state" \
  --arg prev_phase "$phase" \
  --argjson latest_comment_id "$latest_comment_id" \
  --argjson new_human_count "$new_human_count" \
  '{item_id: $item_id, item_type: "Story", decision: $decision, reason: $reason,
    title: $title, state_name: $state_name, prev_state: $prev_state,
    prev_phase: $prev_phase, latest_comment_id: $latest_comment_id,
    new_human_count: $new_human_count}'
