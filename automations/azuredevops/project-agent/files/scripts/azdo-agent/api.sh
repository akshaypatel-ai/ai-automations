#!/usr/bin/env bash
# Minimal Azure DevOps REST client (PAT basic auth with an empty username).
# Usage: api.sh <METHOD> <path> [json-body]
#   e.g. api.sh GET "/wit/workitems/42"            → project-scoped /_apis
#        api.sh GET "//projects/MyProject"         → org-scoped /_apis ("//" escape)
# Every call needs an api-version — appends api-version=7.1 unless the caller
# pins one in the path (the comments endpoints need 7.1-preview.4 explicitly).
# Requires: AZDO_PAT in the environment; org/project come from env.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

METHOD="$1"
API_PATH="$2"
BODY="${3:-}"

[[ -n "${AZDO_PAT:-}" ]] || { echo "error: AZDO_PAT not set" >&2; exit 1; }
for v in AZDO_ORG AZDO_PROJECT; do
  [[ -n "${!v:-}" ]] || { echo "error: $v not set" >&2; exit 1; }
done

# Project names may contain spaces — URL-encode the path segment.
PROJECT_ENC=$(jq -rn --arg p "$AZDO_PROJECT" '$p|@uri')

# "//" prefix = org-level API (e.g. //projects/<name>); default is project-level.
if [[ "$API_PATH" == //* ]]; then
  BASE="https://dev.azure.com/$AZDO_ORG/_apis"
  API_PATH="${API_PATH#/}"
else
  BASE="https://dev.azure.com/$AZDO_ORG/$PROJECT_ENC/_apis"
fi

if [[ "$API_PATH" != *"api-version="* ]]; then
  sep='?'
  [[ "$API_PATH" == *\?* ]] && sep='&'
  API_PATH="${API_PATH}${sep}api-version=7.1"
fi

args=(-sf -X "$METHOD" -u ":$AZDO_PAT" -H "Accept: application/json")
[[ -n "$BODY" ]] && args+=(-H "Content-Type: application/json" --data "$BODY")
curl "${args[@]}" "${BASE}${API_PATH}"
