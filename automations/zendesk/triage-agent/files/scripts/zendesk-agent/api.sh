#!/usr/bin/env bash
# Minimal Zendesk REST client (API v2).
# Usage: api.sh <METHOD> <path> [json-body]     e.g. api.sh GET /tickets/123.json
# Requires: ZENDESK_EMAIL + ZENDESK_API_TOKEN in the environment,
#           ZENDESK_SUBDOMAIN from env.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

METHOD="$1"
API_PATH="$2"
BODY="${3:-}"

[[ -n "${ZENDESK_EMAIL:-}" && -n "${ZENDESK_API_TOKEN:-}" ]] \
  || { echo "error: ZENDESK_EMAIL / ZENDESK_API_TOKEN not set" >&2; exit 1; }

args=(-sf -u "$ZENDESK_EMAIL/token:$ZENDESK_API_TOKEN" -X "$METHOD" -H "Accept: application/json")
[[ -n "$BODY" ]] && args+=(-H "Content-Type: application/json" --data "$BODY")
curl "${args[@]}" "https://$ZENDESK_SUBDOMAIN.zendesk.com/api/v2$API_PATH"
