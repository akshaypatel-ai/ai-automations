#!/usr/bin/env bash
# Post ONE reply to a Figma comment thread — the agent's only write surface
# (it never edits designs and never resolves threads). Replies MUST target
# the thread's ROOT comment id: Figma nests exactly one level, so replying
# to a reply is rejected — pass the root id even when answering a reply.
# Usage: reply.sh <file_key> <root_comment_id> <body-file | body-string>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FILE_KEY="$1"
ROOT_ID="$2"
BODY_ARG="$3"
if [[ -f "$BODY_ARG" ]]; then
  BODY="$(cat "$BODY_ARG")"
else
  BODY="$BODY_ARG"
fi

# Figma documents no hard message cap — truncate defensively anyway.
BODY="$(printf '%s' "$BODY" | head -c 3900)"

"$SCRIPT_DIR/api.sh" POST "/v1/files/$FILE_KEY/comments" \
  "$(jq -cn --arg m "$BODY" --arg id "$ROOT_ID" '{message: $m, comment_id: $id}')" \
  | jq -e '.id' >/dev/null
echo "reply posted on thread $ROOT_ID"
