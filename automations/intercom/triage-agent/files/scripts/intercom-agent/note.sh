#!/usr/bin/env bash
# Post ONE INTERNAL note on an Intercom conversation. Structurally private:
# message_type is hardcoded to "note" — this helper cannot message customers.
# Takes PLAIN TEXT and converts it to the simple HTML Intercom expects.
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

# Notes are attributed to an admin — resolve the token owner's id at runtime.
ADMIN_ID="$("$SCRIPT_DIR/api.sh" GET /me | jq -r '.id // empty')"
[[ -n "$ADMIN_ID" ]] || { echo "error: could not resolve admin id from /me" >&2; exit 1; }

# Plain text → simple HTML: escape & < > (in that order), then wrap each line
# in <p>…</p> — blank lines become empty paragraphs, i.e. paragraph breaks.
HTML="$(printf '%s\n' "$BODY" \
  | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        -e 's#^#<p>#' -e 's#$#</p>#' \
  | tr -d '\n')"

"$SCRIPT_DIR/api.sh" POST "/conversations/$CONVERSATION_ID/reply" \
  "$(jq -cn --arg admin "$ADMIN_ID" --arg b "$HTML" \
      '{message_type: "note", type: "admin", admin_id: $admin, body: $b}')" \
  | jq -e '.id' >/dev/null
echo "internal note posted on conversation $CONVERSATION_ID"
