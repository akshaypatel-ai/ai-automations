#!/usr/bin/env bash
# Push ONE message to the configured Google Chat space webhook.
# Usage: push.sh <body-file | body-string>
# Requires: GCHAT_WEBHOOK_URL in the environment — the space webhook URL
# embeds its own key+token, so the URL itself is the credential.
set -euo pipefail

BODY_ARG="$1"
if [[ -f "$BODY_ARG" ]]; then
  BODY="$(cat "$BODY_ARG")"
else
  BODY="$BODY_ARG"
fi

[[ -n "${GCHAT_WEBHOOK_URL:-}" ]] || { echo "error: GCHAT_WEBHOOK_URL not set" >&2; exit 1; }

# Google Chat caps messages around 4096 chars — truncate defensively.
BODY="$(printf '%s' "$BODY" | head -c 3900)"

# Plain {text} payload — Google Chat renders *bold* and simple markup, but
# arbitrary AI output can break markup, so the playbooks stay plain text.
curl -sf -X POST "$GCHAT_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  --data "$(jq -cn --arg t "$BODY" '{text: $t}')" >/dev/null
echo "pushed to Google Chat"
