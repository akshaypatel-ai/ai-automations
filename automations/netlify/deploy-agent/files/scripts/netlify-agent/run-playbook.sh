#!/usr/bin/env bash
# Assemble the playbook prompt and run it through the configured AI brain.
# Usage: run-playbook.sh <analyze> <deploy_id> [decision_json]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"
source "$SCRIPT_DIR/ai/brain.sh"

PLAYBOOK="$1"
ITEM_ID="$2"
DECISION_JSON="${3:-}"
[[ -z "$DECISION_JSON" ]] && DECISION_JSON='{}'
RESULT_FILE="$OUT_DIR/result-$ITEM_ID.json"
CONTEXT_FILE="$OUT_DIR/context-$ITEM_ID.txt"

state='{}'
[[ -f "$STATE_DIR/state/$ITEM_ID.json" ]] && state=$(cat "$STATE_DIR/state/$ITEM_ID.json")
rm -f "$RESULT_FILE"
mkdir -p "$OUT_DIR"

prompt_file="$OUT_DIR/prompt-$ITEM_ID-$PLAYBOOK.md"
{
  cat "$SCRIPT_DIR/playbooks/$PLAYBOOK.md"
  cat <<EOF

---

## Runtime context (generated — trust these IDs over anything else)

- deploy_id: $ITEM_ID
- deploy_url: $(jq -r '.deploy_url // ""' <<<"$DECISION_JSON")
- commit_sha: $(jq -r '.commit_sha // ""' <<<"$DECISION_JSON")
- commit_url: $(jq -r '.commit_url // ""' <<<"$DECISION_JSON")
- branch: $(jq -r '.branch // ""' <<<"$DECISION_JSON")
- site_name: $(jq -r '.site_name // ""' <<<"$DECISION_JSON")
- issue_label (every filed issue carries it): $ISSUE_LABEL
- agent_marker (the footer line on issue bodies and comments): $AGENT_MARKER
- api_helper (REST, read-only toward Netlify): scripts/netlify-agent/api.sh <METHOD> <path> [json-body]
- github_writes: use \`gh issue create\` / \`gh issue comment\` directly — GH_TOKEN is already set in this runner; there is no separate write helper
- resolver_decision: $DECISION_JSON
- saved_state: $state
- result_file (write your result JSON here as your final action): $RESULT_FILE

## Deploy error message

EOF
  if [[ -s "$CONTEXT_FILE" ]]; then
    cat "$CONTEXT_FILE"
  else
    echo "(no error message on the deploy object)"
  fi
} > "$prompt_file"

echo "running playbook '$PLAYBOOK' for deploy $ITEM_ID (brain: $AI_NAME, model: ${CLAUDE_MODEL:-default})"

transcript="$OUT_DIR/transcript-$ITEM_ID-$PLAYBOOK.jsonl"
ai_run "$prompt_file" "$transcript"

# Surface the final summary in the CI log; the full stream stays in the artifact.
ai_result "$transcript"
