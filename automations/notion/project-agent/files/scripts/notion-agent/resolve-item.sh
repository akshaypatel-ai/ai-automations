#!/usr/bin/env bash
# Decide which playbook (if any) applies to a Notion page by diffing the API
# against saved state. Fully implemented: pages. Database (schema) events the
# relay forwards skip cleanly until their playbook lands.
# Usage: resolve-item.sh <page_id> [item_type]   → prints a one-line decision JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ITEM_ID="$1"
TYPE_HINT="${2:-Page}"
STATE_FILE="$STATE_DIR/state/$ITEM_ID.json"

skip() { # skip <reason>
  jq -cn --arg id "$ITEM_ID" --arg t "$TYPE_HINT" --arg r "$1" \
    '{item_id: $id, item_type: $t, decision: "skip", reason: $r}'
  exit 0
}

norm() { printf '%s' "$1" | tr -d '-' | tr '[:upper:]' '[:lower:]'; }

[[ "$TYPE_HINT" == "Page" ]] || skip "handler not implemented yet"
[[ ",$ENABLED_HANDLERS," == *",pages,"* ]] || skip "handler 'pages' disabled"

state='{}'
[[ -f "$STATE_FILE" ]] && state=$(cat "$STATE_FILE")
prev_status=$(jq -r '.status_name // ""' <<<"$state")
last_comment_at=$(jq -r '.last_comment_at // ""' <<<"$state")
phase=$(jq -r '.phase // "new"' <<<"$state")

page_json=$("$SCRIPT_DIR/api.sh" GET "/pages/$ITEM_ID" 2>/dev/null) || skip "page not fetchable"

[[ "$(jq -r '.archived // false' <<<"$page_json")" == "true" ]] && skip "page archived"

parent_db=$(jq -r '.parent.database_id // ""' <<<"$page_json")
if [[ -n "$NOTION_DATABASE_ID" && "$(norm "$parent_db")" != "$(norm "$NOTION_DATABASE_ID")" ]]; then
  skip "outside watched database"
fi

# Status works for both `status` and `select` property types.
status_name=$(jq -r --arg p "$STATUS_PROP" \
  '.properties[$p] | (.status.name // .select.name // "") | ascii_downcase' <<<"$page_json")
title=$(jq -r '[.properties[] | select(.type == "title") | .title[].plain_text] | join("")' <<<"$page_json")
want_analyze=$(printf '%s' "$STATUS_ANALYZE" | tr '[:upper:]' '[:lower:]')
want_implement=$(printf '%s' "$STATUS_IMPLEMENT" | tr '[:upper:]' '[:lower:]')

# Comment recency is tracked by created_time (ISO-8601, string compare).
comments=$("$SCRIPT_DIR/api.sh" GET "/comments?block_id=$ITEM_ID&page_size=100" 2>/dev/null \
  || echo '{"results":[]}')
latest_comment_at=$(jq -r '[.results[].created_time] | max // ""' <<<"$comments")
new_human_count=$(jq --arg last "$last_comment_at" --arg marker "$AGENT_MARKER" \
  '[.results[] | select(.created_time > $last)
       | select((([.rich_text[].plain_text] | join("") | .[0:120]) | contains($marker)) | not)
   ] | length' <<<"$comments")

decision="skip"
reason="nothing new"
if [[ "$status_name" == "$want_analyze" && "$prev_status" != "$want_analyze" ]]; then
  decision="analyze"; reason="page entered the analyze status"
elif [[ "$status_name" == "$want_implement" && "$prev_status" != "$want_implement" ]]; then
  decision="implement"; reason="page entered the implement status"
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
  --arg latest_comment_at "$latest_comment_at" \
  --argjson new_human_count "$new_human_count" \
  '{item_id: $item_id, item_type: "Page", decision: $decision, reason: $reason,
    title: $title, status_name: $status_name, prev_status: $prev_status,
    prev_phase: $prev_phase, latest_comment_at: $latest_comment_at,
    new_human_count: $new_human_count}'
