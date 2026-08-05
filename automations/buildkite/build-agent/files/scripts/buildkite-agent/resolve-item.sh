#!/usr/bin/env bash
# Decide which playbook (if any) applies to a Buildkite build by checking the
# API against saved state. Fully implemented: builds.
# Usage: resolve-item.sh <build_number> [item_type]   → prints a one-line decision JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ITEM_ID="$1"
TYPE_HINT="${2:-Build}"
STATE_FILE="$STATE_DIR/state/$ITEM_ID.json"

skip() { # skip <reason>
  jq -cn --arg id "$ITEM_ID" --arg t "$TYPE_HINT" --arg r "$1" \
    '{item_id: $id, item_type: $t, decision: "skip", reason: $r}'
  exit 0
}

[[ "$TYPE_HINT" == "Build" ]] || skip "handler not implemented yet"
[[ ",$ENABLED_HANDLERS," == *",builds,"* ]] || skip "handler 'builds' disabled"

state='{}'
[[ -f "$STATE_FILE" ]] && state=$(cat "$STATE_FILE")
phase=$(jq -r '.phase // "new"' <<<"$state")

build_json=$("$SCRIPT_DIR/api.sh" GET "/organizations/$BUILDKITE_ORG/pipelines/$BUILDKITE_PIPELINE/builds/$ITEM_ID" 2>/dev/null) || skip "build not fetchable"

# Only failed builds are triage material — passed/running/canceled are not our business.
build_state=$(jq -r '.state // ""' <<<"$build_json")
[[ "$build_state" == "failed" ]] || skip "build not in failed state"

# A tracked, filed build means a retrigger or a duplicate delivery — the
# sha-search dedupe already ran when it was filed.
[[ -f "$STATE_FILE" && "$phase" == "filed" ]] && skip "already processed"

web_url=$(jq -r '.web_url // ""' <<<"$build_json")
branch=$(jq -r '.branch // ""' <<<"$build_json")
commit_sha=$(jq -r '.commit // ""' <<<"$build_json")
# The build message is the commit subject — enough for the decision log; the
# failing job's actual log goes into the prompt via the context file.
build_message=$(jq -r '(.message // "")[:200]' <<<"$build_json")

jq -cn \
  --arg item_id "$ITEM_ID" \
  --arg decision "analyze" \
  --arg reason "failed build" \
  --arg web_url "$web_url" \
  --arg branch "$branch" \
  --arg commit_sha "$commit_sha" \
  --arg build_message "$build_message" \
  --arg prev_phase "$phase" \
  '{item_id: $item_id, item_type: "Build", decision: $decision, reason: $reason,
    web_url: $web_url, branch: $branch, commit_sha: $commit_sha,
    build_message: $build_message, prev_phase: $prev_phase}'
