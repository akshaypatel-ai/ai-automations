#!/usr/bin/env bash
# Minimal Buildkite REST client.
# Usage: api.sh <METHOD> <path> [json-body]     e.g. api.sh GET /organizations/acme/pipelines/web/builds/42
# Requires: BUILDKITE_TOKEN in the environment (buildkite.com/user/api-access-tokens,
# scopes read_builds + read_build_logs).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

METHOD="$1"
API_PATH="$2"
BODY="${3:-}"

[[ -n "${BUILDKITE_TOKEN:-}" ]] || { echo "error: BUILDKITE_TOKEN not set" >&2; exit 1; }

args=(-sf -X "$METHOD" -H "Authorization: Bearer $BUILDKITE_TOKEN" -H "Accept: application/json")
[[ -n "$BODY" ]] && args+=(-H "Content-Type: application/json" --data "$BODY")
curl "${args[@]}" "https://api.buildkite.com/v2$API_PATH"
