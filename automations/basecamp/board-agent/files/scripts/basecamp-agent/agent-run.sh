#!/usr/bin/env bash
# Entrypoint driver: restore state → resolve card(s) → run playbook(s) → save state.
# Env: CARD_ID (empty = reconcile), EVENT_KIND, DRY_RUN=1 (resolve only, no AI, no push).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
SCRIPTS="scripts/basecamp-agent"
source "$SCRIPTS/env.sh"
mkdir -p "$OUT_DIR"

bash "$SCRIPTS/state.sh" restore

if [[ -n "${CARD_ID:-}" ]]; then
  card_ids=("$CARD_ID")
else
  echo "reconcile: scanning watched columns + tracked cards"
  card_ids=()
  while IFS= read -r cid; do
    [[ -n "$cid" ]] && card_ids+=("$cid")
  done < <(
    {
      basecamp cards list --column "$BC_COL_ANALYZE" --in "$BC_PROJECT_ID" --all --agent | jq -r '(. // [])[].id'
      basecamp cards list --column "$BC_COL_IMPLEMENT" --in "$BC_PROJECT_ID" --all --agent | jq -r '(. // [])[].id'
      ls "$STATE_DIR/state" 2>/dev/null | sed 's/\.json$//'
    } | sort -u
  )
fi

FAILED=0
for card_id in ${card_ids[@]+"${card_ids[@]}"}; do
  [[ -z "$card_id" ]] && continue
  decision_json=$(bash "$SCRIPTS/resolve-card.sh" "$card_id")
  echo "resolved: $decision_json"
  decision=$(jq -r '.decision' <<<"$decision_json")
  column_id=$(jq -r '.column_id // 0' <<<"$decision_json")
  latest_comment_id=$(jq -r '.latest_comment_id // 0' <<<"$decision_json")

  # Don't start tracking cards that are neither watched nor previously tracked.
  if [[ "$decision" == "skip" && ! -f "$STATE_DIR/state/$card_id.json" \
        && "$column_id" != "$BC_COL_ANALYZE" && "$column_id" != "$BC_COL_IMPLEMENT" ]]; then
    continue
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    [[ "$decision" != "skip" ]] && echo "DRY_RUN: would run playbook '$decision' for card $card_id"
  elif [[ "$decision" != "skip" ]]; then
    if ! bash "$SCRIPTS/run-playbook.sh" "$decision" "$card_id" "$decision_json"; then
      echo "playbook '$decision' failed for card $card_id" >&2
      FAILED=1
      # Leave previous state untouched so the next doorbell retries this decision.
      continue
    fi
    # Re-read so the agent's own new comment is consumed and never reprocessed.
    latest_comment_id=$(basecamp comments list "$card_id" --in "$BC_PROJECT_ID" --all --agent 2>/dev/null \
      | jq -r '[(. // [])[].id] | max // 0')
    column_id=$(basecamp cards show "$card_id" --in "$BC_PROJECT_ID" --agent 2>/dev/null \
      | jq -r '.parent.id // 0' || echo "$column_id")
  fi

  # Merge: previous state ← default phase for the playbook ← playbook result ← observed facts.
  result='{}'
  if [[ -f "$OUT_DIR/result-$card_id.json" ]] && jq -e . "$OUT_DIR/result-$card_id.json" >/dev/null 2>&1; then
    result=$(cat "$OUT_DIR/result-$card_id.json")
  fi
  prev='{}'
  [[ -f "$STATE_DIR/state/$card_id.json" ]] && prev=$(cat "$STATE_DIR/state/$card_id.json")
  case "$decision" in
    analyze)   default_phase='{"phase":"analyzed"}' ;;
    respond)   default_phase='{"phase":"analyzed"}' ;;
    implement) default_phase='{"phase":"implementing"}' ;;
    *)         default_phase='{}' ;;
  esac
  [[ "${DRY_RUN:-0}" == "1" ]] && { result='{}'; default_phase='{}'; }

  jq -n \
    --argjson prev "$prev" --argjson default "$default_phase" --argjson result "$result" \
    --argjson card_id "$card_id" --argjson column_id "$column_id" \
    --argjson last_comment_id "$latest_comment_id" \
    '$prev + $default + $result + {card_id: $card_id, column_id: $column_id,
      last_comment_id: $last_comment_id, updated_at: (now | todate)}' \
    > "$STATE_DIR/state/$card_id.json"
done

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "DRY_RUN: state not saved"
else
  bash "$SCRIPTS/state.sh" save "agent: ${EVENT_KIND:-manual} run"
fi

exit "$FAILED"
