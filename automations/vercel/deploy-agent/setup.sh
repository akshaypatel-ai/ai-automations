#!/usr/bin/env bash
# Interactive installer for the Vercel Deploy Agent.
# Renders files/ (+ core adapters) into a target repository.
set -euo pipefail

RECIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$RECIPE_DIR/../../.." && pwd)"
FILES="$RECIPE_DIR/files"
source "$ROOT/core/lib/wizard.sh"
source "$ROOT/core/lib/render.sh"
source "$ROOT/core/lib/brains.sh"

need git jq curl

say "Vercel Deploy Agent — setup"
cat <<'EOF'
Installs an event-driven AI agent into one of YOUR repositories:

  Vercel deployment.error webhook (HMAC-verified) → Cloudflare Worker relay → GitHub Actions → headless Claude Code

Flow: a deployment of this repo fails → the agent fetches the deployment +
its build logs from Vercel, reads this repository at the failing build step,
and files ONE GitHub issue (what failed, log excerpt, likely cause, where to
look, links). New failures of the same commit become ONE comment on that
issue — never a duplicate. It never retries, cancels, or promotes
deployments — Vercel is read-only; the only writes are GitHub issues.

You'll need: a GitHub repo deployed on Vercel, a Vercel token (Account
Settings → Tokens), a free Cloudflare account, and Claude auth.

Finding ids: the team id is under Team Settings → General (leave empty for
personal accounts); the project id is under Project Settings → General
(leave empty to watch every project the token can see).
EOF

say "Target repository"
ask TARGET_IN "Path to the repository the agent should work in"
TARGET_IN="${TARGET_IN/#\~/$HOME}"
TARGET="$(cd "$TARGET_IN" 2>/dev/null && pwd)" || { echo "error: no such directory: $TARGET_IN" >&2; exit 1; }
[[ -d "$TARGET/.git" ]] || { echo "error: not a git repository: $TARGET" >&2; exit 1; }

AGENT_DIR="$TARGET/scripts/vercel-agent"
CONFIG="$AGENT_DIR/automation.config.json"
cfg() { jq -r ".$1 // empty" "$CONFIG" 2>/dev/null || true; }
d() { local v; v="$(cfg "$1")"; printf '%s' "${v:-$2}"; }
[[ -f "$CONFIG" ]] && note "(existing install found — answers default to your previous choices)"

origin_url=$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)
guess_repo=$(printf '%s' "$origin_url" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
ask GITHUB_REPO "GitHub repo (owner/name)" "$(d github_repo "$guess_repo")"

say "Vercel"
note "Team id: Team Settings → General. Empty is fine for personal accounts."
ask_opt VERCEL_TEAM_ID "Vercel team id (team_…)" "$(d vercel_team_id '')"
note "Project id: Project Settings → General. Empty watches all projects the token sees."
ask_opt VERCEL_PROJECT_ID "Vercel project id (prj_…)" "$(d vercel_project_id '')"
HANDLERS="deployments"

say "Conventions"
ask ISSUE_LABEL "Label applied to filed GitHub issues" "$(d issue_label 'deploy-failure')"
ask AGENT_NAME "Agent display name (signs every issue)" "$(d agent_name 'Deploy Triage Agent')"
AGENT_MARKER="🤖 $AGENT_NAME"
ask PROJECT_NAME "Product name used in issues" "$(d project_name "$(basename "$TARGET")")"
ask STACK_NOTE "One-line stack note for the agent" "$(d stack_note 'follow the conventions in CLAUDE.md / README')"
choose_brain "$ROOT/core/ai" "$(d brain 'claude-code')"
ask AI_MODEL "Model for $BRAIN_NAME" "$(d ai_model "$AI_MODEL_DEFAULT")"

repo_slug=$(basename "$TARGET" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
WORKER_NAME="$(d worker_name "${repo_slug}-vercel-relay")"

say "Summary"
cat <<EOF
  Target repo        $TARGET
  GitHub repo        $GITHUB_REPO
  Vercel             team ${VERCEL_TEAM_ID:-"(personal)"} · project ${VERCEL_PROJECT_ID:-"(all)"}
  Issue label        $ISSUE_LABEL
  Agent              $AGENT_MARKER · brain $BRAIN_NAME · model $AI_MODEL
  Relay worker       $WORKER_NAME
EOF
confirm "Install into $TARGET?" || { echo "aborted — nothing written"; exit 1; }

say "Installing files"
RENDER_VARS="GITHUB_REPO HANDLERS VERCEL_TEAM_ID VERCEL_PROJECT_ID ISSUE_LABEL AGENT_NAME AGENT_MARKER PROJECT_NAME STACK_NOTE BRAIN_NAME AI_MODEL WORKER_NAME"

(cd "$FILES" && find . -type f ! -name '.DS_Store' | sed 's#^\./##') | while IFS= read -r rel; do
  src="$FILES/$rel"
  case "$rel" in
    *.tmpl) dest="$TARGET/${rel%.tmpl}"; render "$src" "$dest" ;;
    *) dest="$TARGET/$rel"; mkdir -p "$(dirname "$dest")"; cp "$src" "$dest" ;;
  esac
  echo "  + ${dest#"$TARGET/"}"
done

install -m 0755 "$ROOT/core/state/git-branch.sh" "$AGENT_DIR/state.sh"
echo "  + scripts/vercel-agent/state.sh  (core/state/git-branch.sh)"
mkdir -p "$AGENT_DIR/ai"
install -m 0644 "$BRAIN_FILE" "$AGENT_DIR/ai/brain.sh"
echo "  + scripts/vercel-agent/ai/brain.sh  ($BRAIN_NAME)"
chmod +x "$AGENT_DIR"/*.sh

jq -n \
  --arg github_repo "$GITHUB_REPO" --arg vercel_team_id "$VERCEL_TEAM_ID" \
  --arg vercel_project_id "$VERCEL_PROJECT_ID" \
  --arg issue_label "$ISSUE_LABEL" --arg agent_name "$AGENT_NAME" \
  --arg project_name "$PROJECT_NAME" --arg stack_note "$STACK_NOTE" \
  --arg brain "$BRAIN_NAME" --arg ai_model "$AI_MODEL" --arg worker_name "$WORKER_NAME" \
  '{recipe: "vercel/deploy-agent", runtime: "github-actions", brain: $brain,
    handlers: "deployments", github_repo: $github_repo,
    vercel_team_id: $vercel_team_id, vercel_project_id: $vercel_project_id,
    issue_label: $issue_label, agent_name: $agent_name,
    project_name: $project_name, stack_note: $stack_note,
    ai_model: $ai_model, worker_name: $worker_name}' > "$CONFIG"
echo "  + scripts/vercel-agent/automation.config.json"

render_check "$AGENT_DIR" "$TARGET/.github/workflows/vercel-agent.yml" || true

say "GitHub secrets"
note "Required on $GITHUB_REPO:"
note "  VERCEL_TOKEN — Account Settings → Tokens (vercel.com/account/tokens); scope it to the team when the project lives in one"
note "  $BRAIN_AUTH_VARS — auth for the $BRAIN_NAME brain"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  if confirm "Set secrets on $GITHUB_REPO now with gh?"; then
    for s in VERCEL_TOKEN $BRAIN_AUTH_VARS AGENT_GH_PAT; do
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

4. Create the webhook (Vercel → Team/Account Settings → Webhooks):
     - Events: deployment.error (only this one matters here)
     - Projects: scope it to your project(s)
     - URL: https://$WORKER_NAME.<your-cf-subdomain>.workers.dev/hook
     - Copy the secret — it is shown exactly once at creation; store it
       immediately:  wrangler secret put VERCEL_WEBHOOK_SECRET

5. Commit the new files in $TARGET and merge them to the default branch
   (repository_dispatch only triggers workflows on the default branch).

6. Safe local test — no GitHub issues, no AI, no state pushed
   (export VERCEL_TOKEN first):
     cd $TARGET && DRY_RUN=1 bash scripts/vercel-agent/agent-run.sh

Operating docs (recovery, pausing, transcripts): scripts/vercel-agent/README.md
EOF
