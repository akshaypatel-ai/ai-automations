#!/usr/bin/env bash
# Decide which playbook (if any) applies to a ClickUp task by diffing the API
# against saved state. Fully implemented: tasks. Other families the relay
# forwards (lists/folders/goals/time) skip cleanly until their playbooks land.
# Usage: resolve-item.sh <task_id> [item_type]   → prints a one-line decision JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ITEM_ID="$1"
TYPE_HINT="${2:-Task}"
STATE_FILE="$STATE_DIR/state/$ITEM_ID.json"

skip() { # skip <reason>
  jq -cn --arg id "$ITEM_ID" --arg t "$TYPE_HINT" --arg r "$1" \
    '{item_id: $id, item_type: $t, decision: "skip", reason: $r}'
  exit 0
}

[[ "$TYPE_HINT" == "Task" ]] || skip "handler not implemented yet"
[[ ",$ENABLED_HANDLERS," == *",tasks,"* ]] || skip "handler 'tasks' disabled"

state='{}'
[[ -f "$STATE_FILE" ]] && state=$(cat "$STATE_FILE")
prev_status=$(jq -r '.status_name // ""' <<<"$state")
last_comment_date=$(jq -r '.last_comment_date // 0' <<<"$state")
phase=$(jq -r '.phase // "new"' <<<"$state")

task_json=$("$SCRIPT_DIR/api.sh" GET "/task/$ITEM_ID" 2>/dev/null) || skip "task not fetchable"

list_id=$(jq -r '.list.id // ""' <<<"$task_json")
if [[ -n "$CLICKUP_LIST_ID" && "$list_id" != "$CLICKUP_LIST_ID" ]]; then
  skip "outside watched list"
fi
[[ "$(jq -r '.archived // false' <<<"$task_json")" == "true" ]] && skip "task archived"

# Case-insensitive status match (ClickUp statuses are usually lowercase).
status_name=$(jq -r '.status.status // "" | ascii_downcase' <<<"$task_json")
status_type=$(jq -r '.status.type // ""' <<<"$task_json")
title=$(jq -r '.name // ""' <<<"$task_json")
want_analyze=$(printf '%s' "$STATUS_ANALYZE" | tr '[:upper:]' '[:lower:]')
want_implement=$(printf '%s' "$STATUS_IMPLEMENT" | tr '[:upper:]' '[:lower:]')
[[ "$status_type" == "closed" || "$status_type" == "done" ]] && skip "task $status_type"

# Comment recency is tracked by the numeric ms-epoch `date` field.
comments=$("$SCRIPT_DIR/api.sh" GET "/task/$ITEM_ID/comment" 2>/dev/null || echo '{"comments":[]}')
latest_comment_date=$(jq -r '[.comments[].date | tonumber] | max // 0' <<<"$comments")
new_human_count=$(jq --argjson last "$last_comment_date" --arg marker "$AGENT_MARKER" \
  '[.comments[] | select((.date | tonumber) > $last)
     | select(((.comment_text // "") | .[0:120] | contains($marker)) | not)
   ] | length' <<<"$comments")

decision="skip"
reason="nothing new"
if [[ "$status_name" == "$want_analyze" && "$prev_status" != "$want_analyze" ]]; then
  decision="analyze"; reason="task entered the analyze status"
elif [[ "$status_name" == "$want_implement" && "$prev_status" != "$want_implement" ]]; then
  decision="implement"; reason="task entered the implement status"
elif [[ "$new_human_count" -gt 0 && "$status_name" == "$want_analyze" ]]; then
  decision="respond"; reason="new human comment in the analyze status"
elif [[ "$new_human_count" -gt 0 && "$status_name" == "$want_implement" ]]; then
  decision="implement"; reason="new human comment in the implement status"
fi

jq -cn \
  --arg item_id "$ITEM_ID" \
  --arg decision "$decision" \
  --arg reason "$reason" \
  --arg title "$title" \
  --arg status_name "$status_name" \
  --arg prev_status "$prev_status" \
  --arg prev_phase "$phase" \
  --argjson latest_comment_date "$latest_comment_date" \
  --argjson new_human_count "$new_human_count" \
  '{item_id: $item_id, item_type: "Task", decision: $decision, reason: $reason,
    title: $title, status_name: $status_name, prev_status: $prev_status,
    prev_phase: $prev_phase, latest_comment_date: $latest_comment_date,
    new_human_count: $new_human_count}'
