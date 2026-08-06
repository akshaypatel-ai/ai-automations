#!/usr/bin/env bash
# Interactive installer for the PagerDuty Triage Agent.
# Renders files/ (+ core adapters) into a target repository.
set -euo pipefail

RECIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$RECIPE_DIR/../../.." && pwd)"
FILES="$RECIPE_DIR/files"
source "$ROOT/core/lib/wizard.sh"
source "$ROOT/core/lib/render.sh"
source "$ROOT/core/lib/brains.sh"

need git jq curl

say "PagerDuty Triage Agent — setup"
cat <<'EOF'
Installs an event-driven AI incident-triage agent into one of YOUR repositories:

  PagerDuty v3 webhook (signed) → Cloudflare Worker relay → GitHub Actions → headless Claude Code

Flow: an incident triggers → the agent fetches the incident + all of its
alerts, reads this repository at the implicated code, and posts ONE note on
the incident — what happened, impact, likely cause, where to look — right
where responders are working. It NEVER acknowledges, resolves, assigns, or
escalates; humans own the incident.

You'll need: a GitHub repo, a PagerDuty REST API key (Integrations → API
Access Keys), a free Cloudflare account, and Claude auth.
EOF

say "Target repository"
ask TARGET_IN "Path to the repository the agent should work in"
TARGET_IN="${TARGET_IN/#\~/$HOME}"
TARGET="$(cd "$TARGET_IN" 2>/dev/null && pwd)" || { echo "error: no such directory: $TARGET_IN" >&2; exit 1; }
[[ -d "$TARGET/.git" ]] || { echo "error: not a git repository: $TARGET" >&2; exit 1; }

AGENT_DIR="$TARGET/scripts/pagerduty-agent"
CONFIG="$AGENT_DIR/automation.config.json"
cfg() { jq -r ".$1 // empty" "$CONFIG" 2>/dev/null || true; }
d() { local v; v="$(cfg "$1")"; printf '%s' "${v:-$2}"; }
[[ -f "$CONFIG" ]] && note "(existing install found — answers default to your previous choices)"

origin_url=$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)
guess_repo=$(printf '%s' "$origin_url" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
ask GITHUB_REPO "GitHub repo (owner/name)" "$(d github_repo "$guess_repo")"

say "PagerDuty"
note "Notes are attributed to a real PagerDuty user via the API's From: header."
ask PAGERDUTY_FROM_EMAIL "PagerDuty user email for note attribution (any real user on the account)" "$(d pagerduty_from_email '')"
HANDLERS="incidents"

say "Conventions"
ask AGENT_NAME "Agent display name (opens every note)" "$(d agent_name 'Incident Triage Agent')"
AGENT_MARKER="🤖 $AGENT_NAME"
ask PROJECT_NAME "Product name used in notes" "$(d project_name "$(basename "$TARGET")")"
ask STACK_NOTE "One-line stack note for the agent" "$(d stack_note 'follow the conventions in CLAUDE.md / README')"
choose_brain "$ROOT/core/ai" "$(d brain 'claude-code')" mediated
ask AI_MODEL "Model for $BRAIN_NAME" "$(d ai_model "$AI_MODEL_DEFAULT")"

repo_slug=$(basename "$TARGET" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
WORKER_NAME="$(d worker_name "${repo_slug}-pagerduty-relay")"

say "Summary"
cat <<EOF
  Target repo        $TARGET
  GitHub repo        $GITHUB_REPO
  Note attribution   $PAGERDUTY_FROM_EMAIL (the From: user on every note)
  Agent              $AGENT_MARKER · brain $BRAIN_NAME · model $AI_MODEL
  Writes             incident notes only — never ack/resolve/assign/escalate
  Relay worker       $WORKER_NAME
EOF
confirm "Install into $TARGET?" || { echo "aborted — nothing written"; exit 1; }

say "Installing files"
RENDER_VARS="GITHUB_REPO HANDLERS PAGERDUTY_FROM_EMAIL AGENT_NAME AGENT_MARKER PROJECT_NAME STACK_NOTE BRAIN_NAME AI_MODEL WORKER_NAME"

(cd "$FILES" && find . -type f ! -name '.DS_Store' | sed 's#^\./##') | while IFS= read -r rel; do
  src="$FILES/$rel"
  case "$rel" in
    *.tmpl) dest="$TARGET/${rel%.tmpl}"; render "$src" "$dest" ;;
    *) dest="$TARGET/$rel"; mkdir -p "$(dirname "$dest")"; cp "$src" "$dest" ;;
  esac
  echo "  + ${dest#"$TARGET/"}"
done

install -m 0755 "$ROOT/core/state/git-branch.sh" "$AGENT_DIR/state.sh"
echo "  + scripts/pagerduty-agent/state.sh  (core/state/git-branch.sh)"
mkdir -p "$AGENT_DIR/ai"
install -m 0644 "$BRAIN_FILE" "$AGENT_DIR/ai/brain.sh"
echo "  + scripts/pagerduty-agent/ai/brain.sh  ($BRAIN_NAME)"
chmod +x "$AGENT_DIR"/*.sh

jq -n \
  --arg github_repo "$GITHUB_REPO" --arg pagerduty_from_email "$PAGERDUTY_FROM_EMAIL" \
  --arg agent_name "$AGENT_NAME" --arg project_name "$PROJECT_NAME" \
  --arg stack_note "$STACK_NOTE" --arg brain "$BRAIN_NAME" --arg ai_model "$AI_MODEL" \
  --arg worker_name "$WORKER_NAME" \
  '{recipe: "pagerduty/triage-agent", runtime: "github-actions", brain: $brain,
    handlers: "incidents", github_repo: $github_repo,
    pagerduty_from_email: $pagerduty_from_email, agent_name: $agent_name,
    project_name: $project_name, stack_note: $stack_note,
    ai_model: $ai_model, worker_name: $worker_name}' > "$CONFIG"
echo "  + scripts/pagerduty-agent/automation.config.json"

render_check "$AGENT_DIR" "$TARGET/.github/workflows/pagerduty-agent.yml" || true

say "GitHub secrets"
note "Required on $GITHUB_REPO:"
note "  PAGERDUTY_TOKEN — PagerDuty → Integrations → API Access Keys (a read-write REST API key; posting notes needs write)"
note "  $BRAIN_AUTH_VARS — auth for the $BRAIN_NAME brain"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  if confirm "Set secrets on $GITHUB_REPO now with gh?"; then
    for s in PAGERDUTY_TOKEN $BRAIN_AUTH_VARS AGENT_GH_PAT; do
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
   AGENT_GH_PAT (optional, classic PAT with 'repo' scope) pushes the state
   branch as a real user instead of github-actions[bot]; the built-in token
   works fine here.

2. Deploy the relay (free Cloudflare account; npm i -g wrangler):
     cd $AGENT_DIR/relay
     wrangler deploy
     wrangler secret put GITHUB_PAT   # fine-grained PAT: only $GITHUB_REPO, contents: read+write

3. Create the v3 webhook (PagerDuty → Integrations → Generic Webhooks (v3)):
     - URL: https://$WORKER_NAME.<your-cf-subdomain>.workers.dev/hook
     - Scope: the whole account, or just the service(s) this repo backs
     - Events: incident.triggered, incident.reopened, incident.escalated
     - The signing secret is shown ONCE when the webhook is created — store it
       immediately:  wrangler secret put PAGERDUTY_WEBHOOK_SECRET

4. Commit the new files in $TARGET and merge them to the default branch
   (repository_dispatch only triggers workflows on the default branch).

5. Safe local test — no notes, no AI, no state pushed
   (export PAGERDUTY_TOKEN first):
     cd $TARGET && DRY_RUN=1 bash scripts/pagerduty-agent/agent-run.sh

Operating docs (recovery, pausing, transcripts): scripts/pagerduty-agent/README.md
EOF
