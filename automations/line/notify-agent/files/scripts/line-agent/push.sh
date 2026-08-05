#!/usr/bin/env bash
# Push ONE text message to a LINE group/room/user.
# Usage: push.sh <target_id> <body-file | body-string>
# Requires: LINE_CHANNEL_ACCESS_TOKEN in the environment.
set -euo pipefail

TARGET="$1"
BODY_ARG="$2"
if [[ -f "$BODY_ARG" ]]; then
  BODY="$(cat "$BODY_ARG")"
else
  BODY="$BODY_ARG"
fi

[[ -n "${LINE_CHANNEL_ACCESS_TOKEN:-}" ]] || { echo "error: LINE_CHANNEL_ACCESS_TOKEN not set" >&2; exit 1; }

# LINE caps text messages at 5000 chars — truncate defensively.
BODY="$(printf '%s' "$BODY" | head -c 4900)"

curl -sf -X POST https://api.line.me/v2/bot/message/push \
  -H "Authorization: Bearer $LINE_CHANNEL_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  --data "$(jq -cn --arg to "$TARGET" --arg t "$BODY" \
    '{to: $to, messages: [{type: "text", text: $t}]}')" >/dev/null
echo "pushed to $TARGET"
