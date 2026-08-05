#!/usr/bin/env bash
# Minimal Shortcut REST v3 client.
# Usage: api.sh <METHOD> <path> [json-body]     e.g. api.sh GET /stories/123
# Requires: SHORTCUT_TOKEN in the environment.
set -euo pipefail

METHOD="$1"
API_PATH="$2"
BODY="${3:-}"

[[ -n "${SHORTCUT_TOKEN:-}" ]] || { echo "error: SHORTCUT_TOKEN not set" >&2; exit 1; }

args=(-sf -X "$METHOD" -H "Shortcut-Token: $SHORTCUT_TOKEN" -H "Accept: application/json")
[[ -n "$BODY" ]] && args+=(-H "Content-Type: application/json" --data "$BODY")
curl "${args[@]}" "https://api.app.shortcut.com/api/v3$API_PATH"
