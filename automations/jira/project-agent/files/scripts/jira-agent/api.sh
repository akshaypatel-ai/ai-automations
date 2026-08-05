#!/usr/bin/env bash
# Minimal Jira Cloud REST client.
# Usage: api.sh <METHOD> <path> [json-body]     e.g. api.sh GET /rest/api/2/issue/NOVA-1
# Requires: JIRA_SITE, JIRA_EMAIL, JIRA_API_TOKEN in the environment.
set -euo pipefail

METHOD="$1"
API_PATH="$2"
BODY="${3:-}"

for v in JIRA_SITE JIRA_EMAIL JIRA_API_TOKEN; do
  [[ -n "${!v:-}" ]] || { echo "error: $v not set" >&2; exit 1; }
done

args=(-sf -X "$METHOD" -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H "Accept: application/json")
[[ -n "$BODY" ]] && args+=(-H "Content-Type: application/json" --data "$BODY")
curl "${args[@]}" "${JIRA_SITE%/}$API_PATH"
