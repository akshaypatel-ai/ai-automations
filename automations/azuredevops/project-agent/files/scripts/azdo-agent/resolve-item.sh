#!/usr/bin/env bash
# Decide which playbook (if any) applies to an Azure DevOps work item by
# diffing the API against saved state. Fully implemented: workitems.
# Usage: resolve-item.sh <work_item_id> [item_type]   → prints a one-line decision JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ITEM_ID="$1"
TYPE_HINT="${2:-WorkItem}"
STATE_FILE="$STATE_DIR/state/$ITEM_ID.json"

skip() { # skip <reason>
  jq -cn --arg id "$ITEM_ID" --arg t "$TYPE_HINT" --arg r "$1" \
    '{item_id: $id, item_type: $t, decision: "skip", reason: $r}'
  exit 0
}

[[ "$TYPE_HINT" == "WorkItem" ]] || skip "handler not implemented yet"
[[ ",$ENABLED_HANDLERS," == *",workitems,"* ]] || skip "handler 'workitems' disabled"

state='{}'
[[ -f "$STATE_FILE" ]] && state=$(cat "$STATE_FILE")
prev_state=$(jq -r '.state_name // ""' <<<"$state")
last_comment_id=$(jq -r '.last_comment_id // 0' <<<"$state")
phase=$(jq -r '.phase // "new"' <<<"$state")

item_json=$("$SCRIPT_DIR/api.sh" GET "/wit/workitems/$ITEM_ID" 2>/dev/null) || skip "work item not fetchable"

# Case-insensitive state match (states are display names like "New"/"Active").
state_name=$(jq -r '.fields["System.State"] // "" | ascii_downcase' <<<"$item_json")
title=$(jq -r '.fields["System.Title"] // ""' <<<"$item_json")
item_url=$(jq -r '._links.html.href // ""' <<<"$item_json")
want_analyze=$(printf '%s' "$STATE_ANALYZE" | tr '[:upper:]' '[:lower:]')
want_implement=$(printf '%s' "$STATE_IMPLEMENT" | tr '[:upper:]' '[:lower:]')
[[ "$state_name" == "removed" ]] && skip "work item removed"

# Comment ids are numeric and increasing — track the max like Basecamp.
# The comments endpoint is a preview API; pin its api-version explicitly.
comments=$("$SCRIPT_DIR/api.sh" GET "/wit/workItems/$ITEM_ID/comments?api-version=7.1-preview.4" 2>/dev/null || echo '{"comments":[]}')
latest_comment_id=$(jq -r '[.comments[].id] | max // 0' <<<"$comments")
# Comment text is HTML — strip tags before the marker check.
new_human_count=$(jq --argjson last "$last_comment_id" --arg marker "$AGENT_MARKER" \
  '[.comments[] | select(.id > $last)
     | select((((.text // "") | gsub("<[^>]*>"; "")) | .[0:120] | contains($marker)) | not)
   ] | length' <<<"$comments")

decision="skip"
reason="nothing new"
if [[ "$state_name" == "$want_analyze" && "$prev_state" != "$want_analyze" ]]; then
  decision="analyze"; reason="work item entered the analyze state"
elif [[ "$state_name" == "$want_implement" && "$prev_state" != "$want_implement" ]]; then
  decision="implement"; reason="work item entered the implement state"
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
  --arg item_url "$item_url" \
  --argjson latest_comment_id "$latest_comment_id" \
  --argjson new_human_count "$new_human_count" \
  '{item_id: $item_id, item_type: "WorkItem", decision: $decision, reason: $reason,
    title: $title, state_name: $state_name, prev_state: $prev_state,
    prev_phase: $prev_phase, latest_comment_id: $latest_comment_id,
    new_human_count: $new_human_count, item_url: $item_url}'
