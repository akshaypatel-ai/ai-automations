#!/usr/bin/env bash
# Decide which playbook (if any) applies to a PagerDuty incident by diffing the
# API against saved state. Fully implemented: incidents.
# Usage: resolve-item.sh <incident_id> [item_type]   → prints a one-line decision JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

ITEM_ID="$1"
TYPE_HINT="${2:-Incident}"
STATE_FILE="$STATE_DIR/state/$ITEM_ID.json"

skip() { # skip <reason>
  jq -cn --arg id "$ITEM_ID" --arg t "$TYPE_HINT" --arg r "$1" \
    '{item_id: $id, item_type: $t, decision: "skip", reason: $r}'
  exit 0
}

[[ "$TYPE_HINT" == "Incident" ]] || skip "handler not implemented yet"
[[ ",$ENABLED_HANDLERS," == *",incidents,"* ]] || skip "handler 'incidents' disabled"

state='{}'
tracked=0
[[ -f "$STATE_FILE" ]] && { state=$(cat "$STATE_FILE"); tracked=1; }
phase=$(jq -r '.phase // "new"' <<<"$state")

incident_json=$("$SCRIPT_DIR/api.sh" GET "/incidents/$ITEM_ID" 2>/dev/null) || skip "incident not fetchable"

# Resolved incidents are settled — never note over a finished response.
status=$(jq -r '.incident.status // ""' <<<"$incident_json")
case "$status" in
  resolved) skip "incident resolved" ;;
esac

# One note per incident, ever: duplicate deliveries, retriggers, and reopens
# of an already-annotated incident all land on this skip.
if [[ "$tracked" == 1 && "$phase" == "noted" ]]; then
  skip "already noted"
fi

title=$(jq -r '.incident.title // ""' <<<"$incident_json")
urgency=$(jq -r '.incident.urgency // ""' <<<"$incident_json")
service=$(jq -r '.incident.service.summary // ""' <<<"$incident_json")
html_url=$(jq -r '.incident.html_url // ""' <<<"$incident_json")

decision="analyze"
reason="new incident"

jq -cn \
  --arg item_id "$ITEM_ID" \
  --arg decision "$decision" \
  --arg reason "$reason" \
  --arg title "$title" \
  --arg status "$status" \
  --arg urgency "$urgency" \
  --arg service "$service" \
  --arg html_url "$html_url" \
  --arg prev_phase "$phase" \
  '{item_id: $item_id, item_type: "Incident", decision: $decision, reason: $reason,
    title: $title, status: $status, urgency: $urgency, service: $service,
    html_url: $html_url, prev_phase: $prev_phase}'
