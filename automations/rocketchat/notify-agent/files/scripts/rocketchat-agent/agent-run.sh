#!/usr/bin/env bash
# Entrypoint driver — stateless (notifications are one-shot; no doorbell diffing).
# Env: MODE (ship|incident|ask), plus per-mode context:
#   ship:     RELEASE_TAG
#   incident: WF_NAME, WF_URL, WF_RUN_ID
#   ask:      ASK_TEXT (the channel question, trigger word already stripped)
# DRY_RUN=1 assembles the prompt but skips the AI and the push.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
SCRIPTS="scripts/rocketchat-agent"
source "$SCRIPTS/env.sh"
source "$SCRIPTS/ai/brain.sh"
mkdir -p "$OUT_DIR"

MODE="${MODE:?set MODE=ship|incident|ask}"
[[ ",$ENABLED_HANDLERS," == *",$MODE,"* ]] || { echo "handler '$MODE' disabled — nothing to do"; exit 0; }

# Gather mode-specific context for the prompt (best effort — the playbook
# is told to work with what's here).
CONTEXT_FILE="$OUT_DIR/context-$MODE.md"
case "$MODE" in
  ship)
    {
      echo "## Release"
      gh release view "${RELEASE_TAG:?}" --json name,tagName,body,url,publishedAt 2>/dev/null \
        || echo "(release metadata unavailable — tag: ${RELEASE_TAG:-unknown})"
      echo
      echo "## Recent commits"
      git log -20 --oneline 2>/dev/null || true
    } > "$CONTEXT_FILE"
    ;;
  incident)
    {
      echo "## Failed workflow"
      echo "name: ${WF_NAME:-unknown}"
      echo "url: ${WF_URL:-unknown}"
      echo
      echo "## Failing log excerpt (truncated)"
      if [[ -n "${WF_RUN_ID:-}" ]]; then
        gh run view "$WF_RUN_ID" --log-failed 2>/dev/null | tail -c 8000 || echo "(log unavailable)"
      else
        echo "(no run id)"
      fi
    } > "$CONTEXT_FILE"
    ;;
  ask)
    printf '## Question from Rocket.Chat (trigger word)\n\n%s\n' "${ASK_TEXT:-"(empty)"}" > "$CONTEXT_FILE"
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
  echo "- push_helper (use this to send your ONE message): scripts/rocketchat-agent/push.sh <body-file>"
  echo "- result_file (write your result JSON here as your final action): $RESULT_FILE"
  echo
  echo "## Gathered context"
  echo
  cat "$CONTEXT_FILE"
} > "$prompt_file"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "DRY_RUN: prompt assembled at $prompt_file — no AI, no push"
  exit 0
fi

echo "running playbook '$MODE' (brain: $AI_NAME, model: ${AI_MODEL:-default})"
transcript="$OUT_DIR/transcript-$MODE.jsonl"
ai_run "$prompt_file" "$transcript"
ai_result "$transcript"

# Driver-mediated write-back: a text-only brain can't run the push helper —
# its reply IS the message body, and this driver delivers it.
if [[ "${CAN_RUN_TOOLS:-1}" == "0" ]]; then
  body="$(ai_result "$transcript")"
  if [[ -z "$body" ]]; then
    echo "error: text-only brain returned an empty message body — nothing delivered" >&2
    exit 1
  fi
  body_file="$OUT_DIR/body-$MODE.txt"
  printf '%s\n' "$body" > "$body_file"
  "$SCRIPTS/push.sh" "$body_file"
  case "$MODE" in
    ship)     printf '{"phase": "shipped"}\n'  > "$RESULT_FILE" ;;
    incident) printf '{"phase": "notified"}\n' > "$RESULT_FILE" ;;
    ask)      printf '{"phase": "answered"}\n' > "$RESULT_FILE" ;;
  esac
fi
