#!/usr/bin/env bash
# Minimal Front REST client (Core API).
# Usage: api.sh <METHOD> <path> [json-body]     e.g. api.sh GET /conversations/cnv_123
# Requires: FRONT_TOKEN in the environment
#           (Front → Settings → Developers → API tokens).
set -euo pipefail

METHOD="$1"
API_PATH="$2"
BODY="${3:-}"

[[ -n "${FRONT_TOKEN:-}" ]] || { echo "error: FRONT_TOKEN not set" >&2; exit 1; }

args=(-sf -X "$METHOD" -H "Authorization: Bearer $FRONT_TOKEN" \
  -H "Accept: application/json")
[[ -n "$BODY" ]] && args+=(-H "Content-Type: application/json" --data "$BODY")
curl "${args[@]}" "https://api2.frontapp.com$API_PATH"
