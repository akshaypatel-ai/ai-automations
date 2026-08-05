#!/usr/bin/env bash
# Entrypoint driver: restore state → resolve item(s) → run playbook(s) → save state.
# Env: ITEM_ID (record id; empty = reconcile), ITEM_TYPE, EVENT_KIND,
#      DRY_RUN=1 (resolve only, no AI, no push).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
SCRIPTS="scripts/airtable-agent"
source "$SCRIPTS/env.sh"
mkdir -p "$OUT_DIR"

# Airtable webhooks expire after 7 days unless refreshed — every agent run
# extends the clock, so an active board keeps its own webhook alive. (A repo
# with 7+ quiet days still needs a manual poke — see the ops README.)
if [[ -n "${AIRTABLE_WEBHOOK_ID:-}" ]]; then
  bash "$SCRIPTS/api.sh" POST "/bases/$AIRTABLE_BASE_ID/webhooks/$AIRTABLE_WEBHOOK_ID/refresh" >/dev/null 2>&1 || true
fi

records_in_status() { # records_in_status <status option name> → record ids
  # Server-side filter: {Status}='Todo'. The field name sits inside literal
  # braces (spaces in the name are fine there); Airtable's = compares strings
  # case-insensitively, matching the resolver. An option name containing a
  # single quote is a known formula-escaping edge (see the beta checklist).
  local formula field_q
  formula=$(jq -rn --arg s "{$STATUS_FIELD}='$1'" '$s|@uri')
  field_q=$(jq -rn --arg s "$STATUS_FIELD" '$s|@uri')
  bash "$SCRIPTS/api.sh" GET \
    "/$AIRTABLE_BASE_ID/$AIRTABLE_TABLE_ID?filterByFormula=$formula&maxRecords=100&fields%5B%5D=$field_q" \
    | jq -r '.records[].id'
}

bash "$SCRIPTS/state.sh" restore

if [[ -n "${ITEM_ID:-}" ]]; then
  items=("$ITEM_ID|${ITEM_TYPE:-Record}")
else
  echo "reconcile: scanning watched status options + tracked items"
  items=()
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && items+=("$entry")
  done < <(
    {
      if [[ ",$ENABLED_HANDLERS," == *",records,"* && -n "$AIRTABLE_TABLE_ID" ]]; then
        records_in_status "$STATUS_ANALYZE" | sed 's/$/|Record/'
        records_in_status "$STATUS_IMPLEMENT" | sed 's/$/|Record/'
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

  decision_json=$(bash "$SCRIPTS/resolve-item.sh" "$item_id" "${type_hint:-Record}")
  echo "resolved: $decision_json"
  decision=$(jq -r '.decision' <<<"$decision_json")
  status_name=$(jq -r '.status_name // ""' <<<"$decision_json")
  latest_comment_at=$(jq -r '.latest_comment_at // ""' <<<"$decision_json")

  # Never start tracking items that produced no work.
  if [[ "$decision" == "skip" && ! -f "$STATE_DIR/state/$item_id.json" ]]; then
    continue
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    [[ "$decision" != "skip" ]] && echo "DRY_RUN: would run playbook '$decision' for record $item_id"
  elif [[ "$decision" != "skip" ]]; then
    if ! bash "$SCRIPTS/run-playbook.sh" "$decision" "$item_id" "$decision_json"; then
      echo "playbook '$decision' failed for record $item_id" >&2
      FAILED=1
      # Leave previous state untouched so the next doorbell retries this decision.
      continue
    fi
    # Re-read so the agent's own new comment is consumed and never reprocessed.
    latest_comment_at=$(bash "$SCRIPTS/api.sh" GET "/$AIRTABLE_BASE_ID/$AIRTABLE_TABLE_ID/$item_id/comments" 2>/dev/null \
      | jq -r --arg prev "$latest_comment_at" '[.comments[].createdTime] | max // $prev')
    status_name=$(bash "$SCRIPTS/api.sh" GET "/$AIRTABLE_BASE_ID/$AIRTABLE_TABLE_ID/$item_id" 2>/dev/null \
      | jq -r --arg f "$STATUS_FIELD" --arg prev "$status_name" \
        '((.fields[$f] | if type == "object" then .name else . end) // $prev) | ascii_downcase')
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
    '$prev + $default + $result + {item_id: $item_id, item_type: "Record",
      status_name: $status_name, last_comment_at: $last_comment_at, updated_at: (now | todate)}' \
    > "$STATE_DIR/state/$item_id.json"
done

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "DRY_RUN: state not saved"
else
  bash "$SCRIPTS/state.sh" save "agent: ${EVENT_KIND:-manual} run"
fi

exit "$FAILED"
