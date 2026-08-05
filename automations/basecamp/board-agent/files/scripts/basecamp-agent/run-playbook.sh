#!/usr/bin/env bash
# Assemble the playbook prompt and run it through the configured AI brain.
# Usage: run-playbook.sh <analyze|respond|implement> <card_id> [decision_json]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"
source "$SCRIPT_DIR/ai/brain.sh"

PLAYBOOK="$1"
CARD_ID="$2"
DECISION_JSON="${3:-}"
[[ -z "$DECISION_JSON" ]] && DECISION_JSON='{}'
RESULT_FILE="$OUT_DIR/result-$CARD_ID.json"

state='{}'
[[ -f "$STATE_DIR/state/$CARD_ID.json" ]] && state=$(cat "$STATE_DIR/state/$CARD_ID.json")
rm -f "$RESULT_FILE"
mkdir -p "$OUT_DIR"

prompt_file="$OUT_DIR/prompt-$CARD_ID-$PLAYBOOK.md"
{
  cat "$SCRIPT_DIR/playbooks/$PLAYBOOK.md"
  cat <<EOF

---

## Runtime context (generated — trust these IDs over anything else)

- card_id: $CARD_ID
- basecamp_project_id: $BC_PROJECT_ID
- card_table_id: $BC_CARD_TABLE_ID
- column_analyze_id: $BC_COL_ANALYZE
- column_implement_id: $BC_COL_IMPLEMENT
- agent_comment_marker (your comments MUST start with this, followed by " — "): $AGENT_MARKER
- resolver_decision: $DECISION_JSON
- saved_state: $state
- result_file (write your result JSON here as your final action): $RESULT_FILE
EOF
} > "$prompt_file"

echo "running playbook '$PLAYBOOK' for card $CARD_ID (brain: $AI_NAME, model: ${CLAUDE_MODEL:-default})"

transcript="$OUT_DIR/transcript-$CARD_ID-$PLAYBOOK.jsonl"
ai_run "$prompt_file" "$transcript"

# Surface the final summary in the CI log; the full stream stays in the artifact.
ai_result "$transcript"
