#!/usr/bin/env bash
# Interactive installer for the Sentry Triage Agent.
# Renders files/ (+ core adapters) into a target repository.
set -euo pipefail

RECIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$RECIPE_DIR/../../.." && pwd)"
FILES="$RECIPE_DIR/files"
source "$ROOT/core/lib/wizard.sh"
source "$ROOT/core/lib/render.sh"

need git jq curl

say "Sentry Triage Agent — setup"
cat <<'EOF'
Installs an event-driven AI agent into one of YOUR repositories:

  Sentry issue alert (HMAC-verified) → Cloudflare Worker relay → GitHub Actions → headless Claude Code

Flow: an issue alert fires → the agent fetches the Sentry issue + latest
stack trace, reads this repository at the crash locations, and files ONE
GitHub issue (error, impact, likely cause, where to look). Recurrences become
ONE comment on that same issue — never a duplicate. It never writes to Sentry
and never changes code.

You'll need: a GitHub repo, a Sentry org (you'll create an Internal
Integration in the next steps — it provides both the webhook and the token),
a free Cloudflare account, and Claude auth.

Finding slugs: both are in Sentry URLs — sentry.io/organizations/<org>/
and .../projects/<project>/. Self-hosted Sentry works too: point the API
base URL at your instance.
EOF

say "Target repository"
ask TARGET_IN "Path to the repository the agent should work in"
TARGET_IN="${TARGET_IN/#\~/$HOME}"
TARGET="$(cd "$TARGET_IN" 2>/dev/null && pwd)" || { echo "error: no such directory: $TARGET_IN" >&2; exit 1; }
[[ -d "$TARGET/.git" ]] || { echo "error: not a git repository: $TARGET" >&2; exit 1; }

AGENT_DIR="$TARGET/scripts/sentry-agent"
CONFIG="$AGENT_DIR/automation.config.json"
cfg() { jq -r ".$1 // empty" "$CONFIG" 2>/dev/null || true; }
d() { local v; v="$(cfg "$1")"; printf '%s' "${v:-$2}"; }
[[ -f "$CONFIG" ]] && note "(existing install found — answers default to your previous choices)"

origin_url=$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)
guess_repo=$(printf '%s' "$origin_url" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
ask GITHUB_REPO "GitHub repo (owner/name)" "$(d github_repo "$guess_repo")"

say "Sentry"
ask SENTRY_API_BASE "Sentry API base URL" "$(d sentry_api_base 'https://sentry.io/api/0')"
ask SENTRY_ORG "Organization slug" "$(d sentry_org '')"
ask SENTRY_PROJECT "Project slug" "$(d sentry_project '')"
HANDLERS="issues"

say "Conventions"
ask ISSUE_LABEL "Label applied to filed GitHub issues" "$(d issue_label 'sentry')"
ask AGENT_NAME "Agent display name (signs every issue)" "$(d agent_name 'Sentry Triage Agent')"
AGENT_MARKER="🤖 $AGENT_NAME"
ask PROJECT_NAME "Product name used in issues" "$(d project_name "$(basename "$TARGET")")"
ask STACK_NOTE "One-line stack note for the agent" "$(d stack_note 'follow the conventions in CLAUDE.md / README')"
ask CLAUDE_MODEL "Claude model" "$(d claude_model 'claude-sonnet-5')"

repo_slug=$(basename "$TARGET" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
WORKER_NAME="$(d worker_name "${repo_slug}-sentry-relay")"

say "Summary"
cat <<EOF
  Target repo        $TARGET
  GitHub repo        $GITHUB_REPO
  Sentry             $SENTRY_ORG / $SENTRY_PROJECT  ($SENTRY_API_BASE)
  Issue label        $ISSUE_LABEL
  Agent              $AGENT_MARKER · brain claude-code · model $CLAUDE_MODEL
  Relay worker       $WORKER_NAME
EOF
confirm "Install into $TARGET?" || { echo "aborted — nothing written"; exit 1; }

say "Installing files"
RENDER_VARS="GITHUB_REPO HANDLERS SENTRY_API_BASE SENTRY_ORG SENTRY_PROJECT ISSUE_LABEL AGENT_NAME AGENT_MARKER PROJECT_NAME STACK_NOTE CLAUDE_MODEL WORKER_NAME"

(cd "$FILES" && find . -type f ! -name '.DS_Store' | sed 's#^\./##') | while IFS= read -r rel; do
  src="$FILES/$rel"
  case "$rel" in
    *.tmpl) dest="$TARGET/${rel%.tmpl}"; render "$src" "$dest" ;;
    *) dest="$TARGET/$rel"; mkdir -p "$(dirname "$dest")"; cp "$src" "$dest" ;;
  esac
  echo "  + ${dest#"$TARGET/"}"
done

install -m 0755 "$ROOT/core/state/git-branch.sh" "$AGENT_DIR/state.sh"
echo "  + scripts/sentry-agent/state.sh  (core/state/git-branch.sh)"
mkdir -p "$AGENT_DIR/ai"
install -m 0644 "$ROOT/core/ai/claude-code.sh" "$AGENT_DIR/ai/brain.sh"
echo "  + scripts/sentry-agent/ai/brain.sh  (core/ai/claude-code.sh)"
chmod +x "$AGENT_DIR"/*.sh

jq -n \
  --arg github_repo "$GITHUB_REPO" --arg sentry_api_base "$SENTRY_API_BASE" \
  --arg sentry_org "$SENTRY_ORG" --arg sentry_project "$SENTRY_PROJECT" \
  --arg issue_label "$ISSUE_LABEL" --arg agent_name "$AGENT_NAME" \
  --arg project_name "$PROJECT_NAME" --arg stack_note "$STACK_NOTE" \
  --arg claude_model "$CLAUDE_MODEL" --arg worker_name "$WORKER_NAME" \
  '{recipe: "sentry/triage-agent", runtime: "github-actions", brain: "claude-code",
    handlers: "issues", github_repo: $github_repo, sentry_api_base: $sentry_api_base,
    sentry_org: $sentry_org, sentry_project: $sentry_project,
    issue_label: $issue_label, agent_name: $agent_name,
    project_name: $project_name, stack_note: $stack_note,
    claude_model: $claude_model, worker_name: $worker_name}' > "$CONFIG"
echo "  + scripts/sentry-agent/automation.config.json"

render_check "$AGENT_DIR" "$TARGET/.github/workflows/sentry-agent.yml" || true

say "GitHub secrets"
note "Required on $GITHUB_REPO:"
note "  SENTRY_TOKEN — the Internal Integration's token (project:read + event:read), or a user auth token"
note "  CLAUDE_CODE_OAUTH_TOKEN — 'claude setup-token' (subscription) OR ANTHROPIC_API_KEY (pay-per-token)"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  if confirm "Set secrets on $GITHUB_REPO now with gh?"; then
    for s in SENTRY_TOKEN CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY AGENT_GH_PAT; do
      if confirm "  set $s?"; then gh secret set "$s" -R "$GITHUB_REPO"; fi
    done
  fi
else
  note "gh CLI not available/authenticated — set the secrets manually at:"
  note "  https://github.com/$GITHUB_REPO/settings/secrets/actions"
fi

say "Next steps (in order)"
cat <<EOF
1. Secrets (if any were skipped above) — see the list just printed.
   AGENT_GH_PAT (optional, classic PAT with 'repo' scope) files issues as a
   real user instead of github-actions[bot], so they notify the team and can
   trigger other workflows.

2. Create the issue label once (gh issue create fails on unknown labels):
     gh label create "$ISSUE_LABEL" -R "$GITHUB_REPO" --description "Filed by $AGENT_NAME"

3. Deploy the relay (free Cloudflare account; npm i -g wrangler):
     cd $AGENT_DIR/relay
     wrangler deploy
     wrangler secret put GITHUB_PAT   # fine-grained PAT: only $GITHUB_REPO, contents: read+write

4. Create the Internal Integration (Sentry → Settings → Developer Settings →
   Custom Integrations → New Internal Integration):
     - Webhook URL: https://$WORKER_NAME.<your-cf-subdomain>.workers.dev/hook
     - Enable "Alert Rule Action"
     - Permissions: Issue & Event → Read (project:read + event:read)
     - Copy the Client Secret, then:  wrangler secret put SENTRY_CLIENT_SECRET
     - Copy a token from the integration's Tokens section → repo secret SENTRY_TOKEN

5. Point an issue alert rule at it (Alerts → Create Alert Rule, or edit an
   existing rule): add the action "Send a notification via <integration name>".

6. Commit the new files in $TARGET and merge them to the default branch
   (repository_dispatch only triggers workflows on the default branch).

7. Safe local test — no GitHub issues, no AI, no state pushed
   (export SENTRY_TOKEN first):
     cd $TARGET && DRY_RUN=1 bash scripts/sentry-agent/agent-run.sh

Operating docs (recovery, pausing, transcripts): scripts/sentry-agent/README.md
EOF
