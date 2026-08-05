#!/usr/bin/env bash
# Decide which playbook (if any) applies to a Help Scout conversation by
# diffing the API against saved state. Fully implemented: conversations.
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
last_thread_id=$(jq -r '.last_thread_id // 0' <<<"$state")
phase=$(jq -r '.phase // "new"' <<<"$state")

conversation=$("$SCRIPT_DIR/api.sh" GET "/v2/conversations/$ITEM_ID" 2>/dev/null) || skip "conversation not fetchable"

status=$(jq -r '.status // ""' <<<"$conversation")
case "$status" in
  closed) skip "conversation closed" ;;
  spam)   skip "conversation is spam" ;;
esac
title=$(jq -r '.subject // ""' <<<"$conversation")

# Thread recency is tracked by the numeric thread id (monotonic).
threads=$("$SCRIPT_DIR/api.sh" GET "/v2/conversations/$ITEM_ID/threads" 2>/dev/null \
  || echo '{}')
threads=$(jq '._embedded.threads // []' <<<"$threads")
latest_thread_id=$(jq -r '[.[].id] | max // 0' <<<"$threads")
# New HUMAN threads since last seen: type "customer" is a customer message,
# "message" an agent public reply — "note" and "lineitem" (system events) never
# count. The agent's own notes are type "note" AND marker-prefixed; bodies are
# HTML, so tags are stripped before the marker check (defense-in-depth).
new_human_count=$(jq --argjson last "$last_thread_id" --arg marker "$AGENT_MARKER" \
  '[.[] | select(.id > $last)
       | select(.type == "customer" or .type == "message")
       | select((((.body // "") | gsub("<[^>]*>"; "") | .[0:120]) | contains($marker)) | not)
   ] | length' <<<"$threads")

decision="skip"
reason="nothing new"
if [[ "$tracked" == 0 ]]; then
  decision="triage"; reason="new conversation"
elif [[ "$new_human_count" -gt 0 ]]; then
  decision="respond"; reason="new reply on a tracked conversation"
fi

jq -cn \
  --arg item_id "$ITEM_ID" \
  --arg decision "$decision" \
  --arg reason "$reason" \
  --arg title "$title" \
  --arg status "$status" \
  --arg prev_phase "$phase" \
  --argjson latest_thread_id "$latest_thread_id" \
  --argjson new_human_count "$new_human_count" \
  '{item_id: $item_id, item_type: "Conversation", decision: $decision, reason: $reason,
    title: $title, status: $status, prev_phase: $prev_phase,
    latest_thread_id: $latest_thread_id, new_human_count: $new_human_count}'
