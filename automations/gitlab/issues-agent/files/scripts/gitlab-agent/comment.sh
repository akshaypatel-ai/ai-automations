#!/usr/bin/env bash
# Post ONE comment (note) on a GitLab issue.
# Usage: comment.sh <issue_iid> <body-file | body-string>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ISSUE_IID="$1"
BODY_ARG="$2"
if [[ -f "$BODY_ARG" ]]; then
  BODY="$(cat "$BODY_ARG")"
else
  BODY="$BODY_ARG"
fi

"$SCRIPT_DIR/api.sh" POST "/projects/$GITLAB_PROJECT_ID/issues/$ISSUE_IID/notes" \
  "$(jq -cn --arg body "$BODY" '{body: $body}')" | jq -e '.id' >/dev/null
echo "comment posted on #$ISSUE_IID"
