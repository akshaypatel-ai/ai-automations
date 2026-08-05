#!/usr/bin/env bash
# Post ONE update (comment) on a monday.com item.
# Usage: comment.sh <item_id> <body-file | body-string>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ITEM_ID="$1"
BODY_ARG="$2"
if [[ -f "$BODY_ARG" ]]; then
  BODY="$(cat "$BODY_ARG")"
else
  BODY="$BODY_ARG"
fi

"$SCRIPT_DIR/api.sh" \
  'mutation ($item: ID!, $body: String!) { create_update (item_id: $item, body: $body) { id } }' \
  "$(jq -cn --arg i "$ITEM_ID" --arg b "$BODY" '{item: $i, body: $b}')" \
  | jq -e '.data.create_update.id' >/dev/null
echo "update posted on $ITEM_ID"
