#!/usr/bin/env bash
# Minimal Airtable Web API client.
# Usage: api.sh <METHOD> <path> [json-body]   e.g. api.sh GET /appXXX/tblXXX/recXXX
# Paths are absolute under /v0 (record paths carry the base id themselves —
# nothing is baked in here). Requires: AIRTABLE_TOKEN in the environment.
set -euo pipefail

METHOD="$1"
API_PATH="$2"
BODY="${3:-}"

[[ -n "${AIRTABLE_TOKEN:-}" ]] || { echo "error: AIRTABLE_TOKEN not set" >&2; exit 1; }

args=(-sf -X "$METHOD" -H "Authorization: Bearer $AIRTABLE_TOKEN" -H "Accept: application/json")
[[ -n "$BODY" ]] && args+=(-H "Content-Type: application/json" --data "$BODY")
curl "${args[@]}" "https://api.airtable.com/v0$API_PATH"
