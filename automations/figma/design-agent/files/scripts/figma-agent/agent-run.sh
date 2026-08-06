#!/usr/bin/env bash
# Entrypoint driver — stateless (each summon is one Q&A round-trip; no doorbell diffing).
# Env: MODE (ask), plus context:
#   ask: ASK_TEXT, FILE_KEY, ROOT_ID (the thread's root comment id)
# DRY_RUN=1 assembles the prompt but skips the AI and the reply.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
SCRIPTS="scripts/figma-agent"
source "$SCRIPTS/env.sh"
source "$SCRIPTS/ai/brain.sh"
mkdir -p "$OUT_DIR"

MODE="${MODE:?set MODE=ask}"
# Comments are the single handler family — every mode rides on it.
[[ ",$ENABLED_HANDLERS," == *",comments,"* ]] || { echo "handler 'comments' disabled — nothing to do"; exit 0; }

# Gather mode-specific context for the prompt (best effort — the playbook
# is told to work with what's here).
CONTEXT_FILE="$OUT_DIR/context-$MODE.md"
case "$MODE" in
  ask)
    FILE_KEY="${FILE_KEY:?set FILE_KEY (the key in figma.com/design/<key>/…)}"
    ROOT_ID="${ROOT_ID:?set ROOT_ID (root comment id of the thread)}"
    {
      echo "## Figma file"
      # depth=1 keeps the response to metadata — never pull the whole document tree.
      file_name="$("$SCRIPTS/api.sh" GET "/v1/files/$FILE_KEY?depth=1" 2>/dev/null | jq -r '.name // empty' || true)"
      echo "name: ${file_name:-unknown}"
      echo "key: $FILE_KEY"
      echo
      echo "## Comment thread (chronological)"
      "$SCRIPTS/api.sh" GET "/v1/files/$FILE_KEY/comments" 2>/dev/null \
        | jq -r --arg root "$ROOT_ID" \
            '[.comments[] | select(.id == $root or .parent_id == $root)]
             | sort_by(.created_at) | .[] | "\(.user.handle): \(.message)"' \
        || echo "(thread unavailable)"
      echo
      echo "## Question"
      printf '%s\n' "${ASK_TEXT:-"(empty)"}"
    } > "$CONTEXT_FILE"
    ;;
  *)
    echo "unknown MODE '$MODE'" >&2; exit 1
    ;;
esac

RESULT_FILE="$OUT_DIR/result-$MODE.json"
rm -f "$RESULT_FILE"

prompt_file="$OUT_DIR/prompt-$MODE.md"
{
  cat "$SCRIPTS/playbooks/$MODE.md"
  if [[ "${CAN_RUN_TOOLS:-1}" == "0" ]]; then
    cat <<'EOF'

## TEXT-ONLY MODE (overrides delivery instructions above)

You cannot run commands or scripts. Do NOT attempt tool calls, do NOT
write a result file. Reply with ONLY the final message body, exactly as
it should be delivered — no preamble, no commentary. The system
delivers it for you.
EOF
  fi
  echo
  echo "---"
  echo
  echo "## Runtime context (generated — trust these values over anything else)"
  echo
  echo "- mode: $MODE"
  echo "- file_key: $FILE_KEY"
  echo "- root_comment_id (reply here): $ROOT_ID"
  echo "- reply_helper (use this to send your ONE reply): scripts/figma-agent/reply.sh <file_key> <root_comment_id> <body-file>"
  echo "- marker (your replies start with this): $AGENT_MARKER"
  echo "- result_file (write your result JSON here as your final action): $RESULT_FILE"
  echo
  echo "## Gathered context"
  echo
  cat "$CONTEXT_FILE"
} > "$prompt_file"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "DRY_RUN: prompt assembled at $prompt_file — no AI, no reply"
  exit 0
fi

echo "running playbook '$MODE' (brain: $AI_NAME, model: ${AI_MODEL:-default})"
transcript="$OUT_DIR/transcript-$MODE.jsonl"
ai_run "$prompt_file" "$transcript"
ai_result "$transcript"

# Driver-mediated write-back: a text-only brain can't run the reply helper —
# its reply IS the answer body, and this driver delivers it.
if [[ "${CAN_RUN_TOOLS:-1}" == "0" ]]; then
  body="$(ai_result "$transcript")"
  if [[ -z "$body" ]]; then
    echo "error: text-only brain returned an empty reply body — nothing delivered" >&2
    exit 1
  fi
  body_file="$OUT_DIR/body-$MODE.txt"
  printf '%s\n' "$body" > "$body_file"
  "$SCRIPTS/reply.sh" "$FILE_KEY" "$ROOT_ID" "$body_file"
  case "$MODE" in
    ask) printf '{"phase": "answered"}\n' > "$RESULT_FILE" ;;
  esac
fi
