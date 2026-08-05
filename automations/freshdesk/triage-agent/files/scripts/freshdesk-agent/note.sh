#!/usr/bin/env bash
# Post ONE PRIVATE note on a Freshdesk ticket. Structurally private:
# private is hardcoded true — this helper cannot send customer-facing replies.
# Takes PLAIN TEXT and converts it to the simple HTML Freshdesk expects.
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

# Plain text → simple HTML: escape & < > (in that order), then wrap each line
# in <p>…</p> — blank lines become empty paragraphs, i.e. paragraph breaks.
HTML="$(printf '%s\n' "$BODY" \
  | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        -e 's#^#<p>#' -e 's#$#</p>#' \
  | tr -d '\n')"

"$SCRIPT_DIR/api.sh" POST "/tickets/$TICKET_ID/notes" \
  "$(jq -cn --arg b "$HTML" '{body: $b, private: true}')" \
  | jq -e '.id' >/dev/null
echo "private note posted on ticket $TICKET_ID"
