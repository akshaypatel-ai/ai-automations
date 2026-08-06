#!/usr/bin/env bash
# AI brain adapter: raw Gemini generateContent API (curl + jq — no CLI
# install; the free tier makes this the cheapest brain in the collection).
# TEXT-ONLY class (CAN_RUN_TOOLS=0): usable on notify/summon/triage shapes
# via driver-mediated write-back; hidden elsewhere.
# Contract: core/ai/README.md.

AI_NAME="api-gemini"
CAN_EDIT_REPO=0
CAN_RUN_TOOLS=0
HAS_TRANSCRIPT=1
AI_AUTH_VARS="GEMINI_API_KEY"
AI_DEFAULT_MODEL="gemini-2.5-flash"

ai_install() {
  : # curl + jq only — nothing to install
}

ai_check() {
  command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || {
    echo "curl + jq required" >&2
    return 1
  }
  [[ -n "${GEMINI_API_KEY:-}" ]] || {
    echo "set GEMINI_API_KEY (aistudio.google.com/apikey)" >&2
    return 1
  }
}

# One generateContent call; the transcript is the full response (timestamped).
ai_run() {
  local prompt_file="$1" transcript="$2"
  jq -Rs '{contents: [{parts: [{text: .}]}]}' < "$prompt_file" \
  | curl -sf "https://generativelanguage.googleapis.com/v1beta/models/${AI_MODEL:-gemini-2.5-flash}:generateContent" \
      -H "x-goog-api-key: $GEMINI_API_KEY" \
      -H "Content-Type: application/json" \
      --data @- \
  | perl -MPOSIX -pe 'BEGIN { $| = 1 } $_ = strftime("%H:%M:%S", gmtime) . "\t" . $_' \
  > "$transcript"
}

ai_result() {
  cut -f2- "$1" | jq -r '[.candidates[0].content.parts[]?.text] | join("\n") | select(. != "")' 2>/dev/null \
    || echo "(unparseable response — see the transcript artifact)"
}
