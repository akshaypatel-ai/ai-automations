#!/usr/bin/env bash
# Minimal GitLab REST client (API v4 — gitlab.com or self-hosted).
# Usage: api.sh <METHOD> <path> [json-body]     e.g. api.sh GET /projects/123/issues/42
# Requires: GITLAB_TOKEN in the environment (PAT with 'api' scope),
#           GITLAB_API_BASE from env.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

METHOD="$1"
API_PATH="$2"
BODY="${3:-}"

[[ -n "${GITLAB_TOKEN:-}" ]] \
  || { echo "error: GITLAB_TOKEN not set (PAT with 'api' scope)" >&2; exit 1; }

args=(-sf -X "$METHOD" -H "PRIVATE-TOKEN: $GITLAB_TOKEN" -H "Accept: application/json")
[[ -n "$BODY" ]] && args+=(-H "Content-Type: application/json" --data "$BODY")
curl "${args[@]}" "${GITLAB_API_BASE%/}/api/v4$API_PATH"
