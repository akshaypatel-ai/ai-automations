#!/usr/bin/env bash
# Push ONE message to the configured Rocket.Chat incoming webhook.
# Rocket.Chat renders markdown (**bold**, `- ` bullets, links) natively.
# Usage: push.sh <body-file | body-string>
# Requires: ROCKETCHAT_WEBHOOK_URL in the environment (the URL embeds the
# integration id AND token — the URL is the credential).
set -euo pipefail

BODY_ARG="$1"
if [[ -f "$BODY_ARG" ]]; then
  BODY="$(cat "$BODY_ARG")"
else
  BODY="$BODY_ARG"
fi

[[ -n "${ROCKETCHAT_WEBHOOK_URL:-}" ]] || { echo "error: ROCKETCHAT_WEBHOOK_URL not set" >&2; exit 1; }

# Rocket.Chat caps message length (5000 chars by default, admin-tunable) —
# truncate conservatively.
BODY="$(printf '%s' "$BODY" | head -c 3800)"

# Rocket.Chat's display-name override field is "alias" (Mattermost calls it
# "username") — harmless if the server restricts overriding (field ignored).
curl -sf -X POST "$ROCKETCHAT_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  --data "$(jq -cn --arg t "$BODY" --arg a "${AGENT_NAME:-Notify Agent}" \
    '{text: $t, alias: $a}')" >/dev/null
echo "pushed to Rocket.Chat"
