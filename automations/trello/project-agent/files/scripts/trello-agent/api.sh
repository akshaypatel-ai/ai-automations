#!/usr/bin/env bash
# Minimal Trello REST client (auth via key+token query params).
# Usage: api.sh <METHOD> <path> [extra curl args...]
#   e.g. api.sh GET "/1/cards/abc123?attachments=true"
#        api.sh POST "/1/cards/abc123/actions/comments" --data-urlencode "text=hi"
# Requires: TRELLO_KEY, TRELLO_TOKEN in the environment.
set -euo pipefail

METHOD="$1"
API_PATH="$2"
shift 2

for v in TRELLO_KEY TRELLO_TOKEN; do
  [[ -n "${!v:-}" ]] || { echo "error: $v not set" >&2; exit 1; }
done

sep='?'
[[ "$API_PATH" == *\?* ]] && sep='&'
curl -sf -X "$METHOD" -G "https://api.trello.com${API_PATH}${sep}key=${TRELLO_KEY}&token=${TRELLO_TOKEN}" "$@"
