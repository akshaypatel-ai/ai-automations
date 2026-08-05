#!/usr/bin/env bash
# Interactive installer for the Slack Triage Agent.
# Renders files/ (+ core adapters) into a target repository.
set -euo pipefail

RECIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$RECIPE_DIR/../../.." && pwd)"
FILES="$RECIPE_DIR/files"
source "$ROOT/core/lib/wizard.sh"
source "$ROOT/core/lib/render.sh"

need git jq curl

say "Slack Triage Agent — setup"
cat <<'EOF'
Installs a conversational AI agent into one of YOUR repositories:

  Slack Events API → Cloudflare Worker relay (acks <3s) → GitHub Actions → headless Claude Code

What it does: answers @mentions and DMs grounded in your actual code; triages
designated support/eng channels (answers FAQs, escalates real bugs as GitHub
issues with a thread link); a trigger emoji summons it onto any message.
It never writes code from chat — build requests get redirected to your board.

You'll need: a GitHub repo, permission to create a Slack app in your
workspace, a free Cloudflare account, and Claude auth.
EOF

say "Target repository"
ask TARGET_IN "Path to the repository the agent should answer from"
TARGET_IN="${TARGET_IN/#\~/$HOME}"
TARGET="$(cd "$TARGET_IN" 2>/dev/null && pwd)" || { echo "error: no such directory: $TARGET_IN" >&2; exit 1; }
[[ -d "$TARGET/.git" ]] || { echo "error: not a git repository: $TARGET" >&2; exit 1; }

AGENT_DIR="$TARGET/scripts/slack-agent"
CONFIG="$AGENT_DIR/automation.config.json"
cfg() { jq -r ".$1 // empty" "$CONFIG" 2>/dev/null || true; }
d() { local v; v="$(cfg "$1")"; printf '%s' "${v:-$2}"; }
[[ -f "$CONFIG" ]] && note "(existing install found — answers default to your previous choices)"

origin_url=$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)
guess_repo=$(printf '%s' "$origin_url" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
ask GITHUB_REPO "GitHub repo (owner/name)" "$(d github_repo "$guess_repo")"

say "Slack"
ask HANDLERS "Handlers to enable (mentions,channel,reactions,dm)" "$(d handlers 'mentions,channel,reactions')"
HANDLERS=$(printf '%s' "$HANDLERS" | tr -d ' ')
ask_opt WATCHED_CHANNELS "Channel IDs to triage (comma-separated C… ids; right-click channel → Copy link)" "$(d watched_channels '')"
ask TRIGGER_EMOJI "Trigger emoji names, no colons (comma-separated)" "$(d trigger_emoji 'robot_face')"

say "Conventions"
ask AGENT_NAME "Agent display name (also the Slack app name)" "$(d agent_name 'Triage Agent')"
ask PROJECT_NAME "Product name used in replies" "$(d project_name "$(basename "$TARGET")")"
ask AUDIENCE "Who chats with the agent? (replies are written for them)" "$(d audience 'the team')"
ask STACK_NOTE "One-line stack note for the agent" "$(d stack_note 'follow the conventions in CLAUDE.md / README')"
ask CLAUDE_MODEL "Claude model" "$(d claude_model 'claude-sonnet-5')"

repo_slug=$(basename "$TARGET" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
WORKER_NAME="$(d worker_name "${repo_slug}-slack-relay")"

say "Summary"
cat <<EOF
  Target repo        $TARGET
  GitHub repo        $GITHUB_REPO
  Handlers           $HANDLERS
  Triage channels    ${WATCHED_CHANNELS:-none (mentions/emoji/DM only)}
  Trigger emoji      $TRIGGER_EMOJI
  Agent              $AGENT_NAME · brain claude-code · model $CLAUDE_MODEL
  Relay worker       $WORKER_NAME
EOF
confirm "Install into $TARGET?" || { echo "aborted — nothing written"; exit 1; }

say "Installing files"
RENDER_VARS="GITHUB_REPO HANDLERS WATCHED_CHANNELS TRIGGER_EMOJI AGENT_NAME PROJECT_NAME AUDIENCE STACK_NOTE CLAUDE_MODEL WORKER_NAME"

(cd "$FILES" && find . -type f ! -name '.DS_Store' | sed 's#^\./##') | while IFS= read -r rel; do
  src="$FILES/$rel"
  case "$rel" in
    *.tmpl) dest="$TARGET/${rel%.tmpl}"; render "$src" "$dest" ;;
    *) dest="$TARGET/$rel"; mkdir -p "$(dirname "$dest")"; cp "$src" "$dest" ;;
  esac
  echo "  + ${dest#"$TARGET/"}"
done

install -m 0755 "$ROOT/core/state/git-branch.sh" "$AGENT_DIR/state.sh"
echo "  + scripts/slack-agent/state.sh  (core/state/git-branch.sh)"
mkdir -p "$AGENT_DIR/ai"
install -m 0644 "$ROOT/core/ai/claude-code.sh" "$AGENT_DIR/ai/brain.sh"
echo "  + scripts/slack-agent/ai/brain.sh  (core/ai/claude-code.sh)"
chmod +x "$AGENT_DIR"/*.sh

jq -n \
  --arg github_repo "$GITHUB_REPO" --arg handlers "$HANDLERS" \
  --arg watched_channels "$WATCHED_CHANNELS" --arg trigger_emoji "$TRIGGER_EMOJI" \
  --arg agent_name "$AGENT_NAME" --arg project_name "$PROJECT_NAME" \
  --arg audience "$AUDIENCE" --arg stack_note "$STACK_NOTE" \
  --arg claude_model "$CLAUDE_MODEL" --arg worker_name "$WORKER_NAME" \
  '{recipe: "slack/triage-agent", runtime: "github-actions", brain: "claude-code",
    handlers: $handlers, github_repo: $github_repo, watched_channels: $watched_channels,
    trigger_emoji: $trigger_emoji, agent_name: $agent_name, project_name: $project_name,
    audience: $audience, stack_note: $stack_note, claude_model: $claude_model,
    worker_name: $worker_name}' > "$CONFIG"
echo "  + scripts/slack-agent/automation.config.json"

render_check "$AGENT_DIR" "$TARGET/.github/workflows/slack-agent.yml" || true

say "Next steps (in order)"
cat <<EOF
1. Deploy the relay (free Cloudflare account; npm i -g wrangler):
     cd $AGENT_DIR/relay
     wrangler deploy
     wrangler secret put GITHUB_PAT   # fine-grained PAT: only $GITHUB_REPO, contents: read+write
     # SLACK_SIGNING_SECRET comes in step 2

2. Create the Slack app at https://api.slack.com/apps → "From a manifest",
   paste this manifest (adjust names to taste):

--------------------------------------------------------------------
display_information:
  name: $AGENT_NAME
features:
  bot_user:
    display_name: $(printf '%s' "$AGENT_NAME" | tr '[:upper:] ' '[:lower:]-')
oauth_config:
  scopes:
    bot:
      - app_mentions:read
      - channels:history
      - channels:read
      - chat:write
      - reactions:read
      - im:history
      - im:read
settings:
  event_subscriptions:
    request_url: https://$WORKER_NAME.<your-cf-subdomain>.workers.dev/
    bot_events:
      - app_mention
      - message.channels
      - message.im
      - reaction_added
--------------------------------------------------------------------

   Then: Basic Information → copy the Signing Secret:
     wrangler secret put SLACK_SIGNING_SECRET
   Install the app to the workspace; OAuth page → copy the Bot Token (xoxb-…).
   (Set the event request URL AFTER the signing secret is in the worker —
   Slack verifies the URL with a signed challenge.)

3. GitHub secrets on $GITHUB_REPO:
     gh secret set SLACK_BOT_TOKEN -R $GITHUB_REPO
     gh secret set CLAUDE_CODE_OAUTH_TOKEN -R $GITHUB_REPO   # or ANTHROPIC_API_KEY

4. Invite the bot to the triage channels: /invite @$(printf '%s' "$AGENT_NAME")

5. Commit the new files in $TARGET and merge them to the default branch.

6. Safe local test — no replies, no AI, no state pushed
   (export SLACK_BOT_TOKEN first):
     cd $TARGET && DRY_RUN=1 bash scripts/slack-agent/agent-run.sh

Operating docs: scripts/slack-agent/README.md
EOF
