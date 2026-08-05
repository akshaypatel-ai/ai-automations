#!/usr/bin/env bash
# Minimal Vercel REST client.
# Usage: api.sh <METHOD> <path> [json-body]     e.g. api.sh GET /v13/deployments/dpl_abc
# Requires: VERCEL_TOKEN in the environment, VERCEL_TEAM_ID (optional) from env.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

METHOD="$1"
API_PATH="$2"
BODY="${3:-}"

[[ -n "${VERCEL_TOKEN:-}" ]] || { echo "error: VERCEL_TOKEN not set" >&2; exit 1; }

# Team-scoped tokens need teamId on every call — append with the right separator.
if [[ -n "${VERCEL_TEAM_ID:-}" ]]; then
  case "$API_PATH" in
    *\?*) sep='&' ;;
    *)    sep='?' ;;
  esac
  API_PATH="${API_PATH}${sep}teamId=${VERCEL_TEAM_ID}"
fi

args=(-sf -X "$METHOD" -H "Authorization: Bearer $VERCEL_TOKEN" -H "Accept: application/json")
[[ -n "$BODY" ]] && args+=(-H "Content-Type: application/json" --data "$BODY")
curl "${args[@]}" "https://api.vercel.com$API_PATH"
