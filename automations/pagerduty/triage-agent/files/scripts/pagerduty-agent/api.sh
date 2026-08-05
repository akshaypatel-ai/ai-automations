#!/usr/bin/env bash
# Minimal PagerDuty REST client (api.pagerduty.com).
# Usage: api.sh <METHOD> <path> [json-body] [extra-header]...
#        e.g. api.sh GET "/incidents/PT4KHLK"
# Requires: PAGERDUTY_TOKEN in the environment. Any extra args become
# additional headers (note.sh passes the "From: <email>" attribution header).
set -euo pipefail

METHOD="$1"
API_PATH="$2"
BODY="${3:-}"

[[ -n "${PAGERDUTY_TOKEN:-}" ]] || { echo "error: PAGERDUTY_TOKEN not set" >&2; exit 1; }

args=(-sf -X "$METHOD" -H "Authorization: Token token=$PAGERDUTY_TOKEN" -H "Accept: application/json")
[[ -n "$BODY" ]] && args+=(-H "Content-Type: application/json" --data "$BODY")
for h in "${@:4}"; do args+=(-H "$h"); done
curl "${args[@]}" "https://api.pagerduty.com$API_PATH"
