#!/usr/bin/env bash
# Decide which playbook (if any) applies to a GitHub issue by diffing the API
# against saved state. Fully implemented: issues (label-driven). Pull requests
# and other item types skip cleanly.
# Usage: resolve-item.sh <issue_number> [item_type]   → prints a one-line decision JSON.
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
[[ -f "$STATE_FILE" ]] && state=$(cat "$STATE_FILE")
prev_labels=$(jq -r '.labels // ""' <<<"$state")
last_comment_id=$(jq -r '.last_comment_id // 0' <<<"$state")
phase=$(jq -r '.phase // "new"' <<<"$state")

issue_json=$("$SCRIPT_DIR/api.sh" GET "/issues/$ITEM_ID" 2>/dev/null) || skip "issue not fetchable"

jq -e '.pull_request' <<<"$issue_json" >/dev/null 2>&1 && skip "item is a pull request"
[[ "$(jq -r '.state // ""' <<<"$issue_json")" == "open" ]] || skip "issue not open"

title=$(jq -r '.title // ""' <<<"$issue_json")
labels=$(jq -r '[.labels[].name] | join(",")' <<<"$issue_json")
has_analyze=0; has_implement=0; prev_had_analyze=0; prev_had_implement=0
[[ ",$labels," == *",$LABEL_ANALYZE,"* ]] && has_analyze=1
[[ ",$labels," == *",$LABEL_IMPLEMENT,"* ]] && has_implement=1
[[ ",$prev_labels," == *",$LABEL_ANALYZE,"* ]] && prev_had_analyze=1
[[ ",$prev_labels," == *",$LABEL_IMPLEMENT,"* ]] && prev_had_implement=1
[[ "$has_analyze" == 0 && "$has_implement" == 0 ]] && skip "no watched label"

# Comment recency is tracked by the numeric comment id (monotonic).
comments=$("$SCRIPT_DIR/api.sh" GET "/issues/$ITEM_ID/comments?per_page=100" 2>/dev/null || echo '[]')
latest_comment_id=$(jq -r '[.[].id] | max // 0' <<<"$comments")
new_human_count=$(jq --argjson last "$last_comment_id" --arg marker "$AGENT_MARKER" \
  '[.[] | select(.id > $last)
       | select(.user.type != "Bot")
       | select(((.body // "") | .[0:120] | contains($marker)) | not)
   ] | length' <<<"$comments")

decision="skip"
reason="nothing new"
if [[ "$has_implement" == 1 && "$prev_had_implement" == 0 ]]; then
  decision="implement"; reason="issue was labeled '$LABEL_IMPLEMENT'"
elif [[ "$has_analyze" == 1 && "$prev_had_analyze" == 0 && "$has_implement" == 0 ]]; then
  decision="analyze"; reason="issue was labeled '$LABEL_ANALYZE'"
elif [[ "$new_human_count" -gt 0 && "$has_implement" == 1 ]]; then
  decision="implement"; reason="new human comment on a '$LABEL_IMPLEMENT' issue"
elif [[ "$new_human_count" -gt 0 && "$has_analyze" == 1 ]]; then
  decision="respond"; reason="new human comment on a '$LABEL_ANALYZE' issue"
fi

jq -cn \
  --arg item_id "$ITEM_ID" \
  --arg decision "$decision" \
  --arg reason "$reason" \
  --arg title "$title" \
  --arg labels "$labels" \
  --arg prev_labels "$prev_labels" \
  --arg prev_phase "$phase" \
  --argjson latest_comment_id "$latest_comment_id" \
  --argjson new_human_count "$new_human_count" \
  '{item_id: $item_id, item_type: "Issue", decision: $decision, reason: $reason,
    title: $title, labels: $labels, prev_labels: $prev_labels,
    prev_phase: $prev_phase, latest_comment_id: $latest_comment_id,
    new_human_count: $new_human_count}'
