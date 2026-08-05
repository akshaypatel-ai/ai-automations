#!/usr/bin/env bash
# Minimal Linear GraphQL client.
# Usage: api.sh '<query>' ['<variables-json>']
# Requires: LINEAR_API_KEY in the environment.
set -euo pipefail

QUERY="$1"
VARS="${2:-}"

[[ -n "${LINEAR_API_KEY:-}" ]] || { echo "error: LINEAR_API_KEY not set" >&2; exit 1; }

if [[ -n "$VARS" ]]; then
  body=$(jq -cn --arg q "$QUERY" --argjson v "$VARS" '{query: $q, variables: $v}')
else
  body=$(jq -cn --arg q "$QUERY" '{query: $q}')
fi

resp=$(curl -sf https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  --data "$body")

# GraphQL errors come back as 200s — surface them as failures.
if jq -e '.errors' >/dev/null 2>&1 <<<"$resp"; then
  echo "linear api error: $(jq -c '.errors' <<<"$resp")" >&2
  exit 1
fi
printf '%s' "$resp"
