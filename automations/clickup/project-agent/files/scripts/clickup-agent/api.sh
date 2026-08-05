#!/usr/bin/env bash
# Minimal ClickUp REST v2 client.
# Usage: api.sh <METHOD> <path> [json-body]     e.g. api.sh GET /task/abc123
# Requires: CLICKUP_TOKEN in the environment.
set -euo pipefail

METHOD="$1"
API_PATH="$2"
BODY="${3:-}"

[[ -n "${CLICKUP_TOKEN:-}" ]] || { echo "error: CLICKUP_TOKEN not set" >&2; exit 1; }

args=(-sf -X "$METHOD" -H "Authorization: $CLICKUP_TOKEN" -H "Accept: application/json")
[[ -n "$BODY" ]] && args+=(-H "Content-Type: application/json" --data "$BODY")
curl "${args[@]}" "https://api.clickup.com/api/v2$API_PATH"
