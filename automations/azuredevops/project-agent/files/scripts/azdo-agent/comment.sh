#!/usr/bin/env bash
# Post ONE comment on an Azure DevOps work item.
# Takes PLAIN TEXT and converts it to the simple HTML the comments API expects.
# Usage: comment.sh <work_item_id> <body-file | body-string>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK_ITEM_ID="$1"
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

# The comments endpoint is still a preview API — pin its api-version explicitly.
"$SCRIPT_DIR/api.sh" POST "/wit/workItems/$WORK_ITEM_ID/comments?api-version=7.1-preview.4" \
  "$(jq -cn --arg t "$HTML" '{text: $t}')" | jq -e '.id' >/dev/null
echo "comment posted on work item $WORK_ITEM_ID"
