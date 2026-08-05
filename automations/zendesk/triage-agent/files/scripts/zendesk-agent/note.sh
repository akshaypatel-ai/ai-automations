#!/usr/bin/env bash
# Post ONE INTERNAL note on a Zendesk ticket. Structurally private:
# public is hardcoded false — this helper cannot send customer-facing replies.
# Usage: note.sh <ticket_id> <body-file | body-string>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TICKET_ID="$1"
BODY_ARG="$2"
if [[ -f "$BODY_ARG" ]]; then
  BODY="$(cat "$BODY_ARG")"
else
  BODY="$BODY_ARG"
fi

"$SCRIPT_DIR/api.sh" PUT "/tickets/$TICKET_ID.json" \
  "$(jq -cn --arg b "$BODY" '{ticket: {comment: {body: $b, public: false}}}')" \
  | jq -e '.ticket.id' >/dev/null
echo "internal note posted on ticket $TICKET_ID"
