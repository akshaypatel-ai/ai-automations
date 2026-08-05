#!/usr/bin/env bash
# Assemble the playbook prompt and run it through the configured AI brain.
# Usage: run-playbook.sh <triage|respond> <ticket_id> [decision_json]
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

- ticket_id: $ITEM_ID
- freshdesk_domain: $FRESHDESK_DOMAIN
- escalation_label (for GitHub issues): $ESCALATION_LABEL
- agent_note_marker (your notes MUST start with this, followed by " — "): $AGENT_MARKER
- api_helper (REST): scripts/freshdesk-agent/api.sh <METHOD> <path> [json-body]
- note_helper (use this to post your ONE private note — write PLAIN TEXT, it converts to HTML and is structurally private): scripts/freshdesk-agent/note.sh <ticket_id> <body-file>
- resolver_decision: $DECISION_JSON
- saved_state: $state
- result_file (write your result JSON here as your final action): $RESULT_FILE
EOF
} > "$prompt_file"

echo "running playbook '$PLAYBOOK' for ticket $ITEM_ID (brain: $AI_NAME, model: ${CLAUDE_MODEL:-default})"

transcript="$OUT_DIR/transcript-$ITEM_ID-$PLAYBOOK.jsonl"
ai_run "$prompt_file" "$transcript"

# Surface the final summary in the CI log; the full stream stays in the artifact.
ai_result "$transcript"
