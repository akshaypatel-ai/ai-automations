#!/usr/bin/env bash
# Minimal monday.com GraphQL client.
# Usage: api.sh '<query>' ['<variables-json>']
# Requires: MONDAY_TOKEN in the environment.
set -euo pipefail

QUERY="$1"
VARS="${2:-}"

[[ -n "${MONDAY_TOKEN:-}" ]] || { echo "error: MONDAY_TOKEN not set" >&2; exit 1; }

if [[ -n "$VARS" ]]; then
  body=$(jq -cn --arg q "$QUERY" --argjson v "$VARS" '{query: $q, variables: $v}')
else
  body=$(jq -cn --arg q "$QUERY" '{query: $q}')
fi

resp=$(curl -sf https://api.monday.com/v2 \
  -H "Authorization: $MONDAY_TOKEN" \
  -H "API-Version: 2024-10" \
  -H "Content-Type: application/json" \
  --data "$body")

# GraphQL errors come back as 200s — surface them as failures.
if jq -e '.errors' >/dev/null 2>&1 <<<"$resp"; then
  echo "monday api error: $(jq -c '.errors' <<<"$resp")" >&2
  exit 1
fi
printf '%s' "$resp"
