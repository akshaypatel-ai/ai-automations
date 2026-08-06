#!/usr/bin/env bash
# AI brain adapter: Gemini CLI (agentic — explores the repo, edits code, runs
# the helper scripts; generous free tier makes it the cheapest way to trial an
# automation). Installed into a target repo as <agent-dir>/ai/brain.sh.
# Contract: core/ai/README.md.

AI_NAME="gemini-cli"
CAN_EDIT_REPO=1
CAN_RUN_TOOLS=1
HAS_TRANSCRIPT=1
AI_AUTH_VARS="GEMINI_API_KEY"
AI_DEFAULT_MODEL="gemini-2.5-pro"

ai_install() {
  npm install -g @google/gemini-cli
}

ai_check() {
  command -v gemini >/dev/null 2>&1 || {
    echo "gemini CLI not found (npm install -g @google/gemini-cli)" >&2
    return 1
  }
  [[ -n "${GEMINI_API_KEY:-}" || -n "${GOOGLE_API_KEY:-}" || -d "$HOME/.gemini" ]] || {
    echo "set GEMINI_API_KEY (aistudio.google.com/apikey) or sign in once with 'gemini'" >&2
    return 1
  }
}

# The Gemini CLI has no stable machine-readable stream — the transcript is its
# full stdout/stderr, timestamped per line. Good enough to audit; ai_result
# tails it for the CI log.
ai_run() {
  local prompt_file="$1" transcript="$2"
  gemini --yolo \
    -m "${AI_MODEL:-gemini-2.5-pro}" \
    < "$prompt_file" 2>&1 \
    | perl -MPOSIX -pe 'BEGIN { $| = 1 } $_ = strftime("%H:%M:%S", gmtime) . "\t" . $_' \
    > "$transcript"
}

ai_result() {
  cut -f2- "$1" | tail -n 40
}
