#!/usr/bin/env bash
# Push ONE message to the configured Mattermost incoming webhook.
# Mattermost renders markdown (**bold**, `- ` bullets, links) natively.
# Usage: push.sh <body-file | body-string>
# Requires: MATTERMOST_WEBHOOK_URL in the environment (the URL is the credential).
set -euo pipefail

BODY_ARG="$1"
if [[ -f "$BODY_ARG" ]]; then
  BODY="$(cat "$BODY_ARG")"
else
  BODY="$BODY_ARG"
fi

[[ -n "${MATTERMOST_WEBHOOK_URL:-}" ]] || { echo "error: MATTERMOST_WEBHOOK_URL not set" >&2; exit 1; }

# Mattermost caps posts at ~4000 chars by default (16383 on some servers) —
# truncate conservatively.
BODY="$(printf '%s' "$BODY" | head -c 3800)"

# The username override needs "Enable integrations to override usernames" in
# the System Console — harmless if disabled (the server just ignores the field).
curl -sf -X POST "$MATTERMOST_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  --data "$(jq -cn --arg t "$BODY" --arg u "${AGENT_NAME:-Notify Agent}" \
    '{text: $t, username: $u}')" >/dev/null
echo "pushed to Mattermost"
