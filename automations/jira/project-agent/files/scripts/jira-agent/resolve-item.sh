#!/usr/bin/env bash
# Decide which playbook (if any) applies to a Jira issue by diffing the API
# against saved state. Fully implemented: issues. Other families the relay
# forwards (sprints/versions/worklogs) skip cleanly until their playbooks land.
# Usage: resolve-item.sh <issue_key> [item_type]   → prints a one-line decision JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ITEM_ID="$1"
TYPE_HINT="${2:-Issue}"
STATE_FILE="$STATE_DIR/state/$ITEM_ID.json"

skip() { # skip <reason>
  jq -cn --arg id "$ITEM_ID" --arg t "$TYPE_HINT" --arg r "$1" \
    '{item_id: $id, item_type: $t, decision: "skip", reason: $r}'
  exit 0
}

[[ "$TYPE_HINT" == "Issue" ]] || skip "handler not implemented yet"
[[ ",$ENABLED_HANDLERS," == *",issues,"* ]] || skip "handler 'issues' disabled"

state='{}'
[[ -f "$STATE_FILE" ]] && state=$(cat "$STATE_FILE")
prev_status=$(jq -r '.status_name // ""' <<<"$state")
last_comment_id=$(jq -r '.last_comment_id // 0' <<<"$state")
phase=$(jq -r '.phase // "new"' <<<"$state")

issue_json=$("$SCRIPT_DIR/api.sh" GET \
  "/rest/api/2/issue/$ITEM_ID?fields=summary,status,project" 2>/dev/null) || skip "issue not fetchable"

project_key=$(jq -r '.fields.project.key // ""' <<<"$issue_json")
if [[ -n "$JIRA_PROJECT_KEY" && "$project_key" != "$JIRA_PROJECT_KEY" ]]; then
  skip "outside watched project"
fi

status_name=$(jq -r '.fields.status.name // ""' <<<"$issue_json")
status_category=$(jq -r '.fields.status.statusCategory.key // ""' <<<"$issue_json")
title=$(jq -r '.fields.summary // ""' <<<"$issue_json")
[[ "$status_category" == "done" ]] && skip "issue done"

# Jira comment ids are numeric and increasing — track the max like Basecamp.
comments=$("$SCRIPT_DIR/api.sh" GET \
  "/rest/api/2/issue/$ITEM_ID/comment?maxResults=100&orderBy=created" 2>/dev/null || echo '{"comments":[]}')
latest_comment_id=$(jq -r '[.comments[].id | tonumber] | max // 0' <<<"$comments")
new_human_count=$(jq --argjson last "$last_comment_id" --arg marker "$AGENT_MARKER" \
  '[.comments[] | select((.id | tonumber) > $last)
     | select(((.body // "") | .[0:120] | contains($marker)) | not)
   ] | length' <<<"$comments")

decision="skip"
reason="nothing new"
if [[ "$status_name" == "$STATUS_ANALYZE" && "$prev_status" != "$STATUS_ANALYZE" ]]; then
  decision="analyze"; reason="issue entered the analyze status"
elif [[ "$status_name" == "$STATUS_IMPLEMENT" && "$prev_status" != "$STATUS_IMPLEMENT" ]]; then
  decision="implement"; reason="issue entered the implement status"
elif [[ "$new_human_count" -gt 0 && "$status_name" == "$STATUS_ANALYZE" ]]; then
  decision="respond"; reason="new human comment in the analyze status"
elif [[ "$new_human_count" -gt 0 && "$status_name" == "$STATUS_IMPLEMENT" ]]; then
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
  --argjson latest_comment_id "$latest_comment_id" \
  --argjson new_human_count "$new_human_count" \
  '{item_id: $item_id, item_type: "Issue", decision: $decision, reason: $reason,
    title: $title, status_name: $status_name, prev_status: $prev_status,
    prev_phase: $prev_phase, latest_comment_id: $latest_comment_id,
    new_human_count: $new_human_count}'
