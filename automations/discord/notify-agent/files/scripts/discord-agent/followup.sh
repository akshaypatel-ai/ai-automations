#!/usr/bin/env bash
# Answer a deferred /ask interaction via its follow-up webhook.
# The interaction token stays valid for 15 minutes — plenty for a CI run.
# Usage: followup.sh <application_id> <interaction_token> <body-file | body-string>
set -euo pipefail

APP_ID="$1"
TOKEN="$2"
BODY_ARG="$3"
if [[ -f "$BODY_ARG" ]]; then
  BODY="$(cat "$BODY_ARG")"
else
  BODY="$BODY_ARG"
fi

# Discord caps message content at 2000 chars — truncate defensively.
BODY="$(printf '%s' "$BODY" | head -c 1900)"

curl -sf -X POST "https://discord.com/api/v10/webhooks/$APP_ID/$TOKEN" \
  -H "Content-Type: application/json" \
  --data "$(jq -cn --arg t "$BODY" '{content: $t, allowed_mentions: {parse: []}}')" >/dev/null
echo "follow-up answer sent"
