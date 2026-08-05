#!/usr/bin/env bash
# Decide which playbook (if any) applies to a Slack thread by diffing the API
# against saved state. Threads are identified as "<channel>:<root_ts>".
# Usage: resolve-item.sh <channel> <root_ts> [kind]   → prints a one-line decision JSON.
# Requires SLACK_BOT_USER_ID exported by the driver (from auth.test).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

CHANNEL="$1"
ROOT_TS="$2"
KIND="${3:-}"
ITEM_ID="$CHANNEL:$ROOT_TS"
STATE_KEY="$(printf '%s' "$ITEM_ID" | tr ':' '-')"
STATE_FILE="$STATE_DIR/state/$STATE_KEY.json"

skip() { # skip <reason>
  jq -cn --arg id "$ITEM_ID" --arg r "$1" \
    '{item_id: $id, item_type: "Thread", decision: "skip", reason: $r}'
  exit 0
}

state='{}'
[[ -f "$STATE_FILE" ]] && state=$(cat "$STATE_FILE")
last_ts=$(jq -r '.last_ts // "0"' <<<"$state")
phase=$(jq -r '.phase // "new"' <<<"$state")
saved_kind=$(jq -r '.kind // ""' <<<"$state")
KIND="${KIND:-${saved_kind:-channel}}"

case "$KIND" in
  mention)  handler="mentions"; playbook="mention" ;;
  channel)  handler="channel";  playbook="triage" ;;
  reaction) handler="reactions"; playbook="triage" ;;
  dm)       handler="dm";       playbook="dm" ;;
  *) skip "unknown kind '$KIND'" ;;
esac
[[ ",$ENABLED_HANDLERS," == *",$handler,"* ]] || skip "handler '$handler' disabled"

thread=$("$SCRIPT_DIR/api.sh" conversations.replies \
  --data-urlencode "channel=$CHANNEL" \
  --data-urlencode "ts=$ROOT_TS" \
  --data-urlencode "limit=100" 2>/dev/null) || skip "thread not fetchable"

# New human input = messages after last_ts that aren't the bot's own (bot_id)
# or the agent user itself. ts strings compare numerically via tonumber.
latest_ts=$(jq -r '[.messages[].ts | tonumber] | max // 0' <<<"$thread")
new_human_count=$(jq --arg last "$last_ts" --arg bot "${SLACK_BOT_USER_ID:-}" \
  '[.messages[] | select((.ts | tonumber) > ($last | tonumber))
     | select(.bot_id == null) | select(.user != $bot and $bot != "")
   ] | length' <<<"$thread")

decision="skip"
reason="nothing new"
if [[ ! -f "$STATE_FILE" ]]; then
  decision="$playbook"; reason="new $KIND thread"
elif [[ "$new_human_count" -gt 0 ]]; then
  decision="$playbook"; reason="new human message in thread"
fi

jq -cn \
  --arg item_id "$ITEM_ID" \
  --arg channel "$CHANNEL" \
  --arg root_ts "$ROOT_TS" \
  --arg kind "$KIND" \
  --arg decision "$decision" \
  --arg reason "$reason" \
  --arg prev_phase "$phase" \
  --arg latest_ts "$latest_ts" \
  --argjson new_human_count "$new_human_count" \
  '{item_id: $item_id, item_type: "Thread", channel: $channel, root_ts: $root_ts,
    kind: $kind, decision: $decision, reason: $reason, prev_phase: $prev_phase,
    latest_ts: $latest_ts, new_human_count: $new_human_count}'
