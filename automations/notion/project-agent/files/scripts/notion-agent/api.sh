#!/usr/bin/env bash
# Minimal Notion REST client.
# Usage: api.sh <METHOD> <path> [json-body]     e.g. api.sh GET /pages/<page_id>
# Requires: NOTION_TOKEN (internal integration secret) in the environment.
set -euo pipefail

METHOD="$1"
API_PATH="$2"
BODY="${3:-}"

[[ -n "${NOTION_TOKEN:-}" ]] || { echo "error: NOTION_TOKEN not set" >&2; exit 1; }

args=(-sf -X "$METHOD" \
  -H "Authorization: Bearer $NOTION_TOKEN" \
  -H "Notion-Version: 2022-06-28" \
  -H "Accept: application/json")
[[ -n "$BODY" ]] && args+=(-H "Content-Type: application/json" --data "$BODY")
curl "${args[@]}" "https://api.notion.com/v1$API_PATH"
