#!/usr/bin/env bash
# AI brain adapter: OpenAI Codex CLI (agentic — explores the repo, edits code,
# runs the helper scripts, opens PRs). Installed into a target repo as
# <agent-dir>/ai/brain.sh. Contract: core/ai/README.md.

AI_NAME="codex"
CAN_EDIT_REPO=1
CAN_RUN_TOOLS=1
HAS_TRANSCRIPT=1
AI_AUTH_VARS="OPENAI_API_KEY"
AI_DEFAULT_MODEL="gpt-5-codex"

ai_install() {
  npm install -g @openai/codex
}

ai_check() {
  command -v codex >/dev/null 2>&1 || {
    echo "codex CLI not found (npm install -g @openai/codex)" >&2
    return 1
  }
  [[ -n "${OPENAI_API_KEY:-}" || -f "$HOME/.codex/auth.json" ]] || {
    echo "set OPENAI_API_KEY (or sign in once with 'codex login')" >&2
    return 1
  }
}

# --json emits event lines (timestamped like the other adapters);
# --output-last-message pins the final answer so ai_result never has to
# guess at the event schema.
ai_run() {
  local prompt_file="$1" transcript="$2"
  codex exec \
    --model "${AI_MODEL:-gpt-5-codex}" \
    --full-auto --json \
    --output-last-message "$transcript.last" \
    - < "$prompt_file" \
    | perl -MPOSIX -pe 'BEGIN { $| = 1 } $_ = strftime("%H:%M:%S", gmtime) . "\t" . $_' \
    > "$transcript"
}

ai_result() {
  if [[ -s "$1.last" ]]; then
    cat "$1.last"
  else
    echo "(no final message captured — see the transcript artifact)"
  fi
}
