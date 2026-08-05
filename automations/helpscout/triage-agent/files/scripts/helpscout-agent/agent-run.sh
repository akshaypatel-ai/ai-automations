#!/usr/bin/env bash
# Entrypoint driver: restore state → resolve item(s) → run playbook(s) → save state.
# Env: ITEM_ID (conversation id; empty = reconcile), ITEM_TYPE, EVENT_KIND,
#      DRY_RUN=1 (resolve only, no AI, no push).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
SCRIPTS="scripts/helpscout-agent"
source "$SCRIPTS/env.sh"
mkdir -p "$OUT_DIR"

recent_active_conversations() { # → active conversation ids, most recent first
  local query="/v2/conversations?status=active&sortField=createdAt&sortOrder=desc"
  # Empty HELPSCOUT_MAILBOX_ID = all mailboxes the app can see.
  [[ -n "$HELPSCOUT_MAILBOX_ID" ]] && query="$query&mailbox=$HELPSCOUT_MAILBOX_ID"
  bash "$SCRIPTS/api.sh" GET "$query" \
    | jq -r '._embedded.conversations[]?.id'
}

bash "$SCRIPTS/state.sh" restore

if [[ -n "${ITEM_ID:-}" ]]; then
  items=("$ITEM_ID|${ITEM_TYPE:-Conversation}")
else
  echo "reconcile: scanning recent active conversations + tracked items"
  items=()
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && items+=("$entry")
  done < <(
    {
      if [[ ",$ENABLED_HANDLERS," == *",conversations,"* ]]; then
        recent_active_conversations | sed 's/$/|Conversation/'
      fi
      ls "$STATE_DIR/state" 2>/dev/null | sed 's/\.json$/|/'
    } | sort -u -t'|' -k1,1
  )
fi

FAILED=0
for entry in ${items[@]+"${items[@]}"}; do
  item_id="${entry%%|*}"
  type_hint="${entry#*|}"
  [[ -z "$item_id" ]] && continue

  decision_json=$(bash "$SCRIPTS/resolve-item.sh" "$item_id" "${type_hint:-Conversation}")
  echo "resolved: $decision_json"
  decision=$(jq -r '.decision' <<<"$decision_json")
  latest_thread_id=$(jq -r '.latest_thread_id // 0' <<<"$decision_json")

  # Never start tracking items that produced no work.
  if [[ "$decision" == "skip" && ! -f "$STATE_DIR/state/$item_id.json" ]]; then
    continue
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    [[ "$decision" != "skip" ]] && echo "DRY_RUN: would run playbook '$decision' for conversation $item_id"
  elif [[ "$decision" != "skip" ]]; then
    if ! bash "$SCRIPTS/run-playbook.sh" "$decision" "$item_id" "$decision_json"; then
      echo "playbook '$decision' failed for conversation $item_id" >&2
      FAILED=1
      # Leave previous state untouched so the next doorbell retries this decision.
      continue
    fi
    # Re-read so the agent's own new note is consumed and never reprocessed.
    latest_thread_id=$(bash "$SCRIPTS/api.sh" GET "/v2/conversations/$item_id/threads" 2>/dev/null \
      | jq -r '[._embedded.threads[]?.id] | max // '"$latest_thread_id")
  fi

  # Merge: previous state ← default phase for the playbook ← playbook result ← observed facts.
  result='{}'
  if [[ -f "$OUT_DIR/result-$item_id.json" ]] && jq -e . "$OUT_DIR/result-$item_id.json" >/dev/null 2>&1; then
    result=$(cat "$OUT_DIR/result-$item_id.json")
  fi
  prev='{}'
  [[ -f "$STATE_DIR/state/$item_id.json" ]] && prev=$(cat "$STATE_DIR/state/$item_id.json")
  case "$decision" in
    triage)  default_phase='{"phase":"triaged"}' ;;
    respond) default_phase='{"phase":"triaged"}' ;;
    *)       default_phase='{}' ;;
  esac
  # DRY_RUN still records tracking for triage decisions? No — keep dry runs
  # side-effect free on state, same as every other recipe.
  [[ "${DRY_RUN:-0}" == "1" ]] && { result='{}'; default_phase='{}'; }

  jq -n \
    --argjson prev "$prev" --argjson default "$default_phase" --argjson result "$result" \
    --arg item_id "$item_id" \
    --argjson last_thread_id "$latest_thread_id" \
    '$prev + $default + $result + {item_id: $item_id, item_type: "Conversation",
      last_thread_id: $last_thread_id, updated_at: (now | todate)}' \
    > "$STATE_DIR/state/$item_id.json"
done

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "DRY_RUN: state not saved"
else
  bash "$SCRIPTS/state.sh" save "agent: ${EVENT_KIND:-manual} run"
fi

exit "$FAILED"
