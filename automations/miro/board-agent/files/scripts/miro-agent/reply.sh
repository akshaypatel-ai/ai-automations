#!/usr/bin/env bash
# Place ONE reply sticky note beside the question sticky — the agent's only
# write surface (it never edits, moves, or deletes anything else on the
# board). Takes PLAIN TEXT and converts it to the light HTML stickies hold;
# the reply lands 260px to the right of the origin sticky and starts with
# the agent marker — which is also what the relay's echo protection keys on.
# Usage: reply.sh <origin_item_id> <body-file | body-string>
# Env: MIRO_TOKEN (api.sh), MIRO_BOARD_ID + AGENT_MARKER (from env.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ORIGIN_ID="$1"
BODY_ARG="$2"
if [[ -f "$BODY_ARG" ]]; then
  BODY="$(cat "$BODY_ARG")"
else
  BODY="$BODY_ARG"
fi

[[ -n "${MIRO_BOARD_ID:-}" ]] || { echo "error: MIRO_BOARD_ID not set (source scripts/miro-agent/env.sh)" >&2; exit 1; }
[[ -n "${AGENT_MARKER:-}" ]] || { echo "error: AGENT_MARKER not set (source scripts/miro-agent/env.sh)" >&2; exit 1; }

# Fetch the origin sticky for its position — the reply goes right beside it.
# Best effort: if the question sticky vanished, place near the board origin.
POS=""
[[ -n "$ORIGIN_ID" ]] && POS="$("$SCRIPT_DIR/api.sh" GET "/v2/boards/$MIRO_BOARD_ID/items/$ORIGIN_ID" 2>/dev/null || true)"
X="$(printf '%s' "$POS" | jq -r '.position.x // 0' 2>/dev/null || true)"
Y="$(printf '%s' "$POS" | jq -r '.position.y // 0' 2>/dev/null || true)"
[[ "$X" =~ ^-?[0-9.]+$ ]] || X=0
[[ "$Y" =~ ^-?[0-9.]+$ ]] || Y=0

# Stickies are small — truncate BEFORE escaping so the cap is on visible text.
BODY="$(printf '%s' "$BODY" | head -c 1800)"

# Plain text → sticky HTML: escape & < > (in that order), then newline → <br/>.
HTML="$(printf '%s\n' "$BODY" \
  | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        -e 's#$#<br/>#' \
  | tr -d '\n')"
HTML="${HTML%<br/>}"

# The marker rides INSIDE the content — the relay drops anything carrying it.
CONTENT="<p>$AGENT_MARKER — $HTML</p>"

"$SCRIPT_DIR/api.sh" POST "/v2/boards/$MIRO_BOARD_ID/sticky_notes" \
  "$(jq -cn --arg c "$CONTENT" --argjson x "$X" --argjson y "$Y" \
      '{data: {content: $c, shape: "square"},
        position: {x: ($x + 260), y: $y},
        style: {fillColor: "light_blue"}}')" \
  | jq -e '.id' >/dev/null
echo "reply sticky placed beside item ${ORIGIN_ID:-'(board origin)'}"
