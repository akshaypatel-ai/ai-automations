#!/usr/bin/env bash
# Post ONE comment on a Shortcut story.
# Usage: comment.sh <story_id> <body-file | body-string>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STORY_ID="$1"
BODY_ARG="$2"
if [[ -f "$BODY_ARG" ]]; then
  BODY="$(cat "$BODY_ARG")"
else
  BODY="$BODY_ARG"
fi

"$SCRIPT_DIR/api.sh" POST "/stories/$STORY_ID/comments" \
  "$(jq -cn --arg t "$BODY" '{text: $t}')" | jq -e '.id' >/dev/null
echo "comment posted on story $STORY_ID"
