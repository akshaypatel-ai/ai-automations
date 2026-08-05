#!/usr/bin/env bash
# Assemble the playbook prompt and run it through the configured AI brain.
# Usage: run-playbook.sh <analyze|respond|implement> <issue_number> [decision_json]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"
source "$SCRIPT_DIR/ai/brain.sh"

PLAYBOOK="$1"
ITEM_ID="$2"
DECISION_JSON="${3:-}"
[[ -z "$DECISION_JSON" ]] && DECISION_JSON='{}'
RESULT_FILE="$OUT_DIR/result-$ITEM_ID.json"

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

- issue_number: $ITEM_ID
- repo: $REPO
- label_analyze: $LABEL_ANALYZE
- label_implement: $LABEL_IMPLEMENT
- agent_comment_marker (your comments MUST start with this, followed by " — "): $AGENT_MARKER
- api_helper (REST, repo-relative paths): scripts/issues-agent/api.sh <METHOD> <path> [json-body]
- comment_helper (use this to post your ONE comment): scripts/issues-agent/comment.sh <issue_number> <body-file>
- resolver_decision: $DECISION_JSON
- saved_state: $state
- result_file (write your result JSON here as your final action): $RESULT_FILE
EOF
} > "$prompt_file"

echo "running playbook '$PLAYBOOK' for issue #$ITEM_ID (brain: $AI_NAME, model: ${CLAUDE_MODEL:-default})"

transcript="$OUT_DIR/transcript-$ITEM_ID-$PLAYBOOK.jsonl"
ai_run "$prompt_file" "$transcript"

# Surface the final summary in the CI log; the full stream stays in the artifact.
ai_result "$transcript"
