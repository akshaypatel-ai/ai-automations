#!/usr/bin/env bash
# Push ONE message (as an Adaptive Card) to the configured Teams channel webhook.
# Works with the modern Workflows webhook ("when a webhook request is received")
# and the classic Incoming Webhook connector.
# Usage: push.sh <body-file | body-string>
# Requires: TEAMS_WEBHOOK_URL in the environment.
set -euo pipefail

BODY_ARG="$1"
if [[ -f "$BODY_ARG" ]]; then
  BODY="$(cat "$BODY_ARG")"
else
  BODY="$BODY_ARG"
fi

[[ -n "${TEAMS_WEBHOOK_URL:-}" ]] || { echo "error: TEAMS_WEBHOOK_URL not set" >&2; exit 1; }

# Stay well under Teams' message size cap.
BODY="$(printf '%s' "$BODY" | head -c 3800)"

curl -sf -X POST "$TEAMS_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  --data "$(jq -cn --arg t "$BODY" \
    '{type: "message", attachments: [{
        contentType: "application/vnd.microsoft.card.adaptive",
        content: {
          "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
          type: "AdaptiveCard", version: "1.4",
          body: [{type: "TextBlock", text: $t, wrap: true}]
        }
      }]}')" >/dev/null
echo "pushed to Teams"
