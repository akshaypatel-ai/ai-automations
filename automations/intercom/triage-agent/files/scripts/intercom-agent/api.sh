#!/usr/bin/env bash
# Minimal Intercom REST client (API version 2.11).
# Usage: api.sh <METHOD> <path> [json-body]     e.g. api.sh GET /conversations/123
# Requires: INTERCOM_TOKEN in the environment.
set -euo pipefail

METHOD="$1"
API_PATH="$2"
BODY="${3:-}"

[[ -n "${INTERCOM_TOKEN:-}" ]] || { echo "error: INTERCOM_TOKEN not set" >&2; exit 1; }

args=(-sf -X "$METHOD" -H "Authorization: Bearer $INTERCOM_TOKEN" \
  -H "Intercom-Version: 2.11" -H "Accept: application/json")
[[ -n "$BODY" ]] && args+=(-H "Content-Type: application/json" --data "$BODY")
curl "${args[@]}" "https://api.intercom.io$API_PATH"
