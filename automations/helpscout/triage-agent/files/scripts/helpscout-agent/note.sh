#!/usr/bin/env bash
# Post ONE INTERNAL note on a Help Scout conversation. Structurally private:
# the /notes endpoint only creates notes — this helper cannot message customers.
# Takes PLAIN TEXT and converts it to the simple HTML Help Scout expects.
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

# Plain text → simple HTML: escape & < > (in that order), then wrap each line
# in <p>…</p> — blank lines become empty paragraphs, i.e. paragraph breaks.
HTML="$(printf '%s\n' "$BODY" \
  | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        -e 's#^#<p>#' -e 's#$#</p>#' \
  | tr -d '\n')"

# A successful create is 201 with an EMPTY body (Resource-ID header only) —
# there is no JSON to verify, so curl's exit status is the whole success check.
"$SCRIPT_DIR/api.sh" POST "/v2/conversations/$CONVERSATION_ID/notes" \
  "$(jq -cn --arg b "$HTML" '{text: $b}')" >/dev/null
echo "internal note posted on conversation $CONVERSATION_ID"
