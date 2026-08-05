#!/usr/bin/env bash
# Push ONE message to the configured Discord channel webhook.
# Usage: push.sh <body-file | body-string>
# Requires: DISCORD_WEBHOOK_URL in the environment (the channel webhook URL).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

BODY_ARG="$1"
if [[ -f "$BODY_ARG" ]]; then
  BODY="$(cat "$BODY_ARG")"
else
  BODY="$BODY_ARG"
fi

[[ -n "${DISCORD_WEBHOOK_URL:-}" ]] || { echo "error: DISCORD_WEBHOOK_URL not set" >&2; exit 1; }

# Discord caps message content at 2000 chars — truncate defensively.
BODY="$(printf '%s' "$BODY" | head -c 1900)"

# allowed_mentions: [] — the agent can never ping @everyone/@here/roles.
curl -sf -X POST "$DISCORD_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  --data "$(jq -cn --arg t "$BODY" --arg u "$AGENT_NAME" \
    '{content: $t, username: $u, allowed_mentions: {parse: []}}')" >/dev/null
echo "pushed to Discord"
