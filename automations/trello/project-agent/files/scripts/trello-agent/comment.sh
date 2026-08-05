#!/usr/bin/env bash
# Post ONE comment on a Trello card.
# Usage: comment.sh <card_id> <body-file | body-string>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CARD_ID="$1"
BODY_ARG="$2"
if [[ -f "$BODY_ARG" ]]; then
  BODY="$(cat "$BODY_ARG")"
else
  BODY="$BODY_ARG"
fi

"$SCRIPT_DIR/api.sh" POST "/1/cards/$CARD_ID/actions/comments" \
  --data-urlencode "text=$BODY" | jq -e '.id' >/dev/null
echo "comment posted on $CARD_ID"
