#!/usr/bin/env bash
# Minimal Miro REST client.
# Usage: api.sh <METHOD> <path> [json-body]   e.g. api.sh GET /v2/boards/<board>/items/<id>
# Requires: MIRO_TOKEN in the environment (app access token: Miro → Settings →
#           Your apps → create an app → install it to the board's team → token
#           with boards:read + boards:write).
# Board ids are opaque URL-safe base64, usually with a trailing '=' — '=' is
# valid inside a URL path segment, so pass the id as-is; no encoding needed.
set -euo pipefail

METHOD="$1"
API_PATH="$2"
BODY="${3:-}"

[[ -n "${MIRO_TOKEN:-}" ]] || { echo "error: MIRO_TOKEN not set" >&2; exit 1; }

args=(-sf -X "$METHOD" -H "Authorization: Bearer $MIRO_TOKEN" -H "Accept: application/json")
[[ -n "$BODY" ]] && args+=(-H "Content-Type: application/json" --data "$BODY")
curl "${args[@]}" "https://api.miro.com$API_PATH"
