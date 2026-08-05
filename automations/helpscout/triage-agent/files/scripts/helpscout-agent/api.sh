#!/usr/bin/env bash
# Minimal Help Scout REST client (Mailbox API 2.0).
# Usage: api.sh <METHOD> <path> [json-body]     e.g. api.sh GET /v2/conversations/123
# Paths are relative to https://api.helpscout.net — always pass the /v2 prefix.
# Requires: HELPSCOUT_APP_ID + HELPSCOUT_APP_SECRET in the environment
#           (Help Scout → My Apps → Create App). Auth is OAuth2
#           client-credentials, not a static key — this client obtains and
#           caches its own bearer token; callers never see the token dance.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"   # OUT_DIR (token cache lives there)

METHOD="$1"
API_PATH="$2"
BODY="${3:-}"

[[ -n "${HELPSCOUT_APP_ID:-}" && -n "${HELPSCOUT_APP_SECRET:-}" ]] \
  || { echo "error: HELPSCOUT_APP_ID / HELPSCOUT_APP_SECRET not set" >&2; exit 1; }

# Tokens live ~48h; reuse the cached one while the cache file is younger than
# 100 minutes (well inside the token's life, cheap to refresh). `find -mmin`
# is the bash-3.2-safe freshness test — no GNU stat needed.
TOKEN_FILE="$OUT_DIR/.hs-token"
mkdir -p "$OUT_DIR"
TOKEN=""
if [[ -f "$TOKEN_FILE" && -n "$(find "$TOKEN_FILE" -mmin -100 2>/dev/null)" ]]; then
  TOKEN="$(cat "$TOKEN_FILE")"
fi
if [[ -z "$TOKEN" ]]; then
  TOKEN="$(curl -sf -X POST "https://api.helpscout.net/v2/oauth2/token" \
    --data "grant_type=client_credentials&client_id=$HELPSCOUT_APP_ID&client_secret=$HELPSCOUT_APP_SECRET" \
    | jq -r '.access_token // empty')"
  [[ -n "$TOKEN" ]] \
    || { echo "error: could not obtain a Help Scout access token" >&2; exit 1; }
  printf '%s' "$TOKEN" > "$TOKEN_FILE"
fi

args=(-sf -X "$METHOD" -H "Authorization: Bearer $TOKEN" -H "Accept: application/json")
[[ -n "$BODY" ]] && args+=(-H "Content-Type: application/json" --data "$BODY")
curl "${args[@]}" "https://api.helpscout.net$API_PATH"
