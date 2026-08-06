#!/usr/bin/env bash
# Assemble the playbook prompt and run it through the configured AI brain.
# Usage: run-playbook.sh <triage|respond> <conversation_id> [decision_json]
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

# Text-only mode support: the brain can't fetch anything itself, so the
# driver inlines the source material into the prompt (best effort, capped).
fetch_capped() {
  local out
  if out="$("$SCRIPT_DIR/api.sh" GET "$1" 2>/dev/null)"; then
    head -c 10000 <<<"$out"
    echo
  else
    echo "(fetch failed)"
  fi
}

prompt_file="$OUT_DIR/prompt-$ITEM_ID-$PLAYBOOK.md"
{
  cat "$SCRIPT_DIR/playbooks/$PLAYBOOK.md"
  if [[ "${CAN_RUN_TOOLS:-1}" == "0" ]]; then
    echo
    echo "## Item data (fetched for text-only mode)"
    echo
    echo "### Conversation"
    fetch_capped "/conversations/$ITEM_ID"
    cat <<'EOF'

## TEXT-ONLY MODE (overrides delivery instructions above)

You cannot run commands, fetch anything, or escalate to GitHub in this
mode. Using ONLY the information already present in this prompt, reply
with ONLY the internal note body (start it with the agent marker). The
system posts it for you.
EOF
  fi
  cat <<EOF

---

## Runtime context (generated — trust these IDs over anything else)

- conversation_id: $ITEM_ID
- escalation_label (for GitHub issues): $ESCALATION_LABEL
- agent_note_marker (your notes MUST start with this, followed by " — "): $AGENT_MARKER
- api_helper (REST): scripts/intercom-agent/api.sh <METHOD> <path> [json-body]
- note_helper (use this to post your ONE internal note — write PLAIN TEXT, it converts to the HTML Intercom expects, and it is structurally private): scripts/intercom-agent/note.sh <conversation_id> <body-file>
- resolver_decision: $DECISION_JSON
- saved_state: $state
- result_file (write your result JSON here as your final action): $RESULT_FILE
EOF
} > "$prompt_file"

echo "running playbook '$PLAYBOOK' for conversation $ITEM_ID (brain: $AI_NAME, model: ${AI_MODEL:-default})"

transcript="$OUT_DIR/transcript-$ITEM_ID-$PLAYBOOK.jsonl"
ai_run "$prompt_file" "$transcript"

# Surface the final summary in the CI log; the full stream stays in the artifact.
ai_result "$transcript"

# Driver-mediated write-back: a text-only brain can't run the note helper —
# its reply IS the note, and this driver posts it. GitHub escalation is
# unavailable in this mode (documented capability trade-off).
if [[ "${CAN_RUN_TOOLS:-1}" == "0" ]]; then
  body="$(ai_result "$transcript")"
  if [[ -z "$body" ]]; then
    echo "error: text-only brain returned an empty note body — nothing posted" >&2
    exit 1
  fi
  body_file="$OUT_DIR/body-$ITEM_ID-$PLAYBOOK.txt"
  printf '%s\n' "$body" > "$body_file"
  "$SCRIPT_DIR/note.sh" "$ITEM_ID" "$body_file"
  jq -n --argjson s "$state" \
    '{phase: "triaged", category: "", issue_url: ($s.issue_url // "")}' \
    > "$RESULT_FILE"
fi
