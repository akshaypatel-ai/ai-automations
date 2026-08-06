#!/usr/bin/env bash
# AI brain adapter: raw OpenAI Chat Completions API (curl + jq — no CLI
# install). TEXT-ONLY class (CAN_RUN_TOOLS=0): usable on notify/summon/triage
# shapes via driver-mediated write-back; hidden elsewhere.
# Contract: core/ai/README.md.

AI_NAME="api-openai"
CAN_EDIT_REPO=0
CAN_RUN_TOOLS=0
HAS_TRANSCRIPT=1
AI_AUTH_VARS="OPENAI_API_KEY"
AI_DEFAULT_MODEL="gpt-5-mini"

ai_install() {
  : # curl + jq only — nothing to install
}

ai_check() {
  command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || {
    echo "curl + jq required" >&2
    return 1
  }
  [[ -n "${OPENAI_API_KEY:-}" ]] || {
    echo "set OPENAI_API_KEY" >&2
    return 1
  }
}

# One chat call; the transcript is the full API response JSON (timestamped).
ai_run() {
  local prompt_file="$1" transcript="$2"
  jq -Rs --arg model "${AI_MODEL:-gpt-5-mini}" \
    '{model: $model, messages: [{role: "user", content: .}]}' \
    < "$prompt_file" \
  | curl -sf https://api.openai.com/v1/chat/completions \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -H "Content-Type: application/json" \
      --data @- \
  | perl -MPOSIX -pe 'BEGIN { $| = 1 } $_ = strftime("%H:%M:%S", gmtime) . "\t" . $_' \
  > "$transcript"
}

ai_result() {
  cut -f2- "$1" | jq -r '.choices[0].message.content // empty' 2>/dev/null \
    || echo "(unparseable response — see the transcript artifact)"
}
