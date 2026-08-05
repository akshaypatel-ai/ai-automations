#!/usr/bin/env bash
# Decide which playbook (if any) applies to an Airtable record by diffing the
# API against saved state. Fully implemented: records — Airtable's detail-free
# pings can't name other families anyway; the reconcile scan does the routing.
# Usage: resolve-item.sh <record_id> [item_type]   → prints a one-line decision JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ITEM_ID="$1"
TYPE_HINT="${2:-Record}"
STATE_FILE="$STATE_DIR/state/$ITEM_ID.json"

skip() { # skip <reason>
  jq -cn --arg id "$ITEM_ID" --arg t "$TYPE_HINT" --arg r "$1" \
    '{item_id: $id, item_type: $t, decision: "skip", reason: $r}'
  exit 0
}

[[ "$TYPE_HINT" == "Record" ]] || skip "handler not implemented yet"
[[ ",$ENABLED_HANDLERS," == *",records,"* ]] || skip "handler 'records' disabled"

state='{}'
[[ -f "$STATE_FILE" ]] && state=$(cat "$STATE_FILE")
prev_status=$(jq -r '.status_name // ""' <<<"$state")
last_comment_at=$(jq -r '.last_comment_at // ""' <<<"$state")
phase=$(jq -r '.phase // "new"' <<<"$state")

# A deleted record 404s here, so this check also covers deletions.
record_json=$("$SCRIPT_DIR/api.sh" GET "/$AIRTABLE_BASE_ID/$AIRTABLE_TABLE_ID/$ITEM_ID" 2>/dev/null) \
  || skip "record not fetchable"

# The status field may be a single select (plain string) or a status-type
# field (object with .name) — normalize both; matching is case-insensitive.
status_name=$(jq -r --arg f "$STATUS_FIELD" \
  '(.fields[$f] | if type == "object" then .name else . end) // "" | ascii_downcase' <<<"$record_json")
title=$(jq -r --arg f "$TITLE_FIELD" --arg id "$ITEM_ID" '.fields[$f] // $id' <<<"$record_json")
want_analyze=$(printf '%s' "$STATUS_ANALYZE" | tr '[:upper:]' '[:lower:]')
want_implement=$(printf '%s' "$STATUS_IMPLEMENT" | tr '[:upper:]' '[:lower:]')

# Comment recency is tracked by createdTime (ISO-8601, string compare).
comments=$("$SCRIPT_DIR/api.sh" GET "/$AIRTABLE_BASE_ID/$AIRTABLE_TABLE_ID/$ITEM_ID/comments" 2>/dev/null \
  || echo '{"comments":[]}')
latest_comment_at=$(jq -r '[.comments[].createdTime] | max // ""' <<<"$comments")
new_human_count=$(jq --arg last "$last_comment_at" --arg marker "$AGENT_MARKER" \
  '[.comments[] | select(.createdTime > $last)
     | select(((.text // "") | .[0:120] | contains($marker)) | not)
   ] | length' <<<"$comments")

decision="skip"
reason="nothing new"
if [[ "$status_name" == "$want_analyze" && "$prev_status" != "$want_analyze" ]]; then
  decision="analyze"; reason="record entered the analyze status"
elif [[ "$status_name" == "$want_implement" && "$prev_status" != "$want_implement" ]]; then
  decision="implement"; reason="record entered the implement status"
elif [[ "$new_human_count" -gt 0 && "$status_name" == "$want_analyze" ]]; then
  decision="respond"; reason="new human comment in the analyze status"
elif [[ "$new_human_count" -gt 0 && "$status_name" == "$want_implement" ]]; then
  decision="implement"; reason="new human comment in the implement status"
fi

jq -cn \
  --arg item_id "$ITEM_ID" \
  --arg decision "$decision" \
  --arg reason "$reason" \
  --arg title "$title" \
  --arg status_name "$status_name" \
  --arg prev_status "$prev_status" \
  --arg prev_phase "$phase" \
  --arg latest_comment_at "$latest_comment_at" \
  --argjson new_human_count "$new_human_count" \
  '{item_id: $item_id, item_type: "Record", decision: $decision, reason: $reason,
    title: $title, status_name: $status_name, prev_status: $prev_status,
    prev_phase: $prev_phase, latest_comment_at: $latest_comment_at,
    new_human_count: $new_human_count}'
