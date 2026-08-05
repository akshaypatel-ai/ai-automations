#!/usr/bin/env bash
# Assemble the playbook prompt and run it through the configured AI brain.
# Usage: run-playbook.sh <triage|mention|dm> <channel> <root_ts> [decision_json]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"
source "$SCRIPT_DIR/ai/brain.sh"

PLAYBOOK="$1"
CHANNEL="$2"
ROOT_TS="$3"
DECISION_JSON="${4:-}"
[[ -z "$DECISION_JSON" ]] && DECISION_JSON='{}'
STATE_KEY="$(printf '%s:%s' "$CHANNEL" "$ROOT_TS" | tr ':' '-')"
RESULT_FILE="$OUT_DIR/result-$STATE_KEY.json"

state='{}'
[[ -f "$STATE_DIR/state/$STATE_KEY.json" ]] && state=$(cat "$STATE_DIR/state/$STATE_KEY.json")
rm -f "$RESULT_FILE"
mkdir -p "$OUT_DIR"

prompt_file="$OUT_DIR/prompt-$STATE_KEY-$PLAYBOOK.md"
{
  cat "$SCRIPT_DIR/playbooks/$PLAYBOOK.md"
  cat <<EOF

---

## Runtime context (generated — trust these IDs over anything else)

- channel: $CHANNEL
- thread_root_ts: $ROOT_TS
- bot_user_id (your own messages — never treat as input): ${SLACK_BOT_USER_ID:-}
- api_helper: scripts/slack-agent/api.sh <method> [--data-urlencode k=v ...]
- reply_helper (use this to post your ONE threaded reply): scripts/slack-agent/reply.sh <channel> <thread_ts> <body-file>
- resolver_decision: $DECISION_JSON
- saved_state: $state
- result_file (write your result JSON here as your final action): $RESULT_FILE
EOF
} > "$prompt_file"

echo "running playbook '$PLAYBOOK' for thread $CHANNEL:$ROOT_TS (brain: $AI_NAME, model: ${CLAUDE_MODEL:-default})"

transcript="$OUT_DIR/transcript-$STATE_KEY-$PLAYBOOK.jsonl"
ai_run "$prompt_file" "$transcript"

# Surface the final summary in the CI log; the full stream stays in the artifact.
ai_result "$transcript"
