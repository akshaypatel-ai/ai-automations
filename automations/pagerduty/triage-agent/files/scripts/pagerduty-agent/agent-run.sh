#!/usr/bin/env bash
# Entrypoint driver: restore state → resolve item(s) → run playbook(s) → save state.
# Env: ITEM_ID (pagerduty incident id; empty = reconcile), ITEM_TYPE, EVENT_KIND,
#      DRY_RUN=1 (resolve only, no AI, no push).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
SCRIPTS="scripts/pagerduty-agent"
source "$SCRIPTS/env.sh"
mkdir -p "$OUT_DIR"

open_incidents() { # → the 25 most recently created triggered/acknowledged incident ids
  bash "$SCRIPTS/api.sh" GET "/incidents?statuses%5B%5D=triggered&statuses%5B%5D=acknowledged&limit=25&sort_by=created_at%3Adesc" \
    | jq -r '.incidents[].id'
}

bash "$SCRIPTS/state.sh" restore

if [[ -n "${ITEM_ID:-}" ]]; then
  items=("$ITEM_ID|${ITEM_TYPE:-Incident}")
else
  echo "reconcile: scanning open incidents + tracked items"
  items=()
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && items+=("$entry")
  done < <(
    {
      if [[ ",$ENABLED_HANDLERS," == *",incidents,"* ]]; then
        open_incidents | sed 's/$/|Incident/'
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

  decision_json=$(bash "$SCRIPTS/resolve-item.sh" "$item_id" "${type_hint:-Incident}")
  echo "resolved: $decision_json"
  decision=$(jq -r '.decision' <<<"$decision_json")

  # Never start tracking items that produced no work.
  if [[ "$decision" == "skip" && ! -f "$STATE_DIR/state/$item_id.json" ]]; then
    continue
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    [[ "$decision" != "skip" ]] && echo "DRY_RUN: would run playbook '$decision' for incident $item_id"
  elif [[ "$decision" != "skip" ]]; then
    if ! bash "$SCRIPTS/run-playbook.sh" "$decision" "$item_id" "$decision_json"; then
      echo "playbook '$decision' failed for incident $item_id" >&2
      FAILED=1
      # Leave previous state untouched so the next doorbell retries this decision.
      continue
    fi
  fi

  # Merge: previous state ← default phase for the playbook ← playbook result.
  result='{}'
  if [[ -f "$OUT_DIR/result-$item_id.json" ]] && jq -e . "$OUT_DIR/result-$item_id.json" >/dev/null 2>&1; then
    result=$(cat "$OUT_DIR/result-$item_id.json")
  fi
  prev='{}'
  [[ -f "$STATE_DIR/state/$item_id.json" ]] && prev=$(cat "$STATE_DIR/state/$item_id.json")
  case "$decision" in
    analyze) default_phase='{"phase":"noted"}' ;;
    *)       default_phase='{}' ;;
  esac
  [[ "${DRY_RUN:-0}" == "1" ]] && { result='{}'; default_phase='{}'; }

  jq -n \
    --argjson prev "$prev" --argjson default "$default_phase" --argjson result "$result" \
    --arg item_id "$item_id" \
    '$prev + $default + $result + {item_id: $item_id, item_type: "Incident",
      updated_at: (now | todate)}' \
    > "$STATE_DIR/state/$item_id.json"
done

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "DRY_RUN: state not saved"
else
  bash "$SCRIPTS/state.sh" save "agent: ${EVENT_KIND:-manual} run"
fi

exit "$FAILED"
