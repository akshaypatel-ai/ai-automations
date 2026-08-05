#!/usr/bin/env bash
# Decide which playbook (if any) applies to a Front conversation by diffing
# the API against saved state. Fully implemented: conversations.
# Usage: resolve-item.sh <conversation_id> [item_type]   → prints a one-line decision JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ITEM_ID="$1"
TYPE_HINT="${2:-Conversation}"
STATE_FILE="$STATE_DIR/state/$ITEM_ID.json"

skip() { # skip <reason>
  jq -cn --arg id "$ITEM_ID" --arg t "$TYPE_HINT" --arg r "$1" \
    '{item_id: $id, item_type: $t, decision: "skip", reason: $r}'
  exit 0
}

[[ "$TYPE_HINT" == "Conversation" ]] || skip "handler not implemented yet"
[[ ",$ENABLED_HANDLERS," == *",conversations,"* ]] || skip "handler 'conversations' disabled"

state='{}'
tracked=0
[[ -f "$STATE_FILE" ]] && { state=$(cat "$STATE_FILE"); tracked=1; }
last_message_at=$(jq -r '.last_message_at // 0' <<<"$state")
phase=$(jq -r '.phase // "new"' <<<"$state")

conversation=$("$SCRIPT_DIR/api.sh" GET "/conversations/$ITEM_ID" 2>/dev/null) || skip "conversation not fetchable"

status=$(jq -r '.status // ""' <<<"$conversation")
case "$status" in
  archived) skip "conversation archived" ;;
  deleted)  skip "conversation deleted" ;;
  spam)     skip "conversation is spam" ;;
esac
title=$(jq -r '.subject // ""' <<<"$conversation")

# Message recency is tracked by created_at — an epoch FLOAT (e.g.
# 1722945600.123) — so every comparison stays in jq as a number (--argjson);
# bash never touches it.
messages=$("$SCRIPT_DIR/api.sh" GET "/conversations/$ITEM_ID/messages" 2>/dev/null \
  || echo '{}')
messages=$(jq '._results // []' <<<"$messages")
latest_message_at=$(jq -r '[.[].created_at] | max // 0' <<<"$messages")
# New human messages since last seen: inbound (is_inbound true) is the
# customer, outbound a teammate reply — exactly the human-handled signal the
# respond playbook goes silent on; drafts never count. No marker check needed:
# the agent writes COMMENTS, which never appear in the message list, so loop
# protection is structural.
new_human_count=$(jq --argjson last "$last_message_at" \
  '[.[] | select((.created_at // 0) > $last)
       | select(.is_draft != true)
   ] | length' <<<"$messages")

decision="skip"
reason="nothing new"
if [[ "$tracked" == 0 ]]; then
  decision="triage"; reason="new conversation"
elif [[ "$new_human_count" -gt 0 ]]; then
  decision="respond"; reason="new message on a tracked conversation"
fi

jq -cn \
  --arg item_id "$ITEM_ID" \
  --arg decision "$decision" \
  --arg reason "$reason" \
  --arg title "$title" \
  --arg status "$status" \
  --arg prev_phase "$phase" \
  --argjson latest_message_at "$latest_message_at" \
  --argjson new_human_count "$new_human_count" \
  '{item_id: $item_id, item_type: "Conversation", decision: $decision, reason: $reason,
    title: $title, status: $status, prev_phase: $prev_phase,
    latest_message_at: $latest_message_at, new_human_count: $new_human_count}'
