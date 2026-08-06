#!/usr/bin/env bash
# AI brain adapter: Aider (model-agnostic pair programmer — OpenAI, Anthropic,
# Gemini, or fully-local Ollama). TEXT+EDIT class: Aider can read and edit the
# repo, but headless runs CANNOT execute the recipes' helper scripts (posting
# comments, `gh pr create`), which every current playbook requires.
# CAN_RUN_TOOLS=0 — the brain chooser therefore hides it until driver-mediated
# write-back lands (Phase 2b). Shipped now so the contract and auth wiring are
# real, and for people building their own tool-free playbooks.
# Contract: core/ai/README.md.

AI_NAME="aider"
CAN_EDIT_REPO=1
CAN_RUN_TOOLS=0
HAS_TRANSCRIPT=1
AI_AUTH_VARS="OPENAI_API_KEY ANTHROPIC_API_KEY GEMINI_API_KEY"
AI_DEFAULT_MODEL="claude-sonnet-5"

ai_install() {
  python3 -m pip install --user aider-install && aider-install
}

ai_check() {
  command -v aider >/dev/null 2>&1 || {
    echo "aider not found (python3 -m pip install aider-install && aider-install)" >&2
    return 1
  }
  [[ -n "${OPENAI_API_KEY:-}" || -n "${ANTHROPIC_API_KEY:-}" || -n "${GEMINI_API_KEY:-}" ]] || {
    echo "set OPENAI_API_KEY / ANTHROPIC_API_KEY / GEMINI_API_KEY (or point --model at a local Ollama)" >&2
    return 1
  }
}

# --no-auto-commits: the drivers own git; aider only edits the working tree.
ai_run() {
  local prompt_file="$1" transcript="$2"
  aider \
    --model "${AI_MODEL:-claude-sonnet-5}" \
    --yes --no-auto-commits --no-gitignore \
    --message "$(cat "$prompt_file")" \
    2>&1 \
    | perl -MPOSIX -pe 'BEGIN { $| = 1 } $_ = strftime("%H:%M:%S", gmtime) . "\t" . $_' \
    > "$transcript"
}

ai_result() {
  cut -f2- "$1" | tail -n 40
}
