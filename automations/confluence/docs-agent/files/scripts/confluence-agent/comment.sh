#!/usr/bin/env bash
# Post ONE footer comment on a Confluence page — the agent's only write
# surface (it never edits pages and never touches labels). Takes PLAIN TEXT
# and converts it to the storage-format XHTML Confluence expects.
# Usage: comment.sh <page_id> <body-file | body-string>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PAGE_ID="$1"
BODY_ARG="$2"
if [[ -f "$BODY_ARG" ]]; then
  BODY="$(cat "$BODY_ARG")"
else
  BODY="$BODY_ARG"
fi

# Plain text → storage XHTML: escape & < > (in that order), then wrap each
# line in <p>…</p> — blank lines become empty paragraphs, i.e. paragraph breaks.
XHTML="$(printf '%s\n' "$BODY" \
  | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        -e 's#^#<p>#' -e 's#$#</p>#' \
  | tr -d '\n')"

"$SCRIPT_DIR/api.sh" POST "/api/v2/footer-comments" \
  "$(jq -cn --arg page "$PAGE_ID" --arg b "$XHTML" \
      '{pageId: $page, body: {representation: "storage", value: $b}}')" \
  | jq -e '.id' >/dev/null
echo "footer comment posted on page $PAGE_ID"
