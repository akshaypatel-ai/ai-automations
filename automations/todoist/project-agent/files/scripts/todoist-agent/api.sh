#!/usr/bin/env bash
# Minimal Todoist REST client (v2 — flat JSON responses, no envelope).
# Usage: api.sh <METHOD> <path> [json-body]     e.g. api.sh GET /tasks/6X7rM8997g3RQmvh
# Requires: TODOIST_TOKEN (Settings → Integrations → Developer → API token).
set -euo pipefail

METHOD="$1"
API_PATH="$2"
BODY="${3:-}"

[[ -n "${TODOIST_TOKEN:-}" ]] || { echo "error: TODOIST_TOKEN not set" >&2; exit 1; }

args=(-sf -X "$METHOD" -H "Authorization: Bearer $TODOIST_TOKEN" -H "Accept: application/json")
[[ -n "$BODY" ]] && args+=(-H "Content-Type: application/json" --data "$BODY")
curl "${args[@]}" "https://api.todoist.com/rest/v2$API_PATH"
