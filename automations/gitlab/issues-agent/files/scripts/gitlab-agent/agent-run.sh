#!/usr/bin/env bash
# Entrypoint driver: restore state → resolve item(s) → run playbook(s) → save state.
# Env: ITEM_ID (issue iid; empty = reconcile), ITEM_TYPE, EVENT_KIND,
#      DRY_RUN=1 (resolve only, no AI, no push).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
SCRIPTS="scripts/gitlab-agent"
source "$SCRIPTS/env.sh"
mkdir -p "$OUT_DIR"

issues_with_label() { # issues_with_label <label> → issue iids
  local encoded
  encoded=$(jq -rn --arg l "$1" '$l | @uri')
  bash "$SCRIPTS/api.sh" GET \
    "/projects/$GITLAB_PROJECT_ID/issues?labels=$encoded&state=opened&per_page=100" \
    | jq -r '.[].iid'
}

bash "$SCRIPTS/state.sh" restore

if [[ -n "${ITEM_ID:-}" ]]; then
  items=("$ITEM_ID|${ITEM_TYPE:-Issue}")
else
  echo "reconcile: scanning watched labels + tracked items"
  items=()
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && items+=("$entry")
  done < <(
    {
      if [[ ",$ENABLED_HANDLERS," == *",issues,"* ]]; then
        issues_with_label "$LABEL_ANALYZE" | sed 's/$/|Issue/'
        issues_with_label "$LABEL_IMPLEMENT" | sed 's/$/|Issue/'
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
  labels=$(jq -r '.labels // ""' <<<"$decision_json")
  latest_note_id=$(jq -r '.latest_note_id // 0' <<<"$decision_json")

  # Never start tracking items that produced no work.
  if [[ "$decision" == "skip" && ! -f "$STATE_DIR/state/$item_id.json" ]]; then
    continue
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    [[ "$decision" != "skip" ]] && echo "DRY_RUN: would run playbook '$decision' for issue #$item_id"
  elif [[ "$decision" != "skip" ]]; then
    if ! bash "$SCRIPTS/run-playbook.sh" "$decision" "$item_id" "$decision_json"; then
      echo "playbook '$decision' failed for issue #$item_id" >&2
      FAILED=1
      # Leave previous state untouched so the next doorbell retries this decision.
      continue
    fi
    # Re-read so the agent's own new comment is consumed and never reprocessed.
    latest_note_id=$(bash "$SCRIPTS/api.sh" GET \
      "/projects/$GITLAB_PROJECT_ID/issues/$item_id/notes?per_page=100&sort=asc" 2>/dev/null \
      | jq -r '[.[].id] | max // '"$latest_note_id")
    labels=$(bash "$SCRIPTS/api.sh" GET "/projects/$GITLAB_PROJECT_ID/issues/$item_id" 2>/dev/null \
      | jq -r '.labels // [] | join(",")' || printf '%s' "$labels")
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
    --arg item_id "$item_id" --arg labels "$labels" \
    --argjson last_note_id "$latest_note_id" \
    '$prev + $default + $result + {item_id: $item_id, item_type: "Issue",
      labels: $labels, last_note_id: $last_note_id, updated_at: (now | todate)}' \
    > "$STATE_DIR/state/$item_id.json"
done

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "DRY_RUN: state not saved"
else
  bash "$SCRIPTS/state.sh" save "agent: ${EVENT_KIND:-manual} run"
fi

exit "$FAILED"
