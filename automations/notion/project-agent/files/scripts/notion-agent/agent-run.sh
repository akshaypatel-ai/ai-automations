#!/usr/bin/env bash
# Entrypoint driver: restore state → resolve item(s) → run playbook(s) → save state.
# Env: ITEM_ID (page id; empty = reconcile), ITEM_TYPE, EVENT_KIND,
#      DRY_RUN=1 (resolve only, no AI, no push).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
SCRIPTS="scripts/notion-agent"
source "$SCRIPTS/env.sh"
mkdir -p "$OUT_DIR"

# The filter key depends on the property type (status vs select) — read it once.
STATUS_PROP_TYPE=""
status_prop_type() {
  if [[ -z "$STATUS_PROP_TYPE" ]]; then
    STATUS_PROP_TYPE=$(bash "$SCRIPTS/api.sh" GET "/databases/$NOTION_DATABASE_ID" 2>/dev/null \
      | jq -r --arg p "$STATUS_PROP" '.properties[$p].type // "status"')
  fi
  printf '%s' "$STATUS_PROP_TYPE"
}

pages_in_status() { # pages_in_status <status option name> → page ids
  local ptype filter
  ptype=$(status_prop_type)
  filter=$(jq -cn --arg p "$STATUS_PROP" --arg t "$ptype" --arg v "$1" \
    '{filter: {property: $p}} | .filter[$t] = {equals: $v} | . + {page_size: 100}')
  bash "$SCRIPTS/api.sh" POST "/databases/$NOTION_DATABASE_ID/query" "$filter" \
    | jq -r '.results[].id'
}

bash "$SCRIPTS/state.sh" restore

if [[ -n "${ITEM_ID:-}" ]]; then
  items=("$ITEM_ID|${ITEM_TYPE:-Page}")
else
  echo "reconcile: scanning watched statuses + tracked items"
  items=()
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && items+=("$entry")
  done < <(
    {
      if [[ ",$ENABLED_HANDLERS," == *",pages,"* && -n "$NOTION_DATABASE_ID" ]]; then
        pages_in_status "$STATUS_ANALYZE" | sed 's/$/|Page/'
        pages_in_status "$STATUS_IMPLEMENT" | sed 's/$/|Page/'
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

  decision_json=$(bash "$SCRIPTS/resolve-item.sh" "$item_id" "${type_hint:-Page}")
  echo "resolved: $decision_json"
  decision=$(jq -r '.decision' <<<"$decision_json")
  status_name=$(jq -r '.status_name // ""' <<<"$decision_json")
  latest_comment_at=$(jq -r '.latest_comment_at // ""' <<<"$decision_json")

  # Never start tracking items that produced no work.
  if [[ "$decision" == "skip" && ! -f "$STATE_DIR/state/$item_id.json" ]]; then
    continue
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    [[ "$decision" != "skip" ]] && echo "DRY_RUN: would run playbook '$decision' for page $item_id"
  elif [[ "$decision" != "skip" ]]; then
    if ! bash "$SCRIPTS/run-playbook.sh" "$decision" "$item_id" "$decision_json"; then
      echo "playbook '$decision' failed for page $item_id" >&2
      FAILED=1
      # Leave previous state untouched so the next doorbell retries this decision.
      continue
    fi
    # Re-read so the agent's own new comment is consumed and never reprocessed.
    latest_comment_at=$(bash "$SCRIPTS/api.sh" GET "/comments?block_id=$item_id&page_size=100" 2>/dev/null \
      | jq -r --arg prev "$latest_comment_at" '[.results[].created_time] | max // $prev')
    status_name=$(bash "$SCRIPTS/api.sh" GET "/pages/$item_id" 2>/dev/null \
      | jq -r --arg p "$STATUS_PROP" --arg prev "$status_name" \
        '(.properties[$p] | (.status.name // .select.name // $prev)) | ascii_downcase')
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
    '$prev + $default + $result + {item_id: $item_id, item_type: "Page",
      status_name: $status_name, last_comment_at: $last_comment_at, updated_at: (now | todate)}' \
    > "$STATE_DIR/state/$item_id.json"
done

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "DRY_RUN: state not saved"
else
  bash "$SCRIPTS/state.sh" save "agent: ${EVENT_KIND:-manual} run"
fi

exit "$FAILED"
