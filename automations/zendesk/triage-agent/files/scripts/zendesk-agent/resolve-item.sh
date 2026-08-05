#!/usr/bin/env bash
# Decide which playbook (if any) applies to a Zendesk ticket by diffing the
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
last_comment_id=$(jq -r '.last_comment_id // 0' <<<"$state")
phase=$(jq -r '.phase // "new"' <<<"$state")

ticket_json=$("$SCRIPT_DIR/api.sh" GET "/tickets/$ITEM_ID.json" 2>/dev/null) || skip "ticket not fetchable"

status=$(jq -r '.ticket.status // ""' <<<"$ticket_json")
case "$status" in
  solved|closed) skip "ticket $status" ;;
esac
title=$(jq -r '.ticket.subject // ""' <<<"$ticket_json")

# Comment recency is tracked by the numeric comment id (monotonic).
comments=$("$SCRIPT_DIR/api.sh" GET "/tickets/$ITEM_ID/comments.json" 2>/dev/null \
  || echo '{"comments":[]}')
latest_comment_id=$(jq -r '[.comments[].id] | max // 0' <<<"$comments")
# New PUBLIC comments (customer/agent replies) since last seen — the agent's
# own internal notes are private and marker-prefixed, so they never count.
new_human_count=$(jq --argjson last "$last_comment_id" --arg marker "$AGENT_MARKER" \
  '[.comments[] | select(.id > $last)
       | select(.public == true)
       | select(((.body // "") | .[0:120] | contains($marker)) | not)
   ] | length' <<<"$comments")

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
  --argjson latest_comment_id "$latest_comment_id" \
  --argjson new_human_count "$new_human_count" \
  '{item_id: $item_id, item_type: "Ticket", decision: $decision, reason: $reason,
    title: $title, status: $status, prev_phase: $prev_phase,
    latest_comment_id: $latest_comment_id, new_human_count: $new_human_count}'
