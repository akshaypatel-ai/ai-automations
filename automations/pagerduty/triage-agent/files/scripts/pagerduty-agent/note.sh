#!/usr/bin/env bash
# Post ONE note on a PagerDuty incident. Notes are the agent's ONLY write
# surface — this helper cannot acknowledge, resolve, assign, or escalate.
# PagerDuty requires the note's author via a "From: <email>" header naming a
# real user on the account; this helper adds it from PAGERDUTY_FROM_EMAIL.
# Usage: note.sh <incident_id> <body-file | body-string>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

INCIDENT_ID="$1"
BODY_ARG="$2"
if [[ -f "$BODY_ARG" ]]; then
  BODY="$(cat "$BODY_ARG")"
else
  BODY="$BODY_ARG"
fi

[[ -n "${PAGERDUTY_TOKEN:-}" ]] || { echo "error: PAGERDUTY_TOKEN not set" >&2; exit 1; }
[[ -n "${PAGERDUTY_FROM_EMAIL:-}" ]] || { echo "error: PAGERDUTY_FROM_EMAIL not set" >&2; exit 1; }

# Notes are plain text with a hard length cap — truncate rather than fail.
if [[ ${#BODY} -gt 3800 ]]; then
  BODY="${BODY:0:3800}
[truncated]"
fi

"$SCRIPT_DIR/api.sh" POST "/incidents/$INCIDENT_ID/notes" \
  "$(jq -cn --arg c "$BODY" '{note: {content: $c}}')" \
  "From: $PAGERDUTY_FROM_EMAIL" \
  | jq -e '.note.id' >/dev/null
echo "note posted on incident $INCIDENT_ID"
