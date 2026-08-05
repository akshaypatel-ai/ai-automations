#!/usr/bin/env bash
# Decide which playbook (if any) applies to a Trello card by diffing the API
# against saved state. Fully implemented: cards. Other families the relay
# forwards (lists/members/checklists) skip cleanly until their playbooks land.
# Usage: resolve-item.sh <card_id> [item_type]   → prints a one-line decision JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ITEM_ID="$1"
TYPE_HINT="${2:-Card}"
STATE_FILE="$STATE_DIR/state/$ITEM_ID.json"

skip() { # skip <reason>
  jq -cn --arg id "$ITEM_ID" --arg t "$TYPE_HINT" --arg r "$1" \
    '{item_id: $id, item_type: $t, decision: "skip", reason: $r}'
  exit 0
}

[[ "$TYPE_HINT" == "Card" ]] || skip "handler not implemented yet"
[[ ",$ENABLED_HANDLERS," == *",cards,"* ]] || skip "handler 'cards' disabled"

state='{}'
[[ -f "$STATE_FILE" ]] && state=$(cat "$STATE_FILE")
prev_list=$(jq -r '.list_id // ""' <<<"$state")
last_comment_date=$(jq -r '.last_comment_date // "1970-01-01T00:00:00.000Z"' <<<"$state")
phase=$(jq -r '.phase // "new"' <<<"$state")

card_json=$("$SCRIPT_DIR/api.sh" GET "/1/cards/$ITEM_ID?fields=name,idList,idShort,closed,shortUrl,idBoard" 2>/dev/null) \
  || skip "card not fetchable"

board_id=$(jq -r '.idBoard // ""' <<<"$card_json")
if [[ -n "$TRELLO_BOARD_ID" && "$board_id" != "$TRELLO_BOARD_ID" ]]; then
  skip "outside watched board"
fi
[[ "$(jq -r '.closed // false' <<<"$card_json")" == "true" ]] && skip "card archived"

list_id=$(jq -r '.idList // ""' <<<"$card_json")
title=$(jq -r '.name // ""' <<<"$card_json")

# Comment recency is tracked by action date (ISO-8601 strings compare as text).
# Marker-prefixed comment text is the agent's own.
comments=$("$SCRIPT_DIR/api.sh" GET "/1/cards/$ITEM_ID/actions?filter=commentCard&limit=100" 2>/dev/null || echo '[]')
latest_comment_date=$(jq -r '[(. // [])[].date] | max // "1970-01-01T00:00:00.000Z"' <<<"$comments")
new_human_count=$(jq --arg last "$last_comment_date" --arg marker "$AGENT_MARKER" \
  '[(. // [])[] | select(.date > $last)
     | select(((.data.text // "") | .[0:120] | contains($marker)) | not)
   ] | length' <<<"$comments")

decision="skip"
reason="nothing new"
if [[ "$list_id" == "$LIST_ANALYZE_ID" && "$prev_list" != "$LIST_ANALYZE_ID" ]]; then
  decision="analyze"; reason="card entered the analyze list"
elif [[ "$list_id" == "$LIST_IMPLEMENT_ID" && "$prev_list" != "$LIST_IMPLEMENT_ID" ]]; then
  decision="implement"; reason="card entered the implement list"
elif [[ "$new_human_count" -gt 0 && "$list_id" == "$LIST_ANALYZE_ID" ]]; then
  decision="respond"; reason="new human comment in the analyze list"
elif [[ "$new_human_count" -gt 0 && "$list_id" == "$LIST_IMPLEMENT_ID" ]]; then
  decision="implement"; reason="new human comment in the implement list"
fi

jq -cn \
  --arg item_id "$ITEM_ID" \
  --arg decision "$decision" \
  --arg reason "$reason" \
  --arg title "$title" \
  --arg list_id "$list_id" \
  --arg prev_list "$prev_list" \
  --arg prev_phase "$phase" \
  --arg latest_comment_date "$latest_comment_date" \
  --argjson id_short "$(jq '.idShort // 0' <<<"$card_json")" \
  --argjson new_human_count "$new_human_count" \
  '{item_id: $item_id, item_type: "Card", decision: $decision, reason: $reason,
    title: $title, id_short: $id_short, list_id: $list_id, prev_list: $prev_list,
    prev_phase: $prev_phase, latest_comment_date: $latest_comment_date,
    new_human_count: $new_human_count}'
