#!/usr/bin/env bash
# Entrypoint driver: restore state → resolve item(s) → run playbook(s) → save state.
# Env: ITEM_ID (empty = reconcile), ITEM_TYPE (optional hint), EVENT_KIND,
#      DRY_RUN=1 (resolve only, no AI, no push).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
SCRIPTS="scripts/basecamp-agent"
source "$SCRIPTS/env.sh"
mkdir -p "$OUT_DIR"

has_handler() { [[ ",$ENABLED_HANDLERS," == *",$1,"* ]]; }

bash "$SCRIPTS/state.sh" restore

# Work items are "id|type" pairs (type may be empty — the resolver re-derives it).
if [[ -n "${ITEM_ID:-}" ]]; then
  items=("$ITEM_ID|${ITEM_TYPE:-}")
else
  echo "reconcile: scanning watched sources + tracked items"
  items=()
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && items+=("$entry")
  done < <(
    {
      if has_handler cards; then
        basecamp cards list --column "$BC_COL_ANALYZE" --in "$BC_PROJECT_ID" --all --agent | jq -r '(. // [])[].id | tostring + "|Kanban::Card"'
        basecamp cards list --column "$BC_COL_IMPLEMENT" --in "$BC_PROJECT_ID" --all --agent | jq -r '(. // [])[].id | tostring + "|Kanban::Card"'
      fi
      if has_handler todos; then
        if [[ -n "$BC_TODOLIST_ID" ]]; then
          basecamp todos list --in "$BC_PROJECT_ID" --list "$BC_TODOLIST_ID" --all --json | jq -r '(. // [])[].id | tostring + "|Todo"'
        else
          basecamp todos list --in "$BC_PROJECT_ID" --all --json | jq -r '(. // [])[].id | tostring + "|Todo"'
        fi
      fi
      # messages/docs/checkins/schedule have no cheap "recent" listing — they are
      # webhook-driven; tracked ones are still rescanned below, and a specific
      # item can be backfilled via the manual Run workflow with its ID.
      ls "$STATE_DIR/state" 2>/dev/null | sed 's/\.json$/|/'
    } | sort -u -t'|' -k1,1
  )
fi

FAILED=0
for entry in ${items[@]+"${items[@]}"}; do
  item_id="${entry%%|*}"
  type_hint="${entry#*|}"
  [[ -z "$item_id" ]] && continue

  decision_json=$(bash "$SCRIPTS/resolve-item.sh" "$item_id" "$type_hint")
  echo "resolved: $decision_json"
  decision=$(jq -r '.decision' <<<"$decision_json")
  item_type=$(jq -r '.item_type // ""' <<<"$decision_json")
  column_id=$(jq -r '.column_id // 0' <<<"$decision_json")
  latest_comment_id=$(jq -r '.latest_comment_id // 0' <<<"$decision_json")

  # Never start tracking items that produced no work (containers, disabled
  # handlers, cards parked in unwatched columns, completed todos, …).
  if [[ "$decision" == "skip" && ! -f "$STATE_DIR/state/$item_id.json" ]]; then
    continue
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    [[ "$decision" != "skip" ]] && echo "DRY_RUN: would run playbook '$decision' for $item_type $item_id"
  elif [[ "$decision" != "skip" ]]; then
    if ! bash "$SCRIPTS/run-playbook.sh" "$decision" "$item_id" "$decision_json"; then
      echo "playbook '$decision' failed for $item_type $item_id" >&2
      FAILED=1
      # Leave previous state untouched so the next doorbell retries this decision.
      continue
    fi
    # Re-read so the agent's own new comment is consumed and never reprocessed.
    latest_comment_id=$(basecamp comments list "$item_id" --in "$BC_PROJECT_ID" --all --agent 2>/dev/null \
      | jq -r '[(. // [])[].id] | max // 0')
    if [[ "$item_type" == "Kanban::Card" ]]; then
      column_id=$(basecamp cards show "$item_id" --in "$BC_PROJECT_ID" --agent 2>/dev/null \
        | jq -r '.parent.id // 0' || echo "$column_id")
    fi
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
    --argjson item_id "$item_id" --arg item_type "$item_type" --argjson column_id "$column_id" \
    --argjson last_comment_id "$latest_comment_id" \
    '$prev + $default + $result + {item_id: $item_id, item_type: $item_type,
      column_id: $column_id, last_comment_id: $last_comment_id, updated_at: (now | todate)}' \
    > "$STATE_DIR/state/$item_id.json"
done

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "DRY_RUN: state not saved"
else
  bash "$SCRIPTS/state.sh" save "agent: ${EVENT_KIND:-manual} run"
fi

exit "$FAILED"
