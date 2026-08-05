#!/usr/bin/env bash
# Decide which playbook (if any) applies to an item by diffing Basecamp against saved state.
# Handles every webhook-able recording type, routed by handler family:
#   cards (Kanban::Card)  todos (Todo/Todolist)  messages (Message)
#   docs (Document/Upload/Vault)  checkins (Question/Question::Answer)  schedule (Schedule::Entry)
# Usage: resolve-item.sh <item_id> [item_type]   → prints a one-line decision JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ITEM_ID="$1"
TYPE_HINT="${2:-}"
STATE_FILE="$STATE_DIR/state/$ITEM_ID.json"

state='{}'
[[ -f "$STATE_FILE" ]] && state=$(cat "$STATE_FILE")
prev_column=$(jq -r '.column_id // 0' <<<"$state")
last_comment_id=$(jq -r '.last_comment_id // 0' <<<"$state")
phase=$(jq -r '.phase // "new"' <<<"$state")
prev_type=$(jq -r '.item_type // empty' <<<"$state")

skip() { # skip <item_type> <reason>
  jq -cn --argjson id "$ITEM_ID" --arg t "$1" --arg r "$2" \
    '{item_id: $id, item_type: $t, decision: "skip", reason: $r}'
  exit 0
}

item_type="${TYPE_HINT:-$prev_type}"

fetch_item() {
  case "$1" in
    Kanban::Card) basecamp cards show "$ITEM_ID" --in "$BC_PROJECT_ID" --agent 2>/dev/null ;;
    Todo)         basecamp todos show "$ITEM_ID" --in "$BC_PROJECT_ID" --json 2>/dev/null ;;
    Message)      basecamp messages show "$ITEM_ID" --in "$BC_PROJECT_ID" --json 2>/dev/null ;;
    *)            basecamp show "$ITEM_ID" --in "$BC_PROJECT_ID" --json 2>/dev/null ;;
  esac
}

item_json=$(fetch_item "$item_type") || skip "$item_type" "item not fetchable"
api_type=$(jq -r '.type // empty' <<<"$item_json")
[[ -n "$api_type" ]] && item_type="$api_type"

# Container types never carry actionable content themselves — their children
# (todos in a list, docs in a vault, answers to a question) arrive as their own events.
case "$item_type" in
  Todolist|Vault|Question) skip "$item_type" "container event" ;;
esac

handler=""
case "$item_type" in
  Kanban::Card)      handler="cards" ;;
  Todo)              handler="todos" ;;
  Message)           handler="messages" ;;
  Document|Upload)   handler="docs" ;;
  Question::Answer)  handler="checkins" ;;
  Schedule::Entry)   handler="schedule" ;;
  *)                 skip "$item_type" "no handler for type" ;;
esac
[[ ",$ENABLED_HANDLERS," == *",$handler,"* ]] || skip "$item_type" "handler '$handler' disabled"

item_status=$(jq -r '.status // "active"' <<<"$item_json")
[[ "$item_status" == "trashed" || "$item_status" == "archived" ]] && skip "$item_type" "item $item_status"
if [[ "$item_type" == "Todo" ]]; then
  [[ "$(jq -r '.completed // false' <<<"$item_json")" == "true" ]] && skip "$item_type" "todo completed"
  if [[ -n "$BC_TODOLIST_ID" ]]; then
    todo_list=$(jq -r '.parent.id // 0' <<<"$item_json")
    [[ "$todo_list" == "$BC_TODOLIST_ID" ]] || skip "$item_type" "outside watched todolist"
  fi
fi

column_id=$(jq -r '.parent.id // 0' <<<"$item_json")
title=$(jq -r '.title // .subject // ""' <<<"$item_json")

comments=$(basecamp comments list "$ITEM_ID" --in "$BC_PROJECT_ID" --all --agent 2>/dev/null || echo '[]')
latest_comment_id=$(jq -r '[(. // [])[].id] | max // 0' <<<"$comments")

# A comment is the agent's own when the marker appears near the start of the
# tag-stripped body; everything else counts as human input.
new_human_count=$(jq --argjson last "$last_comment_id" --arg marker "$AGENT_MARKER" \
  '[(. // [])[] | select(.id > $last)
       | select((((.content // "") | gsub("<[^>]*>"; "") | .[0:120] | contains($marker))) | not)
   ] | length' <<<"$comments")

decision="skip"
reason="nothing new"
if [[ "$handler" == "cards" ]]; then
  if [[ "$column_id" == "$BC_COL_ANALYZE" && "$prev_column" != "$BC_COL_ANALYZE" ]]; then
    decision="analyze"; reason="card entered the analyze column"
  elif [[ "$column_id" == "$BC_COL_IMPLEMENT" && "$prev_column" != "$BC_COL_IMPLEMENT" ]]; then
    decision="implement"; reason="card entered the implement column"
  elif [[ "$new_human_count" -gt 0 && "$column_id" == "$BC_COL_ANALYZE" ]]; then
    decision="respond"; reason="new human comment in the analyze column"
  elif [[ "$new_human_count" -gt 0 && "$column_id" == "$BC_COL_IMPLEMENT" ]]; then
    decision="implement"; reason="new human comment in the implement column"
  fi
else
  # Generic content types: a new (untracked) item or fresh human comments wake
  # the handler's playbook; the playbook itself decides whether it's addressed
  # to the agent (silence otherwise — that rule lives in every playbook).
  playbook=""
  case "$handler" in
    todos)    playbook="todo" ;;
    messages) playbook="message" ;;
    docs)     playbook="doc" ;;
    checkins) playbook="checkin" ;;
    schedule) playbook="schedule" ;;
  esac
  if [[ ! -f "$STATE_FILE" ]]; then
    decision="$playbook"; reason="new $item_type"
  elif [[ "$new_human_count" -gt 0 ]]; then
    decision="$playbook"; reason="new human comment"
  fi
fi

jq -cn \
  --argjson item_id "$ITEM_ID" \
  --arg item_type "$item_type" \
  --arg decision "$decision" \
  --arg reason "$reason" \
  --arg title "$title" \
  --arg prev_phase "$phase" \
  --argjson column_id "${column_id:-0}" \
  --argjson prev_column "$prev_column" \
  --argjson latest_comment_id "$latest_comment_id" \
  --argjson new_human_count "$new_human_count" \
  '{item_id: $item_id, item_type: $item_type, decision: $decision, reason: $reason,
    title: $title, column_id: $column_id, prev_column: $prev_column, prev_phase: $prev_phase,
    latest_comment_id: $latest_comment_id, new_human_count: $new_human_count}'
