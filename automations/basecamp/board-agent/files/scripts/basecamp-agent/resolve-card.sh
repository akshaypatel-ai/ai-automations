#!/usr/bin/env bash
# Decide which playbook (if any) applies to a card by diffing Basecamp against saved state.
# Usage: resolve-card.sh <card_id>   → prints a one-line decision JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

CARD_ID="$1"
STATE_FILE="$STATE_DIR/state/$CARD_ID.json"

card_json=$(basecamp cards show "$CARD_ID" --in "$BC_PROJECT_ID" --agent 2>/dev/null) || {
  jq -cn --argjson id "$CARD_ID" '{card_id: $id, decision: "skip", reason: "card not fetchable"}'
  exit 0
}

column_id=$(jq -r '.parent.id // 0' <<<"$card_json")
title=$(jq -r '.title // ""' <<<"$card_json")

state='{}'
[[ -f "$STATE_FILE" ]] && state=$(cat "$STATE_FILE")
prev_column=$(jq -r '.column_id // 0' <<<"$state")
last_comment_id=$(jq -r '.last_comment_id // 0' <<<"$state")
phase=$(jq -r '.phase // "new"' <<<"$state")

comments=$(basecamp comments list "$CARD_ID" --in "$BC_PROJECT_ID" --all --agent 2>/dev/null || echo '[]')
latest_comment_id=$(jq -r '[(. // [])[].id] | max // 0' <<<"$comments")

# A comment is the agent's own when the marker appears near the start of the
# tag-stripped body; everything else counts as human input.
new_human_count=$(jq --argjson last "$last_comment_id" --arg marker "$AGENT_MARKER" \
  '[(. // [])[] | select(.id > $last)
       | select((((.content // "") | gsub("<[^>]*>"; "") | .[0:120] | contains($marker))) | not)
   ] | length' <<<"$comments")

decision="skip"
reason="nothing new"
if [[ "$column_id" == "$BC_COL_ANALYZE" && "$prev_column" != "$BC_COL_ANALYZE" ]]; then
  decision="analyze"; reason="card entered the analyze column"
elif [[ "$column_id" == "$BC_COL_IMPLEMENT" && "$prev_column" != "$BC_COL_IMPLEMENT" ]]; then
  decision="implement"; reason="card entered the implement column"
elif [[ "$new_human_count" -gt 0 && "$column_id" == "$BC_COL_ANALYZE" ]]; then
  decision="respond"; reason="new human comment in the analyze column"
elif [[ "$new_human_count" -gt 0 && "$column_id" == "$BC_COL_IMPLEMENT" ]]; then
  decision="implement"; reason="new human comment in the implement column"
fi

jq -cn \
  --argjson card_id "$CARD_ID" \
  --arg decision "$decision" \
  --arg reason "$reason" \
  --arg title "$title" \
  --arg prev_phase "$phase" \
  --argjson column_id "$column_id" \
  --argjson prev_column "$prev_column" \
  --argjson latest_comment_id "$latest_comment_id" \
  --argjson new_human_count "$new_human_count" \
  '{card_id: $card_id, decision: $decision, reason: $reason, title: $title,
    column_id: $column_id, prev_column: $prev_column, prev_phase: $prev_phase,
    latest_comment_id: $latest_comment_id, new_human_count: $new_human_count}'
