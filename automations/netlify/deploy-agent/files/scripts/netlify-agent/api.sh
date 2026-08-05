#!/usr/bin/env bash
# Minimal Netlify REST client (API v1).
# Usage: api.sh <METHOD> <path> [json-body]     e.g. api.sh GET /deploys/abc123
# Requires: NETLIFY_TOKEN in the environment (User settings → Applications →
# Personal access tokens).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

METHOD="$1"
API_PATH="$2"
BODY="${3:-}"

[[ -n "${NETLIFY_TOKEN:-}" ]] || { echo "error: NETLIFY_TOKEN not set" >&2; exit 1; }

args=(-sf -X "$METHOD" -H "Authorization: Bearer $NETLIFY_TOKEN" -H "Accept: application/json")
[[ -n "$BODY" ]] && args+=(-H "Content-Type: application/json" --data "$BODY")
curl "${args[@]}" "https://api.netlify.com/api/v1$API_PATH"
