#!/usr/bin/env bash
# Post ONE comment on a Todoist task.
# Usage: comment.sh <task_id> <body-file | body-string>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TASK_ID="$1"
BODY_ARG="$2"
if [[ -f "$BODY_ARG" ]]; then
  BODY="$(cat "$BODY_ARG")"
else
  BODY="$BODY_ARG"
fi

"$SCRIPT_DIR/api.sh" POST "/comments" \
  "$(jq -cn --arg id "$TASK_ID" --arg t "$BODY" '{task_id: $id, content: $t}')" | jq -e '.id' >/dev/null
echo "comment posted on $TASK_ID"
