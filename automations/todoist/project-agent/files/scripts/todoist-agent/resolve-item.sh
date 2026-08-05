#!/usr/bin/env bash
# Decide which playbook (if any) applies to a Todoist task by diffing the API
# against saved state. Fully implemented: tasks. Other families the relay
# forwards (projects/sections) skip cleanly until their playbooks land.
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
prev_section=$(jq -r '.section_name // ""' <<<"$state")
last_comment_at=$(jq -r '.last_comment_at // ""' <<<"$state")
phase=$(jq -r '.phase // "new"' <<<"$state")

task_json=$("$SCRIPT_DIR/api.sh" GET "/tasks/$ITEM_ID" 2>/dev/null) || skip "task not fetchable"

[[ "$(jq -r '.is_completed // false' <<<"$task_json")" == "true" ]] && skip "task completed"
[[ "$(jq -r '.project_id // ""' <<<"$task_json")" == "$TODOIST_PROJECT_ID" ]] || skip "outside watched project"

# The board columns are sections; the task carries only a section_id, so map
# id → name via the project's section list (case-insensitive matching).
section_id=$(jq -r '.section_id // ""' <<<"$task_json")
[[ -z "$section_id" ]] && skip "no section (list view)"
section_name=$("$SCRIPT_DIR/api.sh" GET "/sections?project_id=$TODOIST_PROJECT_ID" 2>/dev/null \
  | jq -r --arg id "$section_id" '[.[] | select(.id == $id) | .name][0] // "" | ascii_downcase' \
  || echo "")
[[ -z "$section_name" ]] && skip "section not found in watched project"

title=$(jq -r '.content // ""' <<<"$task_json")
want_analyze=$(printf '%s' "$SECTION_ANALYZE" | tr '[:upper:]' '[:lower:]')
want_implement=$(printf '%s' "$SECTION_IMPLEMENT" | tr '[:upper:]' '[:lower:]')

# Comment recency is tracked by posted_at (ISO-8601, string compare).
comments=$("$SCRIPT_DIR/api.sh" GET "/comments?task_id=$ITEM_ID" 2>/dev/null || echo '[]')
latest_comment_at=$(jq -r '[.[].posted_at] | max // ""' <<<"$comments")
new_human_count=$(jq --arg last "$last_comment_at" --arg marker "$AGENT_MARKER" \
  '[.[] | select(.posted_at > $last)
       | select(((.content // "") | .[0:120] | contains($marker)) | not)
   ] | length' <<<"$comments")

decision="skip"
reason="nothing new"
if [[ "$section_name" == "$want_analyze" && "$prev_section" != "$want_analyze" ]]; then
  decision="analyze"; reason="task entered the analyze section"
elif [[ "$section_name" == "$want_implement" && "$prev_section" != "$want_implement" ]]; then
  decision="implement"; reason="task entered the implement section"
elif [[ "$new_human_count" -gt 0 && "$section_name" == "$want_analyze" ]]; then
  decision="respond"; reason="new human comment in the analyze section"
elif [[ "$new_human_count" -gt 0 && "$section_name" == "$want_implement" ]]; then
  decision="implement"; reason="new human comment in the implement section"
fi

jq -cn \
  --arg item_id "$ITEM_ID" \
  --arg decision "$decision" \
  --arg reason "$reason" \
  --arg title "$title" \
  --arg section_name "$section_name" \
  --arg prev_section "$prev_section" \
  --arg prev_phase "$phase" \
  --arg latest_comment_at "$latest_comment_at" \
  --argjson new_human_count "$new_human_count" \
  '{item_id: $item_id, item_type: "Task", decision: $decision, reason: $reason,
    title: $title, section_name: $section_name, prev_section: $prev_section,
    prev_phase: $prev_phase, latest_comment_at: $latest_comment_at,
    new_human_count: $new_human_count}'
