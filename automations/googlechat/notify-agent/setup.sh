#!/usr/bin/env bash
# Interactive installer for the Google Chat Notify Agent.
# Renders files/ (+ core adapters) into a target repository.
set -euo pipefail

RECIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$RECIPE_DIR/../../.." && pwd)"
FILES="$RECIPE_DIR/files"
source "$ROOT/core/lib/wizard.sh"
source "$ROOT/core/lib/render.sh"
source "$ROOT/core/lib/brains.sh"

need git jq curl

say "Google Chat Notify Agent — setup"
cat <<'EOF'
Installs an AI notifier into one of YOUR repositories:

  ship:     release published → AI-written plain-language announcement pushed to Google Chat
  incident: monitored workflow fails → calm what/impact/cause note to Google Chat

Fully relay-free: both handlers are GitHub-native triggers and the write
path is a space webhook URL — nothing to deploy beyond two repo secrets.
(Inbound Q&A would need a Google Chat app on a GCP project — out of scope.)

You'll need: a GitHub repo, a Google Chat space webhook (space → ⚙ →
Apps & integrations → Webhooks → Add → copy URL), and Claude auth.
EOF

say "Target repository"
ask TARGET_IN "Path to the repository to notify about"
TARGET_IN="${TARGET_IN/#\~/$HOME}"
TARGET="$(cd "$TARGET_IN" 2>/dev/null && pwd)" || { echo "error: no such directory: $TARGET_IN" >&2; exit 1; }
[[ -d "$TARGET/.git" ]] || { echo "error: not a git repository: $TARGET" >&2; exit 1; }

AGENT_DIR="$TARGET/scripts/googlechat-agent"
CONFIG="$AGENT_DIR/automation.config.json"
cfg() { jq -r ".$1 // empty" "$CONFIG" 2>/dev/null || true; }
d() { local v; v="$(cfg "$1")"; printf '%s' "${v:-$2}"; }
[[ -f "$CONFIG" ]] && note "(existing install found — answers default to your previous choices)"

origin_url=$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)
guess_repo=$(printf '%s' "$origin_url" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
ask GITHUB_REPO "GitHub repo (owner/name)" "$(d github_repo "$guess_repo")"

say "Google Chat"
note "Only ship and incident exist — inbound Q&A would need a Google Chat app on GCP."
ask HANDLERS "Handlers to enable (ship,incident)" "$(d handlers 'ship,incident')"
HANDLERS=$(printf '%s' "$HANDLERS" | tr -d ' ')
ask WF_NAMES "Workflow names to monitor for incidents (comma-separated)" "$(d wf_names 'CI')"
# Render as a YAML inline list: CI,Deploy → "CI", "Deploy"
INCIDENT_WORKFLOWS=$(printf '%s' "$WF_NAMES" | awk -F',' '{for(i=1;i<=NF;i++){gsub(/^ +| +$/,"",$i); printf "%s\"%s\"", (i>1?", ":""), $i}}')

say "Conventions"
ask AGENT_NAME "Agent display name" "$(d agent_name 'Notify Agent')"
ask PROJECT_NAME "Product name used in messages" "$(d project_name "$(basename "$TARGET")")"
ask AUDIENCE "Who reads the space? (messages are written for them)" "$(d audience 'the team')"
ask STACK_NOTE "One-line stack note for the agent" "$(d stack_note 'follow the conventions in CLAUDE.md / README')"
choose_brain "$ROOT/core/ai" "$(d brain 'claude-code')" mediated
ask AI_MODEL "Model for $BRAIN_NAME" "$(d ai_model "$AI_MODEL_DEFAULT")"

say "Summary"
cat <<EOF
  Target repo        $TARGET
  GitHub repo        $GITHUB_REPO
  Handlers           $HANDLERS
  Incident watch     $WF_NAMES
  Agent              $AGENT_NAME · brain $BRAIN_NAME · model $AI_MODEL
EOF
confirm "Install into $TARGET?" || { echo "aborted — nothing written"; exit 1; }

say "Installing files"
RENDER_VARS="GITHUB_REPO HANDLERS INCIDENT_WORKFLOWS AGENT_NAME PROJECT_NAME AUDIENCE STACK_NOTE BRAIN_NAME AI_MODEL"

(cd "$FILES" && find . -type f ! -name '.DS_Store' | sed 's#^\./##') | while IFS= read -r rel; do
  src="$FILES/$rel"
  case "$rel" in
    *.tmpl) dest="$TARGET/${rel%.tmpl}"; render "$src" "$dest" ;;
    *) dest="$TARGET/$rel"; mkdir -p "$(dirname "$dest")"; cp "$src" "$dest" ;;
  esac
  echo "  + ${dest#"$TARGET/"}"
done

mkdir -p "$AGENT_DIR/ai"
install -m 0644 "$BRAIN_FILE" "$AGENT_DIR/ai/brain.sh"
echo "  + scripts/googlechat-agent/ai/brain.sh  ($BRAIN_NAME)"
chmod +x "$AGENT_DIR"/*.sh

jq -n \
  --arg github_repo "$GITHUB_REPO" --arg handlers "$HANDLERS" \
  --arg wf_names "$WF_NAMES" --arg agent_name "$AGENT_NAME" \
  --arg project_name "$PROJECT_NAME" --arg audience "$AUDIENCE" \
  --arg stack_note "$STACK_NOTE" --arg brain "$BRAIN_NAME" --arg ai_model "$AI_MODEL" \
  '{recipe: "googlechat/notify-agent", runtime: "github-actions", brain: $brain,
    handlers: $handlers, github_repo: $github_repo, wf_names: $wf_names,
    agent_name: $agent_name, project_name: $project_name, audience: $audience,
    stack_note: $stack_note, ai_model: $ai_model}' > "$CONFIG"
echo "  + scripts/googlechat-agent/automation.config.json"

render_check "$AGENT_DIR" "$TARGET/.github/workflows/googlechat-agent.yml" || true

say "Next steps (in order)"
cat <<EOF
1. GitHub secrets on $GITHUB_REPO:
     gh secret set GCHAT_WEBHOOK_URL -R $GITHUB_REPO        # space → ⚙ → Apps & integrations → Webhooks → Add → copy URL
     gh secret set ${BRAIN_AUTH_VARS%% *} -R $GITHUB_REPO  # brain auth ($BRAIN_NAME) — any one of: $BRAIN_AUTH_VARS
   The webhook URL embeds its own key+token — it IS the credential.
   Keep it in secrets only; never write it into a file.

2. Commit the new files in $TARGET and merge to the default branch.
   Both handlers are now LIVE — fully relay-free, nothing else to deploy.

3. Test without sending anything:
     cd $TARGET && DRY_RUN=1 MODE=ship RELEASE_TAG=v0.0.0 bash scripts/googlechat-agent/agent-run.sh
   Real test: Actions → Google Chat Notify Agent → Run workflow → mode: ship.

Operating docs: scripts/googlechat-agent/README.md
EOF
