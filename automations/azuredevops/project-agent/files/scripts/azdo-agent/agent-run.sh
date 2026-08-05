#!/usr/bin/env bash
# Entrypoint driver: restore state → resolve item(s) → run playbook(s) → save state.
# Env: ITEM_ID (work item id; empty = reconcile), ITEM_TYPE, EVENT_KIND,
#      DRY_RUN=1 (resolve only, no AI, no push).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
SCRIPTS="scripts/azdo-agent"
source "$SCRIPTS/env.sh"
mkdir -p "$OUT_DIR"

items_in_state() { # items_in_state <state display name> → work item ids
  # WIQL string literals escape single quotes by doubling them. The quote is
  # spelled \u0027 in the jq program to stay clear of shell quoting.
  local body
  body=$(jq -cn --arg s "$1" \
    '{query: ("SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.State] = \u0027" + ($s | gsub("\u0027"; "\u0027\u0027")) + "\u0027")}')
  bash "$SCRIPTS/api.sh" POST "/wit/wiql" "$body" | jq -r '.workItems[].id'
}

bash "$SCRIPTS/state.sh" restore

if [[ -n "${ITEM_ID:-}" ]]; then
  items=("$ITEM_ID|${ITEM_TYPE:-WorkItem}")
else
  echo "reconcile: scanning watched states + tracked items"
  items=()
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && items+=("$entry")
  done < <(
    {
      if [[ ",$ENABLED_HANDLERS," == *",workitems,"* ]]; then
        items_in_state "$STATE_ANALYZE" | sed 's/$/|WorkItem/'
        items_in_state "$STATE_IMPLEMENT" | sed 's/$/|WorkItem/'
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

  decision_json=$(bash "$SCRIPTS/resolve-item.sh" "$item_id" "${type_hint:-WorkItem}")
  echo "resolved: $decision_json"
  decision=$(jq -r '.decision' <<<"$decision_json")
  state_name=$(jq -r '.state_name // ""' <<<"$decision_json")
  latest_comment_id=$(jq -r '.latest_comment_id // 0' <<<"$decision_json")

  # Never start tracking items that produced no work.
  if [[ "$decision" == "skip" && ! -f "$STATE_DIR/state/$item_id.json" ]]; then
    continue
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    [[ "$decision" != "skip" ]] && echo "DRY_RUN: would run playbook '$decision' for work item $item_id"
  elif [[ "$decision" != "skip" ]]; then
    if ! bash "$SCRIPTS/run-playbook.sh" "$decision" "$item_id" "$decision_json"; then
      echo "playbook '$decision' failed for work item $item_id" >&2
      FAILED=1
      # Leave previous state untouched so the next doorbell retries this decision.
      continue
    fi
    # Re-read so the agent's own new comment is consumed and never reprocessed.
    latest_comment_id=$(bash "$SCRIPTS/api.sh" GET "/wit/workItems/$item_id/comments?api-version=7.1-preview.4" 2>/dev/null \
      | jq -r '[.comments[].id] | max // '"$latest_comment_id")
    state_name=$(bash "$SCRIPTS/api.sh" GET "/wit/workitems/$item_id" 2>/dev/null \
      | jq -r ".fields[\"System.State\"] // \"$state_name\" | ascii_downcase")
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
    --arg item_id "$item_id" --arg state_name "$state_name" \
    --argjson last_comment_id "$latest_comment_id" \
    '$prev + $default + $result + {item_id: $item_id, item_type: "WorkItem",
      state_name: $state_name, last_comment_id: $last_comment_id, updated_at: (now | todate)}' \
    > "$STATE_DIR/state/$item_id.json"
done

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "DRY_RUN: state not saved"
else
  bash "$SCRIPTS/state.sh" save "agent: ${EVENT_KIND:-manual} run"
fi

exit "$FAILED"
