#!/usr/bin/env bash
# Entrypoint driver — stateless (each summon is one Q&A round-trip; no doorbell diffing).
# Env: MODE (ask), plus context:
#   ask: ASK_TEXT, ITEM_ID (the question sticky's item id — optional for manual runs)
# DRY_RUN=1 assembles the prompt but skips the AI and the reply.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
SCRIPTS="scripts/miro-agent"
source "$SCRIPTS/env.sh"
source "$SCRIPTS/ai/brain.sh"
mkdir -p "$OUT_DIR"

MODE="${MODE:?set MODE=ask}"
# Stickies are the single handler family — every mode rides on it.
[[ ",$ENABLED_HANDLERS," == *",stickies,"* ]] || { echo "handler 'stickies' disabled — nothing to do"; exit 0; }

# Gather mode-specific context for the prompt (best effort — the playbook
# is told to work with what's here).
CONTEXT_FILE="$OUT_DIR/context-$MODE.md"
case "$MODE" in
  ask)
    ITEM_ID="${ITEM_ID:-}"
    {
      echo "## Board"
      board_name="$("$SCRIPTS/api.sh" GET "/v2/boards/$MIRO_BOARD_ID" 2>/dev/null | jq -r '.name // empty' 2>/dev/null || true)"
      echo "name: ${board_name:-unknown}"
      echo "id: $MIRO_BOARD_ID"
      echo
      echo "## Question sticky"
      # The relay caps the forwarded text at 1500 chars — fetch the origin
      # sticky for the full question (best effort; HTML tags stripped).
      sticky=""
      if [[ -n "$ITEM_ID" ]]; then
        sticky="$("$SCRIPTS/api.sh" GET "/v2/boards/$MIRO_BOARD_ID/items/$ITEM_ID" 2>/dev/null \
          | jq -r '.data.content // empty' 2>/dev/null | sed -e 's/<[^>]*>/ /g' || true)"
      fi
      printf '%s\n' "${sticky:-"(origin sticky unavailable)"}"
      echo
      echo "## Question (as forwarded)"
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
  echo
  echo "---"
  echo
  echo "## Runtime context (generated — trust these values over anything else)"
  echo
  echo "- mode: $MODE"
  echo "- item_id (the question sticky — reply beside it): ${ITEM_ID:-"(none — manual test run; the reply lands near the board origin)"}"
  echo "- miro_board_id: $MIRO_BOARD_ID"
  echo "- reply_helper (use this to send your ONE reply sticky): scripts/miro-agent/reply.sh <item_id> <body-file> — plain text in; it escapes, wraps, prefixes the marker, and places the sticky beside the question"
  echo "- marker (your reply stickies start with this): $AGENT_MARKER"
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
