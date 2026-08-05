#!/usr/bin/env bash
# Post ONE comment on a GitHub issue.
# Usage: comment.sh <issue_number> <body-file | body-string>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ISSUE="$1"
BODY_ARG="$2"

if [[ -f "$BODY_ARG" ]]; then
  gh issue comment "$ISSUE" -R "$REPO" --body-file "$BODY_ARG" >/dev/null
else
  gh issue comment "$ISSUE" -R "$REPO" --body "$BODY_ARG" >/dev/null
fi
echo "comment posted on #$ISSUE"
