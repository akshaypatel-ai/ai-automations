#!/usr/bin/env bash
# AI brain adapter: raw Anthropic Messages API (curl + jq — no CLI install,
# fastest cold start, lowest cost). TEXT-ONLY class: it cannot read the repo
# on its own, cannot run helper scripts, cannot open PRs — every current
# playbook requires those, so CAN_RUN_TOOLS=0 hides it from the brain chooser
# until driver-mediated write-back lands (Phase 2b). Shipped now so the
# contract and auth wiring are real, and for people building their own
# text-in/text-out playbooks.
# Contract: core/ai/README.md.

AI_NAME="api-anthropic"
CAN_EDIT_REPO=0
CAN_RUN_TOOLS=0
HAS_TRANSCRIPT=1
AI_AUTH_VARS="ANTHROPIC_API_KEY"
AI_DEFAULT_MODEL="claude-sonnet-5"

ai_install() {
  : # curl + jq only — nothing to install
}

ai_check() {
  command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || {
    echo "curl + jq required" >&2
    return 1
  }
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] || {
    echo "set ANTHROPIC_API_KEY" >&2
    return 1
  }
}

# One Messages call; the transcript is the full API response JSON (timestamped).
ai_run() {
  local prompt_file="$1" transcript="$2"
  jq -Rs --arg model "${AI_MODEL:-claude-sonnet-5}" \
    '{model: $model, max_tokens: 8192, messages: [{role: "user", content: .}]}' \
    < "$prompt_file" \
  | curl -sf https://api.anthropic.com/v1/messages \
      -H "x-api-key: $ANTHROPIC_API_KEY" \
      -H "anthropic-version: 2023-06-01" \
      -H "Content-Type: application/json" \
      --data @- \
  | perl -MPOSIX -pe 'BEGIN { $| = 1 } $_ = strftime("%H:%M:%S", gmtime) . "\t" . $_' \
  > "$transcript"
}

ai_result() {
  cut -f2- "$1" | jq -r '.content[]? | select(.type == "text") | .text' 2>/dev/null \
    || echo "(unparseable response — see the transcript artifact)"
}
