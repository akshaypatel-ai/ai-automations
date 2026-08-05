#!/usr/bin/env bash
# Minimal Sentry REST client (API v0 — hosted and self-hosted).
# Usage: api.sh <METHOD> <path> [json-body]     e.g. api.sh GET /issues/123456/
# Requires: SENTRY_TOKEN in the environment, SENTRY_API_BASE from env.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

METHOD="$1"
API_PATH="$2"
BODY="${3:-}"

[[ -n "${SENTRY_TOKEN:-}" ]] || { echo "error: SENTRY_TOKEN not set" >&2; exit 1; }

args=(-sf -X "$METHOD" -H "Authorization: Bearer $SENTRY_TOKEN" -H "Accept: application/json")
[[ -n "$BODY" ]] && args+=(-H "Content-Type: application/json" --data "$BODY")
curl "${args[@]}" "$SENTRY_API_BASE$API_PATH"
