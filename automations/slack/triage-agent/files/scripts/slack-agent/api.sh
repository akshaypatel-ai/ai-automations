#!/usr/bin/env bash
# Minimal Slack Web API client (form-encoded — works for every method).
# Usage: api.sh <method> [--data-urlencode k=v ...]
#   e.g. api.sh conversations.replies --data-urlencode channel=C123 --data-urlencode ts=1712.001
# Requires: SLACK_BOT_TOKEN in the environment.
set -euo pipefail

METHOD="$1"
shift

[[ -n "${SLACK_BOT_TOKEN:-}" ]] || { echo "error: SLACK_BOT_TOKEN not set" >&2; exit 1; }

resp=$(curl -sf -X POST "https://slack.com/api/$METHOD" \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" "$@")
if ! jq -e '.ok' >/dev/null 2>&1 <<<"$resp"; then
  echo "slack api error ($METHOD): $(jq -r '.error // "unknown"' <<<"$resp")" >&2
  exit 1
fi
printf '%s' "$resp"
