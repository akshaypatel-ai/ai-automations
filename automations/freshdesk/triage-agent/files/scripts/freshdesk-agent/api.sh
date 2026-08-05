#!/usr/bin/env bash
# Minimal Freshdesk REST client (API v2).
# Usage: api.sh <METHOD> <path> [json-body]     e.g. api.sh GET /tickets/123
# Requires: FRESHDESK_API_KEY in the environment,
#           FRESHDESK_DOMAIN from env.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

METHOD="$1"
API_PATH="$2"
BODY="${3:-}"

[[ -n "${FRESHDESK_API_KEY:-}" ]] \
  || { echo "error: FRESHDESK_API_KEY not set" >&2; exit 1; }

# Freshdesk basic auth: the API key is the username, the password is ignored.
args=(-sf -u "$FRESHDESK_API_KEY:X" -X "$METHOD" -H "Accept: application/json")
[[ -n "$BODY" ]] && args+=(-H "Content-Type: application/json" --data "$BODY")
curl "${args[@]}" "https://$FRESHDESK_DOMAIN.freshdesk.com/api/v2$API_PATH"
