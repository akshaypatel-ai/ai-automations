#!/usr/bin/env bash
# Post ONE INTERNAL comment on a Front conversation. Structurally private:
# comments are a separate stream from messages that Front never sends to
# customers — this helper cannot message anyone outside the team.
# Takes PLAIN TEXT and posts it AS IS: Front comments accept plain text /
# markdown, so this is the only triage sibling without an HTML converter.
# Usage: note.sh <conversation_id> <body-file | body-string>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONVERSATION_ID="$1"
BODY_ARG="$2"
if [[ -f "$BODY_ARG" ]]; then
  BODY="$(cat "$BODY_ARG")"
else
  BODY="$BODY_ARG"
fi

"$SCRIPT_DIR/api.sh" POST "/conversations/$CONVERSATION_ID/comments" \
  "$(jq -cn --arg b "$BODY" '{body: $b}')" \
  | jq -e '.id' >/dev/null
echo "internal comment posted on conversation $CONVERSATION_ID"
