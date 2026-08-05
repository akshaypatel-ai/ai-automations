#!/usr/bin/env bash
# Post ONE comment on a Notion page.
# Notion caps rich_text objects at 2000 chars — long bodies are chunked.
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

chunks='[]'
offset=0
len=${#BODY}
while (( offset < len )); do
  part="${BODY:offset:1900}"
  chunks=$(jq -c --arg t "$part" '. + [{text: {content: $t}}]' <<<"$chunks")
  offset=$((offset + 1900))
done

"$SCRIPT_DIR/api.sh" POST "/comments" \
  "$(jq -cn --arg p "$PAGE_ID" --argjson rt "$chunks" '{parent: {page_id: $p}, rich_text: $rt}')" \
  | jq -e '.id' >/dev/null
echo "comment posted on $PAGE_ID"
