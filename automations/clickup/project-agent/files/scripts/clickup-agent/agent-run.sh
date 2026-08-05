#!/usr/bin/env bash
# Entrypoint driver: restore state → resolve item(s) → run playbook(s) → save state.
# Env: ITEM_ID (task id; empty = reconcile), ITEM_TYPE, EVENT_KIND,
#      DRY_RUN=1 (resolve only, no AI, no push).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
SCRIPTS="scripts/clickup-agent"
source "$SCRIPTS/env.sh"
mkdir -p "$OUT_DIR"

tasks_in_status() { # tasks_in_status <status name (lowercase)> → task ids
  bash "$SCRIPTS/api.sh" GET "/list/$CLICKUP_LIST_ID/task?include_closed=false" \
    | jq -r --arg s "$1" '.tasks[] | select((.status.status | ascii_downcase) == $s) | .id'
}

bash "$SCRIPTS/state.sh" restore

if [[ -n "${ITEM_ID:-}" ]]; then
  items=("$ITEM_ID|${ITEM_TYPE:-Task}")
else
  echo "reconcile: scanning watched statuses + tracked items"
  items=()
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && items+=("$entry")
  done < <(
    {
      if [[ ",$ENABLED_HANDLERS," == *",tasks,"* && -n "$CLICKUP_LIST_ID" ]]; then
        tasks_in_status "$(printf '%s' "$STATUS_ANALYZE" | tr '[:upper:]' '[:lower:]')" | sed 's/$/|Task/'
        tasks_in_status "$(printf '%s' "$STATUS_IMPLEMENT" | tr '[:upper:]' '[:lower:]')" | sed 's/$/|Task/'
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

  decision_json=$(bash "$SCRIPTS/resolve-item.sh" "$item_id" "${type_hint:-Task}")
  echo "resolved: $decision_json"
  decision=$(jq -r '.decision' <<<"$decision_json")
  status_name=$(jq -r '.status_name // ""' <<<"$decision_json")
  latest_comment_date=$(jq -r '.latest_comment_date // 0' <<<"$decision_json")

  # Never start tracking items that produced no work.
  if [[ "$decision" == "skip" && ! -f "$STATE_DIR/state/$item_id.json" ]]; then
    continue
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    [[ "$decision" != "skip" ]] && echo "DRY_RUN: would run playbook '$decision' for task $item_id"
  elif [[ "$decision" != "skip" ]]; then
    if ! bash "$SCRIPTS/run-playbook.sh" "$decision" "$item_id" "$decision_json"; then
      echo "playbook '$decision' failed for task $item_id" >&2
      FAILED=1
      # Leave previous state untouched so the next doorbell retries this decision.
      continue
    fi
    # Re-read so the agent's own new comment is consumed and never reprocessed.
    latest_comment_date=$(bash "$SCRIPTS/api.sh" GET "/task/$item_id/comment" 2>/dev/null \
      | jq -r '[.comments[].date | tonumber] | max // '"$latest_comment_date")
    status_name=$(bash "$SCRIPTS/api.sh" GET "/task/$item_id" 2>/dev/null \
      | jq -r ".status.status // \"$status_name\" | ascii_downcase")
  fi

  # Merge: previous state ← default phase for the playbook ← playbook result ← observed facts.
  result='{}'
  if [[ -f "$OUT_DIR/result-$item_id.json" ]] && jq -e . "$OUT_DIR/result-$item_id.json" >/dev/null 2>&1; then
    result=$(cat "$OUT_DIR/result-$item_id.json")
  fi
  prev='{}'
  [[ -f "$STATE_DIR/state/$item_id.json" ]] && prev=$(cat "$STATE_DIR/state/$item_id.json")
  case "$decision" in
    analyze)   default_phase='{"phase":"analyzed"}' ;;
    respond)   default_phase='{"phase":"analyzed"}' ;;
    implement) default_phase='{"phase":"implementing"}' ;;
    *)         default_phase='{}' ;;
  esac
  [[ "${DRY_RUN:-0}" == "1" ]] && { result='{}'; default_phase='{}'; }

  jq -n \
    --argjson prev "$prev" --argjson default "$default_phase" --argjson result "$result" \
    --arg item_id "$item_id" --arg status_name "$status_name" \
    --argjson last_comment_date "$latest_comment_date" \
    '$prev + $default + $result + {item_id: $item_id, item_type: "Task",
      status_name: $status_name, last_comment_date: $last_comment_date, updated_at: (now | todate)}' \
    > "$STATE_DIR/state/$item_id.json"
done

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "DRY_RUN: state not saved"
else
  bash "$SCRIPTS/state.sh" save "agent: ${EVENT_KIND:-manual} run"
fi

exit "$FAILED"
