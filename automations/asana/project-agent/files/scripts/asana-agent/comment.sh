#!/usr/bin/env bash
# Post ONE comment (story) on an Asana task.
# Usage: comment.sh <task_gid> <body-file | body-string>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TASK_GID="$1"
BODY_ARG="$2"
if [[ -f "$BODY_ARG" ]]; then
  BODY="$(cat "$BODY_ARG")"
else
  BODY="$BODY_ARG"
fi

"$SCRIPT_DIR/api.sh" POST "/tasks/$TASK_GID/stories" \
  "$(jq -cn --arg t "$BODY" '{data: {text: $t}}')" | jq -e '.data.gid' >/dev/null
echo "comment posted on $TASK_GID"
