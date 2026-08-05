#!/usr/bin/env bash
# Minimal GitHub REST client via the gh CLI (auth: GH_TOKEN from CI).
# Paths are relative to the watched repo: /issues/42 → repos/<owner>/<repo>/issues/42
# Usage: api.sh <METHOD> <path> [json-body]     e.g. api.sh GET /issues/42
set -euo pipefail

METHOD="$1"
API_PATH="$2"
BODY="${3:-}"

[[ -n "${REPO:-}" ]] || { echo "error: REPO not set (source env.sh)" >&2; exit 1; }

if [[ -n "$BODY" ]]; then
  printf '%s' "$BODY" | gh api -X "$METHOD" "repos/$REPO$API_PATH" --input -
else
  gh api -X "$METHOD" "repos/$REPO$API_PATH"
fi
