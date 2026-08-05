#!/usr/bin/env bash
# Push ONE text message to a Telegram chat.
# Usage: push.sh <chat_id> <body-file | body-string>
# Requires: TELEGRAM_BOT_TOKEN in the environment (from @BotFather).
set -euo pipefail

CHAT_ID="$1"
BODY_ARG="$2"
if [[ -f "$BODY_ARG" ]]; then
  BODY="$(cat "$BODY_ARG")"
else
  BODY="$BODY_ARG"
fi

[[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] || { echo "error: TELEGRAM_BOT_TOKEN not set" >&2; exit 1; }

# Telegram caps text messages at 4096 chars — truncate defensively.
BODY="$(printf '%s' "$BODY" | head -c 3900)"

# parse_mode deliberately omitted: plain text can never fail Telegram's
# Markdown parser on arbitrary AI output (a stray * or _ would 400).
curl -sf -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
  -H "Content-Type: application/json" \
  --data "$(jq -cn --arg chat "$CHAT_ID" --arg t "$BODY" \
    '{chat_id: $chat, text: $t, disable_web_page_preview: true}')" \
  | jq -e '.ok == true' >/dev/null
echo "pushed to $CHAT_ID"
