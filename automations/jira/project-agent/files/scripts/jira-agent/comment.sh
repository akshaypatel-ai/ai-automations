#!/usr/bin/env bash
# Post ONE comment on a Jira issue (v2 endpoint: plain-text / wiki-markup body).
# Usage: comment.sh <issue_key> <body-file | body-string>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ISSUE_KEY="$1"
BODY_ARG="$2"
if [[ -f "$BODY_ARG" ]]; then
  BODY="$(cat "$BODY_ARG")"
else
  BODY="$BODY_ARG"
fi

"$SCRIPT_DIR/api.sh" POST "/rest/api/2/issue/$ISSUE_KEY/comment" \
  "$(jq -cn --arg body "$BODY" '{body: $body}')" | jq -e '.id' >/dev/null
echo "comment posted on $ISSUE_KEY"
