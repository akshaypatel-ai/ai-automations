#!/usr/bin/env bash
# AI brain adapter: Claude Code (agentic CLI — can explore the repo, edit code,
# and open PRs). Installed into a target repo as <agent-dir>/ai/brain.sh.
#
# Brain adapter contract (see core/ai/README.md):
#   AI_NAME            identifier shown in logs
#   CAN_EDIT_REPO      1 when the brain may modify files / push branches
#   HAS_TRANSCRIPT     1 when ai_run produces a machine-readable transcript
#   ai_check           → 0 when deps + credentials look usable
#   ai_run    <prompt_file> <transcript_out>   run headless in $PWD
#   ai_result <transcript_out>                 print the run's final summary text

AI_NAME="claude-code"
CAN_EDIT_REPO=1
CAN_RUN_TOOLS=1
HAS_TRANSCRIPT=1
AI_AUTH_VARS="CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY"
AI_DEFAULT_MODEL="claude-sonnet-5"

ai_install() {
  npm install -g @anthropic-ai/claude-code
}

ai_check() {
  command -v claude >/dev/null 2>&1 || {
    echo "claude CLI not found (npm install -g @anthropic-ai/claude-code)" >&2
    return 1
  }
  [[ -n "${ANTHROPIC_API_KEY:-}" || -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] || {
    echo "set CLAUDE_CODE_OAUTH_TOKEN (run 'claude setup-token') or ANTHROPIC_API_KEY" >&2
    return 1
  }
}

# Stream-JSON with an arrival timestamp per event, so the transcript shows
# where playbook time actually goes (per tool call), not just the final text.
# AI_MODEL is the generic knob; CLAUDE_MODEL kept for pre-Phase-2 installs.
ai_run() {
  local prompt_file="$1" transcript="$2"
  claude -p \
    --model "${AI_MODEL:-${CLAUDE_MODEL:-claude-sonnet-5}}" \
    --dangerously-skip-permissions \
    --output-format stream-json --verbose \
    < "$prompt_file" \
    | perl -MPOSIX -pe 'BEGIN { $| = 1 } $_ = strftime("%H:%M:%S", gmtime) . "\t" . $_' \
    > "$transcript"
}

ai_result() {
  cut -f2- "$1" | jq -r 'select(.type == "result") | .result // empty'
}
