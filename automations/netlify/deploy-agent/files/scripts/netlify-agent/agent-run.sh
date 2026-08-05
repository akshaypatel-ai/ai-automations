#!/usr/bin/env bash
# Entrypoint driver: restore state → resolve item(s) → gather error context →
# run playbook(s) → save state.
# Env: ITEM_ID (netlify deploy id; empty = reconcile), ITEM_TYPE, EVENT_KIND,
#      DRY_RUN=1 (resolve + gather only, no AI, no push).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
SCRIPTS="scripts/netlify-agent"
source "$SCRIPTS/env.sh"
mkdir -p "$OUT_DIR"

failed_deploys() { # → the 10 most recent failed deploy ids for the site
  bash "$SCRIPTS/api.sh" GET "/sites/$NETLIFY_SITE_ID/deploys?state=error&per_page=10" \
    | jq -r '.[].id'
}

gather_context() { # <deploy_id> — the deploy's error_message, for the prompt (best effort)
  # Netlify's build-log API is not public/stable, so the deploy object's
  # error_message (often the failing step + last lines) is the log excerpt.
  local id="$1"
  local out="$OUT_DIR/context-$id.txt"
  bash "$SCRIPTS/api.sh" GET "/deploys/$id" 2>/dev/null \
    | jq -r '.error_message // empty' 2>/dev/null > "$out" || true
  [[ -s "$out" ]] || echo "(no error message on the deploy object)" > "$out"
}

bash "$SCRIPTS/state.sh" restore

if [[ -n "${ITEM_ID:-}" ]]; then
  items=("$ITEM_ID|${ITEM_TYPE:-Deploy}")
else
  echo "reconcile: scanning failed deploys + tracked items"
  items=()
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && items+=("$entry")
  done < <(
    {
      if [[ ",$ENABLED_HANDLERS," == *",deploys,"* ]]; then
        failed_deploys | sed 's/$/|Deploy/'
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

  decision_json=$(bash "$SCRIPTS/resolve-item.sh" "$item_id" "${type_hint:-Deploy}")
  echo "resolved: $decision_json"
  decision=$(jq -r '.decision' <<<"$decision_json")
  commit_sha=$(jq -r '.commit_sha // ""' <<<"$decision_json")

  # Never start tracking items that produced no work.
  if [[ "$decision" == "skip" && ! -f "$STATE_DIR/state/$item_id.json" ]]; then
    continue
  fi

  # The playbook's ground truth is the deploy's error message + this repo —
  # fetch the message up front so run-playbook.sh can inline it into the prompt.
  [[ "$decision" != "skip" ]] && gather_context "$item_id"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    [[ "$decision" != "skip" ]] && echo "DRY_RUN: would run playbook '$decision' for deploy $item_id"
  elif [[ "$decision" != "skip" ]]; then
    if ! bash "$SCRIPTS/run-playbook.sh" "$decision" "$item_id" "$decision_json"; then
      echo "playbook '$decision' failed for deploy $item_id" >&2
      FAILED=1
      # Leave previous state untouched so the next doorbell retries this decision.
      continue
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
    analyze) default_phase='{"phase":"filed"}' ;;
    *)       default_phase='{}' ;;
  esac
  [[ "${DRY_RUN:-0}" == "1" ]] && { result='{}'; default_phase='{}'; }

  jq -n \
    --argjson prev "$prev" --argjson default "$default_phase" --argjson result "$result" \
    --arg item_id "$item_id" --arg commit_sha "$commit_sha" \
    '$prev + $default + $result
     + {item_id: $item_id, item_type: "Deploy", updated_at: (now | todate)}
     + (if $commit_sha != "" then {commit_sha: $commit_sha} else {} end)' \
    > "$STATE_DIR/state/$item_id.json"
done

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "DRY_RUN: state not saved"
else
  bash "$SCRIPTS/state.sh" save "agent: ${EVENT_KIND:-manual} run"
fi

exit "$FAILED"
