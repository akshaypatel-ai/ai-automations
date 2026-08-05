#!/usr/bin/env bash
# Decide which playbook (if any) applies to a monday.com item by diffing the
# API against saved state. Fully implemented: items. Subitem events the relay
# forwards skip cleanly until their playbook lands.
# Usage: resolve-item.sh <item_id> [item_type]   → prints a one-line decision JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ITEM_ID="$1"
TYPE_HINT="${2:-Item}"
STATE_FILE="$STATE_DIR/state/$ITEM_ID.json"

skip() { # skip <reason>
  jq -cn --arg id "$ITEM_ID" --arg t "$TYPE_HINT" --arg r "$1" \
    '{item_id: $id, item_type: $t, decision: "skip", reason: $r}'
  exit 0
}

[[ "$TYPE_HINT" == "Item" ]] || skip "handler not implemented yet"
[[ ",$ENABLED_HANDLERS," == *",items,"* ]] || skip "handler 'items' disabled"

state='{}'
[[ -f "$STATE_FILE" ]] && state=$(cat "$STATE_FILE")
prev_status=$(jq -r '.status_name // ""' <<<"$state")
last_comment_at=$(jq -r '.last_comment_at // ""' <<<"$state")
phase=$(jq -r '.phase // "new"' <<<"$state")

item_resp=$("$SCRIPT_DIR/api.sh" \
  'query ($ids: [ID!], $cols: [String!]) {
     items (ids: $ids) {
       id name state url
       board { id }
       column_values (ids: $cols) { id text }
       updates (limit: 100) { id text_body created_at }
     }
   }' \
  "$(jq -cn --arg id "$ITEM_ID" --arg col "$STATUS_COLUMN_ID" '{ids: [$id], cols: [$col]}')" \
  2>/dev/null) || skip "item not fetchable"

item_json=$(jq '.data.items[0] // empty' <<<"$item_resp")
[[ -n "$item_json" ]] || skip "item not found"

[[ "$(jq -r '.state // "active"' <<<"$item_json")" == "active" ]] || skip "item archived/deleted"

board_id=$(jq -r '.board.id // ""' <<<"$item_json")
if [[ -n "$MONDAY_BOARD_ID" && "$board_id" != "$MONDAY_BOARD_ID" ]]; then
  skip "outside watched board"
fi

title=$(jq -r '.name // ""' <<<"$item_json")
status_name=$(jq -r '.column_values[0].text // "" | ascii_downcase' <<<"$item_json")
want_analyze=$(printf '%s' "$STATUS_ANALYZE" | tr '[:upper:]' '[:lower:]')
want_implement=$(printf '%s' "$STATUS_IMPLEMENT" | tr '[:upper:]' '[:lower:]')

# Comment recency is tracked by the update created_at (ISO-8601, string compare).
comments=$(jq '[.updates[]?]' <<<"$item_json")
latest_comment_at=$(jq -r '[.[].created_at] | max // ""' <<<"$comments")
new_human_count=$(jq --arg last "$last_comment_at" --arg marker "$AGENT_MARKER" \
  '[.[] | select(.created_at > $last)
       | select(((.text_body // "") | .[0:120] | contains($marker)) | not)
   ] | length' <<<"$comments")

decision="skip"
reason="nothing new"
if [[ "$status_name" == "$want_analyze" && "$prev_status" != "$want_analyze" ]]; then
  decision="analyze"; reason="item entered the analyze status"
elif [[ "$status_name" == "$want_implement" && "$prev_status" != "$want_implement" ]]; then
  decision="implement"; reason="item entered the implement status"
elif [[ "$new_human_count" -gt 0 && "$status_name" == "$want_analyze" ]]; then
  decision="respond"; reason="new human update in the analyze status"
elif [[ "$new_human_count" -gt 0 && "$status_name" == "$want_implement" ]]; then
  decision="implement"; reason="new human update in the implement status"
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
  '{item_id: $item_id, item_type: "Item", decision: $decision, reason: $reason,
    title: $title, status_name: $status_name, prev_status: $prev_status,
    prev_phase: $prev_phase, latest_comment_at: $latest_comment_at,
    new_human_count: $new_human_count}'
