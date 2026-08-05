#!/usr/bin/env bash
# Post ONE comment on a Linear issue. Body is read from a file (safest for
# multi-line markdown) or taken as a literal string.
# Usage: comment.sh <issue_id> <body-file | body-string>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ISSUE_ID="$1"
BODY_ARG="$2"
if [[ -f "$BODY_ARG" ]]; then
  BODY="$(cat "$BODY_ARG")"
else
  BODY="$BODY_ARG"
fi

vars=$(jq -cn --arg id "$ISSUE_ID" --arg body "$BODY" '{id: $id, body: $body}')
"$SCRIPT_DIR/api.sh" \
  'mutation($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success } }' \
  "$vars" | jq -e '.data.commentCreate.success' >/dev/null
echo "comment posted on $ISSUE_ID"
