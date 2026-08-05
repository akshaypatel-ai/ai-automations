#!/usr/bin/env bash
# Entrypoint driver: restore state → resolve item(s) → run playbook(s) → save state.
# Env: ITEM_ID (empty = reconcile), ITEM_TYPE (optional hint), EVENT_KIND,
#      DRY_RUN=1 (resolve only, no AI, no push).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
SCRIPTS="scripts/linear-agent"
source "$SCRIPTS/env.sh"
mkdir -p "$OUT_DIR"

issues_in_state() { # issues_in_state <state name> → issue UUIDs
  local filter
  filter=$(jq -cn --arg s "$1" --arg team "$LINEAR_TEAM_KEY" \
    '{state: {name: {eq: $s}}} + (if $team == "" then {} else {team: {key: {eq: $team}}} end)')
  "$SCRIPTS/api.sh" \
    'query($f: IssueFilter) { issues(filter: $f, first: 100) { nodes { id } } }' \
    "$(jq -cn --argjson f "$filter" '{f: $f}')" | jq -r '.data.issues.nodes[].id'
}

bash "$SCRIPTS/state.sh" restore

if [[ -n "${ITEM_ID:-}" ]]; then
  items=("$ITEM_ID|${ITEM_TYPE:-Issue}")
else
  echo "reconcile: scanning watched states + tracked items"
  items=()
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && items+=("$entry")
  done < <(
    {
      if [[ ",$ENABLED_HANDLERS," == *",issues,"* ]]; then
        issues_in_state "$STATE_ANALYZE" | sed 's/$/|Issue/'
        issues_in_state "$STATE_IMPLEMENT" | sed 's/$/|Issue/'
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

  decision_json=$(bash "$SCRIPTS/resolve-item.sh" "$item_id" "${type_hint:-Issue}")
  echo "resolved: $decision_json"
  decision=$(jq -r '.decision' <<<"$decision_json")
  item_type=$(jq -r '.item_type // "Issue"' <<<"$decision_json")
  state_name=$(jq -r '.state_name // ""' <<<"$decision_json")
  latest_comment_at=$(jq -r '.latest_comment_at // "1970-01-01T00:00:00.000Z"' <<<"$decision_json")

  # Never start tracking items that produced no work.
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
    refreshed=$("$SCRIPTS/api.sh" \
      'query($id: String!) { issue(id: $id) { state { name } comments(first: 100) { nodes { createdAt } } } }' \
      "$(jq -cn --arg id "$item_id" '{id: $id}')" 2>/dev/null || echo '{}')
    latest_comment_at=$(jq -r '[.data.issue.comments.nodes[].createdAt] | max // "'"$latest_comment_at"'"' <<<"$refreshed")
    state_name=$(jq -r ".data.issue.state.name // \"$state_name\"" <<<"$refreshed")
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
    --arg item_id "$item_id" --arg item_type "$item_type" --arg state_name "$state_name" \
    --arg last_comment_at "$latest_comment_at" \
    '$prev + $default + $result + {item_id: $item_id, item_type: $item_type,
      state_name: $state_name, last_comment_at: $last_comment_at, updated_at: (now | todate)}' \
    > "$STATE_DIR/state/$item_id.json"
done

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "DRY_RUN: state not saved"
else
  bash "$SCRIPTS/state.sh" save "agent: ${EVENT_KIND:-manual} run"
fi

exit "$FAILED"
