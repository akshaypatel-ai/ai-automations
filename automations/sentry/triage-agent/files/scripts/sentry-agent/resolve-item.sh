#!/usr/bin/env bash
# Decide which playbook (if any) applies to a Sentry issue by diffing the API
# against saved state. Fully implemented: issues.
# Usage: resolve-item.sh <sentry_issue_id> [item_type]   → prints a one-line decision JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ITEM_ID="$1"
TYPE_HINT="${2:-Issue}"
STATE_FILE="$STATE_DIR/state/$ITEM_ID.json"

skip() { # skip <reason>
  jq -cn --arg id "$ITEM_ID" --arg t "$TYPE_HINT" --arg r "$1" \
    '{item_id: $id, item_type: $t, decision: "skip", reason: $r}'
  exit 0
}

[[ "$TYPE_HINT" == "Issue" ]] || skip "handler not implemented yet"
[[ ",$ENABLED_HANDLERS," == *",issues,"* ]] || skip "handler 'issues' disabled"

state='{}'
tracked=0
[[ -f "$STATE_FILE" ]] && { state=$(cat "$STATE_FILE"); tracked=1; }
gh_issue_url=$(jq -r '.gh_issue_url // ""' <<<"$state")
last_event_count=$(jq -r '.last_event_count // 0' <<<"$state")
phase=$(jq -r '.phase // "new"' <<<"$state")

issue_json=$("$SCRIPT_DIR/api.sh" GET "/issues/$ITEM_ID/" 2>/dev/null) || skip "issue not fetchable"

# Resolved/ignored issues are human-settled — never triage over their heads.
status=$(jq -r '.status // ""' <<<"$issue_json")
case "$status" in
  resolved|ignored) skip "issue $status" ;;
esac

title=$(jq -r '.title // ""' <<<"$issue_json")
level=$(jq -r '.level // ""' <<<"$issue_json")
short_id=$(jq -r '.shortId // ""' <<<"$issue_json")
permalink=$(jq -r '.permalink // ""' <<<"$issue_json")
# Sentry serves count as a string — normalize to a number for comparisons.
count=$(jq -r '(.count // "0") | tonumber' <<<"$issue_json")
user_count=$(jq -r '.userCount // 0' <<<"$issue_json")

decision="skip"
reason="nothing new"
if [[ "$tracked" == 0 ]]; then
  decision="analyze"; reason="new sentry issue"
elif [[ -n "$gh_issue_url" && "$count" -gt "$last_event_count" ]]; then
  decision="update"; reason="issue recurring since filed"
fi

jq -cn \
  --arg item_id "$ITEM_ID" \
  --arg decision "$decision" \
  --arg reason "$reason" \
  --arg title "$title" \
  --arg level "$level" \
  --arg short_id "$short_id" \
  --arg permalink "$permalink" \
  --arg prev_phase "$phase" \
  --argjson count "$count" \
  --argjson user_count "$user_count" \
  '{item_id: $item_id, item_type: "Issue", decision: $decision, reason: $reason,
    title: $title, level: $level, count: $count, user_count: $user_count,
    short_id: $short_id, permalink: $permalink, prev_phase: $prev_phase}'
