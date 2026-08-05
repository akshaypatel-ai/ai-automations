#!/usr/bin/env bash
# Post ONE comment on an Airtable record.
# Usage: comment.sh <record_id> <body-file | body-string>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

RECORD_ID="$1"
BODY_ARG="$2"
if [[ -f "$BODY_ARG" ]]; then
  BODY="$(cat "$BODY_ARG")"
else
  BODY="$BODY_ARG"
fi

"$SCRIPT_DIR/api.sh" POST "/$AIRTABLE_BASE_ID/$AIRTABLE_TABLE_ID/$RECORD_ID/comments" \
  "$(jq -cn --arg t "$BODY" '{text: $t}')" | jq -e '.id' >/dev/null
echo "comment posted on $RECORD_ID"
