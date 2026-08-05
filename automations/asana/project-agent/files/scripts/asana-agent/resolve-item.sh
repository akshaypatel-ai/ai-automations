#!/usr/bin/env bash
# Decide which playbook (if any) applies to an Asana task by diffing the API
# against saved state. Fully implemented: tasks. Other families the relay
# forwards (sections/projects) skip cleanly until their playbooks land.
# Usage: resolve-item.sh <task_gid> [item_type]   → prints a one-line decision JSON.
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

task_json=$("$SCRIPT_DIR/api.sh" GET \
  "/tasks/$ITEM_ID?opt_fields=name,completed,permalink_url,memberships.project.gid,memberships.section.name" \
  2>/dev/null) || skip "task not fetchable"

[[ "$(jq -r '.data.completed // false' <<<"$task_json")" == "true" ]] && skip "task completed"

# The task's section within OUR project (tasks can live in many projects).
section_name=$(jq -r --arg p "$ASANA_PROJECT_GID" \
  '[.data.memberships[]? | select(.project.gid == $p) | .section.name][0] // "" | ascii_downcase' \
  <<<"$task_json")
[[ -z "$section_name" ]] && skip "outside watched project"

title=$(jq -r '.data.name // ""' <<<"$task_json")
want_analyze=$(printf '%s' "$SECTION_ANALYZE" | tr '[:upper:]' '[:lower:]')
want_implement=$(printf '%s' "$SECTION_IMPLEMENT" | tr '[:upper:]' '[:lower:]')

# Comment recency is tracked by the story created_at (ISO-8601, string compare).
stories=$("$SCRIPT_DIR/api.sh" GET \
  "/tasks/$ITEM_ID/stories?opt_fields=created_at,text,resource_subtype" 2>/dev/null \
  || echo '{"data":[]}')
comments=$(jq '[.data[] | select(.resource_subtype == "comment_added")]' <<<"$stories")
latest_comment_at=$(jq -r '[.[].created_at] | max // ""' <<<"$comments")
new_human_count=$(jq --arg last "$last_comment_at" --arg marker "$AGENT_MARKER" \
  '[.[] | select(.created_at > $last)
       | select(((.text // "") | .[0:120] | contains($marker)) | not)
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
