#!/usr/bin/env bash
# Interactive installer for the Mattermost Notify Agent.
# Renders files/ (+ core adapters) into a target repository.
set -euo pipefail

RECIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$RECIPE_DIR/../../.." && pwd)"
FILES="$RECIPE_DIR/files"
source "$ROOT/core/lib/wizard.sh"
source "$ROOT/core/lib/render.sh"

need git jq curl

say "Mattermost Notify Agent — setup"
cat <<'EOF'
Installs an AI notifier into one of YOUR repositories:

  ship:     release published → AI-written plain-language announcement pushed to Mattermost
  incident: monitored workflow fails → calm what/impact/cause note to Mattermost
  ask:      (optional) trigger word in the channel → grounded answers from the repo

ship/incident need NO relay — an incoming webhook URL is enough. Only `ask`
needs the small Cloudflare relay for Mattermost's outgoing webhook.

You'll need: a GitHub repo, a Mattermost incoming webhook URL (Integrations
→ Incoming Webhooks — the URL is the credential), and Claude auth.
EOF

say "Target repository"
ask TARGET_IN "Path to the repository to notify about"
TARGET_IN="${TARGET_IN/#\~/$HOME}"
TARGET="$(cd "$TARGET_IN" 2>/dev/null && pwd)" || { echo "error: no such directory: $TARGET_IN" >&2; exit 1; }
[[ -d "$TARGET/.git" ]] || { echo "error: not a git repository: $TARGET" >&2; exit 1; }

AGENT_DIR="$TARGET/scripts/mattermost-agent"
CONFIG="$AGENT_DIR/automation.config.json"
cfg() { jq -r ".$1 // empty" "$CONFIG" 2>/dev/null || true; }
d() { local v; v="$(cfg "$1")"; printf '%s' "${v:-$2}"; }
[[ -f "$CONFIG" ]] && note "(existing install found — answers default to your previous choices)"

origin_url=$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)
guess_repo=$(printf '%s' "$origin_url" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
ask GITHUB_REPO "GitHub repo (owner/name)" "$(d github_repo "$guess_repo")"

say "Mattermost"
ask HANDLERS "Handlers to enable (ship,incident,ask)" "$(d handlers 'ship,incident')"
HANDLERS=$(printf '%s' "$HANDLERS" | tr -d ' ')
ask WF_NAMES "Workflow names to monitor for incidents (comma-separated)" "$(d wf_names 'CI')"
# Render as a YAML inline list: CI,Deploy → "CI", "Deploy"
INCIDENT_WORKFLOWS=$(printf '%s' "$WF_NAMES" | awk -F',' '{for(i=1;i<=NF;i++){gsub(/^ +| +$/,"",$i); printf "%s\"%s\"", (i>1?", ":""), $i}}')
ask TRIGGER "Trigger word for ask (only used if 'ask' is enabled)" "$(d trigger '@ai')"

say "Conventions"
ask AGENT_NAME "Agent display name" "$(d agent_name 'Notify Agent')"
ask PROJECT_NAME "Product name used in messages" "$(d project_name "$(basename "$TARGET")")"
ask AUDIENCE "Who reads the channel? (messages are written for them)" "$(d audience 'the team')"
ask STACK_NOTE "One-line stack note for the agent" "$(d stack_note 'follow the conventions in CLAUDE.md / README')"
ask CLAUDE_MODEL "Claude model" "$(d claude_model 'claude-sonnet-5')"

repo_slug=$(basename "$TARGET" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
WORKER_NAME="$(d worker_name "${repo_slug}-mattermost-relay")"

say "Summary"
cat <<EOF
  Target repo        $TARGET
  GitHub repo        $GITHUB_REPO
  Handlers           $HANDLERS
  Incident watch     $WF_NAMES
  Trigger word       $TRIGGER
  Agent              $AGENT_NAME · brain claude-code · model $CLAUDE_MODEL
EOF
confirm "Install into $TARGET?" || { echo "aborted — nothing written"; exit 1; }

say "Installing files"
RENDER_VARS="GITHUB_REPO HANDLERS INCIDENT_WORKFLOWS TRIGGER AGENT_NAME PROJECT_NAME AUDIENCE STACK_NOTE CLAUDE_MODEL WORKER_NAME"

(cd "$FILES" && find . -type f ! -name '.DS_Store' | sed 's#^\./##') | while IFS= read -r rel; do
  src="$FILES/$rel"
  case "$rel" in
    *.tmpl) dest="$TARGET/${rel%.tmpl}"; render "$src" "$dest" ;;
    *) dest="$TARGET/$rel"; mkdir -p "$(dirname "$dest")"; cp "$src" "$dest" ;;
  esac
  echo "  + ${dest#"$TARGET/"}"
done

mkdir -p "$AGENT_DIR/ai"
install -m 0644 "$ROOT/core/ai/claude-code.sh" "$AGENT_DIR/ai/brain.sh"
echo "  + scripts/mattermost-agent/ai/brain.sh  (core/ai/claude-code.sh)"
chmod +x "$AGENT_DIR"/*.sh

jq -n \
  --arg github_repo "$GITHUB_REPO" --arg handlers "$HANDLERS" \
  --arg wf_names "$WF_NAMES" --arg trigger "$TRIGGER" \
  --arg agent_name "$AGENT_NAME" \
  --arg project_name "$PROJECT_NAME" --arg audience "$AUDIENCE" \
  --arg stack_note "$STACK_NOTE" --arg claude_model "$CLAUDE_MODEL" \
  --arg worker_name "$WORKER_NAME" \
  '{recipe: "mattermost/notify-agent", runtime: "github-actions", brain: "claude-code",
    handlers: $handlers, github_repo: $github_repo, wf_names: $wf_names,
    trigger: $trigger, agent_name: $agent_name, project_name: $project_name,
    audience: $audience, stack_note: $stack_note, claude_model: $claude_model,
    worker_name: $worker_name}' > "$CONFIG"
echo "  + scripts/mattermost-agent/automation.config.json"

render_check "$AGENT_DIR" "$TARGET/.github/workflows/mattermost-agent.yml" || true

say "Next steps (in order)"
cat <<EOF
1. GitHub secrets on $GITHUB_REPO:
     gh secret set MATTERMOST_WEBHOOK_URL -R $GITHUB_REPO   # incoming webhook URL (Integrations → Incoming Webhooks — the URL is the credential)
     gh secret set CLAUDE_CODE_OAUTH_TOKEN -R $GITHUB_REPO  # or ANTHROPIC_API_KEY

2. Commit the new files in $TARGET and merge to the default branch.
   ship/incident are now LIVE — no relay needed.

3. ONLY if you enabled 'ask' — deploy the relay and create the outgoing webhook:
     cd $AGENT_DIR/relay
     wrangler deploy
     wrangler secret put GITHUB_PAT            # fine-grained PAT: only $GITHUB_REPO, contents: read+write
   In Mattermost: Integrations → Outgoing Webhooks → Add
     Channel: the SAME channel the incoming webhook posts to (answers arrive there)
     Trigger word: $TRIGGER
     Callback URL: https://$WORKER_NAME.<your-cf-subdomain>.workers.dev/hook
     Content type: either — the relay parses both
   Mattermost shows the webhook token — store it:
     wrangler secret put MATTERMOST_OUTGOING_TOKEN
   Notes: outgoing webhooks fire only in PUBLIC channels. Optionally enable
   "Enable integrations to override usernames" in the System Console so
   posts show as $AGENT_NAME (harmless if off — the field is ignored).

4. Test without sending anything:
     cd $TARGET && DRY_RUN=1 MODE=ship RELEASE_TAG=v0.0.0 bash scripts/mattermost-agent/agent-run.sh
   Real test: Actions → Mattermost Notify Agent → Run workflow → mode: ship.

Operating docs: scripts/mattermost-agent/README.md
EOF
