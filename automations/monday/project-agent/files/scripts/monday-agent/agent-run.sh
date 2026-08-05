#!/usr/bin/env bash
# Entrypoint driver: restore state → resolve item(s) → run playbook(s) → save state.
# Env: ITEM_ID (item id; empty = reconcile), ITEM_TYPE, EVENT_KIND,
#      DRY_RUN=1 (resolve only, no AI, no push).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
SCRIPTS="scripts/monday-agent"
source "$SCRIPTS/env.sh"
mkdir -p "$OUT_DIR"

items_in_status() { # items_in_status <status label (as configured)> → item ids
  bash "$SCRIPTS/api.sh" \
    'query ($board: ID!, $col: String!, $vals: [String]!) {
       items_page_by_column_values (board_id: $board,
         columns: [{column_id: $col, column_values: $vals}], limit: 100) {
         items { id }
       }
     }' \
    "$(jq -cn --arg b "$MONDAY_BOARD_ID" --arg c "$STATUS_COLUMN_ID" --arg v "$1" \
       '{board: $b, col: $c, vals: [$v]}')" \
    | jq -r '.data.items_page_by_column_values.items[].id'
}

bash "$SCRIPTS/state.sh" restore

if [[ -n "${ITEM_ID:-}" ]]; then
  items=("$ITEM_ID|${ITEM_TYPE:-Item}")
else
  echo "reconcile: scanning watched statuses + tracked items"
  items=()
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && items+=("$entry")
  done < <(
    {
      if [[ ",$ENABLED_HANDLERS," == *",items,"* && -n "$MONDAY_BOARD_ID" ]]; then
        items_in_status "$STATUS_ANALYZE" | sed 's/$/|Item/'
        items_in_status "$STATUS_IMPLEMENT" | sed 's/$/|Item/'
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

  decision_json=$(bash "$SCRIPTS/resolve-item.sh" "$item_id" "${type_hint:-Item}")
  echo "resolved: $decision_json"
  decision=$(jq -r '.decision' <<<"$decision_json")
  status_name=$(jq -r '.status_name // ""' <<<"$decision_json")
  latest_comment_at=$(jq -r '.latest_comment_at // ""' <<<"$decision_json")

  # Never start tracking items that produced no work.
  if [[ "$decision" == "skip" && ! -f "$STATE_DIR/state/$item_id.json" ]]; then
    continue
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    [[ "$decision" != "skip" ]] && echo "DRY_RUN: would run playbook '$decision' for item $item_id"
  elif [[ "$decision" != "skip" ]]; then
    if ! bash "$SCRIPTS/run-playbook.sh" "$decision" "$item_id" "$decision_json"; then
      echo "playbook '$decision' failed for item $item_id" >&2
      FAILED=1
      # Leave previous state untouched so the next doorbell retries this decision.
      continue
    fi
    # Re-read so the agent's own new update is consumed and never reprocessed.
    fresh=$(bash "$SCRIPTS/api.sh" \
      'query ($ids: [ID!], $cols: [String!]) {
         items (ids: $ids) {
           column_values (ids: $cols) { text }
           updates (limit: 100) { created_at }
         }
       }' \
      "$(jq -cn --arg id "$item_id" --arg col "$STATUS_COLUMN_ID" '{ids: [$id], cols: [$col]}')" \
      2>/dev/null || echo '{}')
    latest_comment_at=$(jq -r --arg prev "$latest_comment_at" \
      '[.data.items[0].updates[]?.created_at] | max // $prev' <<<"$fresh")
    status_name=$(jq -r --arg prev "$status_name" \
      '(.data.items[0].column_values[0].text // $prev) | ascii_downcase' <<<"$fresh")
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
    --arg last_comment_at "$latest_comment_at" \
    '$prev + $default + $result + {item_id: $item_id, item_type: "Item",
      status_name: $status_name, last_comment_at: $last_comment_at, updated_at: (now | todate)}' \
    > "$STATE_DIR/state/$item_id.json"
done

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "DRY_RUN: state not saved"
else
  bash "$SCRIPTS/state.sh" save "agent: ${EVENT_KIND:-manual} run"
fi

exit "$FAILED"
