#!/usr/bin/env bash
# Entrypoint driver: restore state → resolve thread(s) → run playbook(s) → save state.
# Env: ITEM_ID ("<channel>:<root_ts>"; empty = re-check tracked threads),
#      EVENT_KIND (mention|channel|reaction|dm), DRY_RUN=1 (no AI, no push).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
SCRIPTS="scripts/slack-agent"
source "$SCRIPTS/env.sh"
mkdir -p "$OUT_DIR"

# The bot's own user id — structural loop protection (no marker needed).
SLACK_BOT_USER_ID=$(bash "$SCRIPTS/api.sh" auth.test | jq -r '.user_id // ""')
export SLACK_BOT_USER_ID
echo "bot user: $SLACK_BOT_USER_ID"

bash "$SCRIPTS/state.sh" restore

# Work items are "channel:root_ts|kind".
if [[ -n "${ITEM_ID:-}" ]]; then
  items=("$ITEM_ID|${EVENT_KIND:-}")
else
  echo "reconcile: re-checking tracked threads"
  items=()
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    # State filenames are channel-ts (ts contains a dot, channel never has '-'
    # in the middle... but ids are C…/D… with no '-', so split on the FIRST '-'.
    channel="${key%%-*}"
    root_ts="${key#*-}"
    items+=("$channel:$root_ts|")
  done < <(ls "$STATE_DIR/state" 2>/dev/null | sed 's/\.json$//')
fi

FAILED=0
for entry in ${items[@]+"${items[@]}"}; do
  id_part="${entry%%|*}"
  kind_hint="${entry#*|}"
  channel="${id_part%%:*}"
  root_ts="${id_part#*:}"
  [[ -z "$channel" || -z "$root_ts" ]] && continue
  state_key="$(printf '%s' "$id_part" | tr ':' '-')"

  decision_json=$(bash "$SCRIPTS/resolve-item.sh" "$channel" "$root_ts" "$kind_hint")
  echo "resolved: $decision_json"
  decision=$(jq -r '.decision' <<<"$decision_json")
  kind=$(jq -r '.kind // "channel"' <<<"$decision_json")
  latest_ts=$(jq -r '.latest_ts // "0"' <<<"$decision_json")

  # Never start tracking threads that produced no work.
  if [[ "$decision" == "skip" && ! -f "$STATE_DIR/state/$state_key.json" ]]; then
    continue
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    [[ "$decision" != "skip" ]] && echo "DRY_RUN: would run playbook '$decision' for $id_part"
  elif [[ "$decision" != "skip" ]]; then
    if ! bash "$SCRIPTS/run-playbook.sh" "$decision" "$channel" "$root_ts" "$decision_json"; then
      echo "playbook '$decision' failed for $id_part" >&2
      FAILED=1
      continue
    fi
    # Re-read so the agent's own reply is consumed and never reprocessed.
    latest_ts=$(bash "$SCRIPTS/api.sh" conversations.replies \
      --data-urlencode "channel=$channel" --data-urlencode "ts=$root_ts" \
      --data-urlencode "limit=100" 2>/dev/null \
      | jq -r '[.messages[].ts | tonumber] | max // '"$latest_ts")
  fi

  result='{}'
  rf="$OUT_DIR/result-$state_key.json"
  if [[ -f "$rf" ]] && jq -e . "$rf" >/dev/null 2>&1; then
    result=$(cat "$rf")
  fi
  prev='{}'
  [[ -f "$STATE_DIR/state/$state_key.json" ]] && prev=$(cat "$STATE_DIR/state/$state_key.json")
  [[ "${DRY_RUN:-0}" == "1" ]] && result='{}'

  jq -n \
    --argjson prev "$prev" --argjson result "$result" \
    --arg item_id "$id_part" --arg channel "$channel" --arg root_ts "$root_ts" \
    --arg kind "$kind" --arg last_ts "$latest_ts" \
    '$prev + $result + {item_id: $item_id, item_type: "Thread", channel: $channel,
      root_ts: $root_ts, kind: $kind, last_ts: $last_ts, updated_at: (now | todate)}' \
    > "$STATE_DIR/state/$state_key.json"
done

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "DRY_RUN: state not saved"
else
  bash "$SCRIPTS/state.sh" save "agent: ${EVENT_KIND:-manual} run"
fi

exit "$FAILED"
