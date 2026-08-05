#!/usr/bin/env bash
# Decide which playbook (if any) applies to a Confluence page by diffing the
# API against saved state. Fully implemented: pages.
# Usage: resolve-item.sh <page_id> [item_type]   → prints a one-line decision JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ITEM_ID="$1"
TYPE_HINT="${2:-Page}"
STATE_FILE="$STATE_DIR/state/$ITEM_ID.json"

skip() { # skip <reason>
  jq -cn --arg id "$ITEM_ID" --arg t "$TYPE_HINT" --arg r "$1" \
    '{item_id: $id, item_type: $t, decision: "skip", reason: $r}'
  exit 0
}

[[ "$TYPE_HINT" == "Page" ]] || skip "handler not implemented yet"
[[ ",$ENABLED_HANDLERS," == *",pages,"* ]] || skip "handler 'pages' disabled"

state='{}'
tracked=0
[[ -f "$STATE_FILE" ]] && { state=$(cat "$STATE_FILE"); tracked=1; }
last_comment_at=$(jq -r '.last_comment_at // ""' <<<"$state")
phase=$(jq -r '.phase // "new"' <<<"$state")

page_json=$("$SCRIPT_DIR/api.sh" GET "/api/v2/pages/$ITEM_ID?body-format=storage" 2>/dev/null) \
  || skip "page not fetchable"

status=$(jq -r '.status // ""' <<<"$page_json")
[[ "$status" == "current" ]] || skip "page status '$status'"
title=$(jq -r '.title // ""' <<<"$page_json")

labels_json=$("$SCRIPT_DIR/api.sh" GET "/api/v2/pages/$ITEM_ID/labels" 2>/dev/null \
  || echo '{"results":[]}')
labels=$(jq -r '[.results[]?.name // empty] | join(",")' <<<"$labels_json")
has_review=$(jq --arg l "$REVIEW_LABEL" \
  '[.results[]? | select(((.name // "") | ascii_downcase) == ($l | ascii_downcase))] | length' \
  <<<"$labels_json")

# Comment recency is the footer comment's version.createdAt — ISO-8601, so a
# plain string comparison orders correctly. Bodies are storage-format XHTML;
# tags are stripped before the marker check, so the agent's own comments
# never count as human activity.
comments=$("$SCRIPT_DIR/api.sh" GET "/api/v2/pages/$ITEM_ID/footer-comments?body-format=storage&limit=100" 2>/dev/null \
  || echo '{"results":[]}')
latest_comment_at=$(jq -r '[.results[]?.version.createdAt // empty] | max // ""' <<<"$comments")
new_human_count=$(jq --arg last "$last_comment_at" --arg marker "$AGENT_MARKER" \
  '[.results[]?
       | select((.version.createdAt // "") > $last)
       | select((((.body.storage.value // "") | gsub("<[^>]*>"; "") | .[0:120]) | contains($marker)) | not)
   ] | length' <<<"$comments")

decision="skip"
reason="nothing new"
if [[ "$tracked" == 0 ]]; then
  if [[ "$has_review" -gt 0 ]]; then
    decision="review"; reason="page labeled for review"
  else
    reason="no review label"
  fi
elif [[ "$new_human_count" -gt 0 ]]; then
  decision="respond"; reason="new human comment on a tracked page"
fi

jq -cn \
  --arg item_id "$ITEM_ID" \
  --arg decision "$decision" \
  --arg reason "$reason" \
  --arg title "$title" \
  --arg labels "$labels" \
  --arg prev_phase "$phase" \
  --arg latest_comment_at "$latest_comment_at" \
  --argjson new_human_count "$new_human_count" \
  '{item_id: $item_id, item_type: "Page", decision: $decision, reason: $reason,
    title: $title, labels: $labels, prev_phase: $prev_phase,
    latest_comment_at: $latest_comment_at, new_human_count: $new_human_count}'
