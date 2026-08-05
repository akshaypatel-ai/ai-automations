#!/usr/bin/env bash
# Entrypoint driver: restore state → resolve item(s) → run playbook(s) → save state.
# Env: ITEM_ID (task gid; empty = reconcile), ITEM_TYPE, EVENT_KIND,
#      DRY_RUN=1 (resolve only, no AI, no push).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
SCRIPTS="scripts/asana-agent"
source "$SCRIPTS/env.sh"
mkdir -p "$OUT_DIR"

tasks_in_section() { # tasks_in_section <section name (lowercase)> → task gids
  local gid
  gid=$(bash "$SCRIPTS/api.sh" GET "/projects/$ASANA_PROJECT_GID/sections?opt_fields=name" \
    | jq -r --arg s "$1" '.data[] | select((.name | ascii_downcase) == $s) | .gid' | head -1)
  [[ -n "$gid" ]] || return 0
  bash "$SCRIPTS/api.sh" GET "/sections/$gid/tasks?opt_fields=gid" | jq -r '.data[].gid'
}

bash "$SCRIPTS/state.sh" restore

if [[ -n "${ITEM_ID:-}" ]]; then
  items=("$ITEM_ID|${ITEM_TYPE:-Task}")
else
  echo "reconcile: scanning watched sections + tracked items"
  items=()
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && items+=("$entry")
  done < <(
    {
      if [[ ",$ENABLED_HANDLERS," == *",tasks,"* && -n "$ASANA_PROJECT_GID" ]]; then
        tasks_in_section "$(printf '%s' "$SECTION_ANALYZE" | tr '[:upper:]' '[:lower:]')" | sed 's/$/|Task/'
        tasks_in_section "$(printf '%s' "$SECTION_IMPLEMENT" | tr '[:upper:]' '[:lower:]')" | sed 's/$/|Task/'
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
  section_name=$(jq -r '.section_name // ""' <<<"$decision_json")
  latest_comment_at=$(jq -r '.latest_comment_at // ""' <<<"$decision_json")

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
    latest_comment_at=$(bash "$SCRIPTS/api.sh" GET \
      "/tasks/$item_id/stories?opt_fields=created_at,resource_subtype" 2>/dev/null \
      | jq -r --arg prev "$latest_comment_at" \
        '[.data[] | select(.resource_subtype == "comment_added") | .created_at] | max // $prev')
    section_name=$(bash "$SCRIPTS/api.sh" GET \
      "/tasks/$item_id?opt_fields=memberships.project.gid,memberships.section.name" 2>/dev/null \
      | jq -r --arg p "$ASANA_PROJECT_GID" --arg prev "$section_name" \
        '([.data.memberships[]? | select(.project.gid == $p) | .section.name][0] // $prev) | ascii_downcase')
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
    --arg item_id "$item_id" --arg section_name "$section_name" \
    --arg last_comment_at "$latest_comment_at" \
    '$prev + $default + $result + {item_id: $item_id, item_type: "Task",
      section_name: $section_name, last_comment_at: $last_comment_at, updated_at: (now | todate)}' \
    > "$STATE_DIR/state/$item_id.json"
done

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "DRY_RUN: state not saved"
else
  bash "$SCRIPTS/state.sh" save "agent: ${EVENT_KIND:-manual} run"
fi

exit "$FAILED"
