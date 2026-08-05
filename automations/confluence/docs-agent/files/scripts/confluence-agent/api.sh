#!/usr/bin/env bash
# Minimal Confluence Cloud REST client (paths given under /wiki — v2 and the
# occasional documented v1 endpoint both work).
# Usage: api.sh <METHOD> <path> [json-body]   e.g. api.sh GET /api/v2/pages/123
# Requires: CONFLUENCE_EMAIL + CONFLUENCE_API_TOKEN in the environment,
#           CONFLUENCE_SITE from env.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

METHOD="$1"
API_PATH="$2"
BODY="${3:-}"

[[ -n "${CONFLUENCE_EMAIL:-}" && -n "${CONFLUENCE_API_TOKEN:-}" ]] \
  || { echo "error: CONFLUENCE_EMAIL / CONFLUENCE_API_TOKEN not set" >&2; exit 1; }

args=(-sf -u "$CONFLUENCE_EMAIL:$CONFLUENCE_API_TOKEN" -X "$METHOD" -H "Accept: application/json")
[[ -n "$BODY" ]] && args+=(-H "Content-Type: application/json" --data "$BODY")
curl "${args[@]}" "https://$CONFLUENCE_SITE.atlassian.net/wiki$API_PATH"
