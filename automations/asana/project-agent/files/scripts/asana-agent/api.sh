#!/usr/bin/env bash
# Minimal Asana REST client (API 1.0 — responses wrap payloads in {"data": ...}).
# Usage: api.sh <METHOD> <path> [json-body]     e.g. api.sh GET /tasks/1234567890
# Requires: ASANA_TOKEN (personal access token) in the environment.
set -euo pipefail

METHOD="$1"
API_PATH="$2"
BODY="${3:-}"

[[ -n "${ASANA_TOKEN:-}" ]] || { echo "error: ASANA_TOKEN not set" >&2; exit 1; }

args=(-sf -X "$METHOD" -H "Authorization: Bearer $ASANA_TOKEN" -H "Accept: application/json")
[[ -n "$BODY" ]] && args+=(-H "Content-Type: application/json" --data "$BODY")
curl "${args[@]}" "https://app.asana.com/api/1.0$API_PATH"
