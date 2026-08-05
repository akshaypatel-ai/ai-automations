#!/usr/bin/env bash
# Decide which playbook (if any) applies to an Intercom conversation by diffing
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
last_part_at=$(jq -r '.last_part_at // 0' <<<"$state")
phase=$(jq -r '.phase // "new"' <<<"$state")

conversation=$("$SCRIPT_DIR/api.sh" GET "/conversations/$ITEM_ID" 2>/dev/null) || skip "conversation not fetchable"

conv_state=$(jq -r '.state // ""' <<<"$conversation")
case "$conv_state" in
  closed) skip "conversation closed" ;;
esac
title=$(jq -r '.title // ""' <<<"$conversation")

# Part recency is tracked by created_at (epoch seconds) — part ids are strings,
# so numeric ordering by id is unsafe. The conversation's own created_at stands
# in for the source message, which has no part timestamp.
latest_part_at=$(jq -r \
  '([.conversation_parts.conversation_parts[]?.created_at] + [.created_at // 0]) | max // 0' \
  <<<"$conversation")
# New customer parts since last seen — bodies are HTML, so tags are stripped
# before the marker check; the agent's own notes are marker-prefixed and never
# count. The source message counts too while nothing has been seen yet.
new_human_count=$(jq --argjson last "$last_part_at" --arg marker "$AGENT_MARKER" \
  '[.conversation_parts.conversation_parts[]?
       | select((.created_at // 0) > $last)
       | select(.author.type == "user")
       | select((((.body // "") | gsub("<[^>]*>"; "") | .[0:120]) | contains($marker)) | not)
   ] | length + (if $last == 0 then 1 else 0 end)' <<<"$conversation")

decision="skip"
reason="nothing new"
if [[ "$tracked" == 0 ]]; then
  decision="triage"; reason="new conversation"
elif [[ "$new_human_count" -gt 0 ]]; then
  decision="respond"; reason="new customer reply on a tracked conversation"
fi

jq -cn \
  --arg item_id "$ITEM_ID" \
  --arg decision "$decision" \
  --arg reason "$reason" \
  --arg title "$title" \
  --arg state "$conv_state" \
  --arg prev_phase "$phase" \
  --argjson latest_part_at "$latest_part_at" \
  --argjson new_human_count "$new_human_count" \
  '{item_id: $item_id, item_type: "Conversation", decision: $decision, reason: $reason,
    title: $title, state: $state, prev_phase: $prev_phase,
    latest_part_at: $latest_part_at, new_human_count: $new_human_count}'
