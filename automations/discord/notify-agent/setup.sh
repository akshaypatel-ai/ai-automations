#!/usr/bin/env bash
# Interactive installer for the Discord Notify Agent.
# Renders files/ (+ core adapters) into a target repository.
set -euo pipefail

RECIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$RECIPE_DIR/../../.." && pwd)"
FILES="$RECIPE_DIR/files"
source "$ROOT/core/lib/wizard.sh"
source "$ROOT/core/lib/render.sh"

need git jq curl

say "Discord Notify Agent — setup"
cat <<'EOF'
Installs an AI notifier into one of YOUR repositories:

  ship:     release published → AI-written plain-language announcement pushed to Discord
  incident: monitored workflow fails → calm what/impact/cause note to Discord
  ask:      (optional) /ask slash command → grounded answers from the repo

ship/incident need NO relay — a channel webhook URL is enough. Only `ask`
needs the small Cloudflare relay for Discord's signed interactions endpoint.

You'll need: a GitHub repo, a Discord channel webhook (channel → Edit →
Integrations → Webhooks → New Webhook → Copy URL), and Claude auth. For
`ask` additionally a Discord application (discord.com/developers).
EOF

say "Target repository"
ask TARGET_IN "Path to the repository to notify about"
TARGET_IN="${TARGET_IN/#\~/$HOME}"
TARGET="$(cd "$TARGET_IN" 2>/dev/null && pwd)" || { echo "error: no such directory: $TARGET_IN" >&2; exit 1; }
[[ -d "$TARGET/.git" ]] || { echo "error: not a git repository: $TARGET" >&2; exit 1; }

AGENT_DIR="$TARGET/scripts/discord-agent"
CONFIG="$AGENT_DIR/automation.config.json"
cfg() { jq -r ".$1 // empty" "$CONFIG" 2>/dev/null || true; }
d() { local v; v="$(cfg "$1")"; printf '%s' "${v:-$2}"; }
[[ -f "$CONFIG" ]] && note "(existing install found — answers default to your previous choices)"

origin_url=$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)
guess_repo=$(printf '%s' "$origin_url" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
ask GITHUB_REPO "GitHub repo (owner/name)" "$(d github_repo "$guess_repo")"

say "Discord"
ask HANDLERS "Handlers to enable (ship,incident,ask)" "$(d handlers 'ship,incident')"
HANDLERS=$(printf '%s' "$HANDLERS" | tr -d ' ')
ask WF_NAMES "Workflow names to monitor for incidents (comma-separated)" "$(d wf_names 'CI')"
# Render as a YAML inline list: CI,Deploy → "CI", "Deploy"
INCIDENT_WORKFLOWS=$(printf '%s' "$WF_NAMES" | awk -F',' '{for(i=1;i<=NF;i++){gsub(/^ +| +$/,"",$i); printf "%s\"%s\"", (i>1?", ":""), $i}}')

say "Conventions"
ask AGENT_NAME "Agent display name (shown as the webhook username)" "$(d agent_name 'Notify Agent')"
ask PROJECT_NAME "Product name used in messages" "$(d project_name "$(basename "$TARGET")")"
ask AUDIENCE "Who reads the channel? (messages are written for them)" "$(d audience 'the team')"
ask STACK_NOTE "One-line stack note for the agent" "$(d stack_note 'follow the conventions in CLAUDE.md / README')"
ask CLAUDE_MODEL "Claude model" "$(d claude_model 'claude-sonnet-5')"

repo_slug=$(basename "$TARGET" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
WORKER_NAME="$(d worker_name "${repo_slug}-discord-relay")"

say "Summary"
cat <<EOF
  Target repo        $TARGET
  GitHub repo        $GITHUB_REPO
  Handlers           $HANDLERS
  Incident watch     $WF_NAMES
  Agent              $AGENT_NAME · brain claude-code · model $CLAUDE_MODEL
EOF
confirm "Install into $TARGET?" || { echo "aborted — nothing written"; exit 1; }

say "Installing files"
RENDER_VARS="GITHUB_REPO HANDLERS INCIDENT_WORKFLOWS AGENT_NAME PROJECT_NAME AUDIENCE STACK_NOTE CLAUDE_MODEL WORKER_NAME"

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
echo "  + scripts/discord-agent/ai/brain.sh  (core/ai/claude-code.sh)"
chmod +x "$AGENT_DIR"/*.sh

jq -n \
  --arg github_repo "$GITHUB_REPO" --arg handlers "$HANDLERS" \
  --arg wf_names "$WF_NAMES" --arg agent_name "$AGENT_NAME" \
  --arg project_name "$PROJECT_NAME" --arg audience "$AUDIENCE" \
  --arg stack_note "$STACK_NOTE" --arg claude_model "$CLAUDE_MODEL" \
  --arg worker_name "$WORKER_NAME" \
  '{recipe: "discord/notify-agent", runtime: "github-actions", brain: "claude-code",
    handlers: $handlers, github_repo: $github_repo, wf_names: $wf_names,
    agent_name: $agent_name, project_name: $project_name, audience: $audience,
    stack_note: $stack_note, claude_model: $claude_model,
    worker_name: $worker_name}' > "$CONFIG"
echo "  + scripts/discord-agent/automation.config.json"

render_check "$AGENT_DIR" "$TARGET/.github/workflows/discord-agent.yml" || true

say "Next steps (in order)"
cat <<EOF
1. GitHub secrets on $GITHUB_REPO:
     gh secret set DISCORD_WEBHOOK_URL -R $GITHUB_REPO      # channel → Integrations → Webhooks → Copy URL
     gh secret set CLAUDE_CODE_OAUTH_TOKEN -R $GITHUB_REPO  # or ANTHROPIC_API_KEY

2. Commit the new files in $TARGET and merge to the default branch.
   ship/incident are now LIVE — no relay needed.

3. ONLY if you enabled 'ask' — create a Discord app (discord.com/developers),
   then deploy the relay and wire the interactions endpoint:
     cd $AGENT_DIR/relay
     wrangler deploy
     wrangler secret put GITHUB_PAT          # fine-grained PAT: only $GITHUB_REPO, contents: read+write
     wrangler secret put DISCORD_PUBLIC_KEY  # app's General Information → Public Key
   In the Developer Portal → General Information:
     Interactions Endpoint URL: https://$WORKER_NAME.<your-cf-subdomain>.workers.dev/
     (Discord verifies with a PING + bad-signature probe — the relay handles both.)
   Register the /ask command (once; guild-scoped appears instantly):
     curl -X POST "https://discord.com/api/v10/applications/<APP_ID>/guilds/<GUILD_ID>/commands" \\
       -H "Authorization: Bot <BOT_TOKEN>" -H "Content-Type: application/json" \\
       -d '{"name": "ask", "description": "Ask the repo agent", "options":
            [{"type": 3, "name": "question", "description": "Your question", "required": true}]}'

4. Test without sending anything:
     cd $TARGET && DRY_RUN=1 MODE=ship RELEASE_TAG=v0.0.0 bash scripts/discord-agent/agent-run.sh
   Real test: Actions → Discord Notify Agent → Run workflow → mode: ship.

Operating docs: scripts/discord-agent/README.md
EOF
