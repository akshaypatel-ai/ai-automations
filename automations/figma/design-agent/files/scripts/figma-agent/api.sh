#!/usr/bin/env bash
# Minimal Figma REST client.
# Usage: api.sh <METHOD> <path> [json-body]   e.g. api.sh GET /v1/files/<key>/comments
# Requires: FIGMA_TOKEN in the environment (personal access token,
#           figma.com/settings → Personal access tokens).
set -euo pipefail

METHOD="$1"
API_PATH="$2"
BODY="${3:-}"

[[ -n "${FIGMA_TOKEN:-}" ]] || { echo "error: FIGMA_TOKEN not set" >&2; exit 1; }

args=(-sf -X "$METHOD" -H "X-Figma-Token: $FIGMA_TOKEN" -H "Accept: application/json")
[[ -n "$BODY" ]] && args+=(-H "Content-Type: application/json" --data "$BODY")
curl "${args[@]}" "https://api.figma.com$API_PATH"
