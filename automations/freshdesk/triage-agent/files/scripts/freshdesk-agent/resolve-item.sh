#!/usr/bin/env bash
# Decide which playbook (if any) applies to a Freshdesk ticket by diffing the
# API against saved state. Fully implemented: tickets.
# Usage: resolve-item.sh <ticket_id> [item_type]   → prints a one-line decision JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ITEM_ID="$1"
TYPE_HINT="${2:-Ticket}"
STATE_FILE="$STATE_DIR/state/$ITEM_ID.json"

skip() { # skip <reason>
  jq -cn --arg id "$ITEM_ID" --arg t "$TYPE_HINT" --arg r "$1" \
    '{item_id: $id, item_type: $t, decision: "skip", reason: $r}'
  exit 0
}

[[ "$TYPE_HINT" == "Ticket" ]] || skip "handler not implemented yet"
[[ ",$ENABLED_HANDLERS," == *",tickets,"* ]] || skip "handler 'tickets' disabled"

state='{}'
tracked=0
[[ -f "$STATE_FILE" ]] && { state=$(cat "$STATE_FILE"); tracked=1; }
last_conversation_id=$(jq -r '.last_conversation_id // 0' <<<"$state")
phase=$(jq -r '.phase // "new"' <<<"$state")

ticket_json=$("$SCRIPT_DIR/api.sh" GET "/tickets/$ITEM_ID" 2>/dev/null) || skip "ticket not fetchable"

# Freshdesk statuses are numeric: 2=open, 3=pending, 4=resolved, 5=closed.
status_num=$(jq -r '.status // 0' <<<"$ticket_json")
case "$status_num" in
  2) status="open" ;;
  3) status="pending" ;;
  4) skip "ticket resolved" ;;
  5) skip "ticket closed" ;;
  *) status="$status_num" ;;
esac
title=$(jq -r '.subject // ""' <<<"$ticket_json")

# Conversation recency is tracked by the numeric conversation id (monotonic).
# The requester's FIRST message is the ticket's description_text, NOT a
# conversation — untracked tickets go to triage regardless, so nothing is lost.
conversations=$("$SCRIPT_DIR/api.sh" GET "/tickets/$ITEM_ID/conversations" 2>/dev/null \
  || echo '[]')
latest_conversation_id=$(jq -r '[.[].id] | max // 0' <<<"$conversations")
# New PUBLIC conversations (customer/agent replies) since last seen — the
# agent's own notes are private and marker-prefixed, so they never count.
new_human_count=$(jq --argjson last "$last_conversation_id" --arg marker "$AGENT_MARKER" \
  '[.[] | select(.id > $last)
       | select(.private == false)
       | select(((.body_text // "") | .[0:120] | contains($marker)) | not)
   ] | length' <<<"$conversations")

decision="skip"
reason="nothing new"
if [[ "$tracked" == 0 ]]; then
  decision="triage"; reason="new ticket"
elif [[ "$new_human_count" -gt 0 ]]; then
  decision="respond"; reason="new public reply on a tracked ticket"
fi

jq -cn \
  --arg item_id "$ITEM_ID" \
  --arg decision "$decision" \
  --arg reason "$reason" \
  --arg title "$title" \
  --arg status "$status" \
  --arg prev_phase "$phase" \
  --argjson latest_conversation_id "$latest_conversation_id" \
  --argjson new_human_count "$new_human_count" \
  '{item_id: $item_id, item_type: "Ticket", decision: $decision, reason: $reason,
    title: $title, status: $status, prev_phase: $prev_phase,
    latest_conversation_id: $latest_conversation_id, new_human_count: $new_human_count}'
