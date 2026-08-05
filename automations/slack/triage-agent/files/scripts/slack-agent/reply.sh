#!/usr/bin/env bash
# Post ONE threaded reply in Slack.
# Usage: reply.sh <channel> <thread_ts> <body-file | body-string>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CHANNEL="$1"
THREAD_TS="$2"
BODY_ARG="$3"
if [[ -f "$BODY_ARG" ]]; then
  BODY="$(cat "$BODY_ARG")"
else
  BODY="$BODY_ARG"
fi

"$SCRIPT_DIR/api.sh" chat.postMessage \
  --data-urlencode "channel=$CHANNEL" \
  --data-urlencode "thread_ts=$THREAD_TS" \
  --data-urlencode "text=$BODY" >/dev/null
echo "reply posted in $CHANNEL (thread $THREAD_TS)"
