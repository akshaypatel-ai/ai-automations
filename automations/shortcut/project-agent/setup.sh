#!/usr/bin/env bash
# Interactive installer for the Shortcut Project Agent.
# Renders files/ (+ core adapters) into a target repository.
set -euo pipefail

RECIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$RECIPE_DIR/../../.." && pwd)"
FILES="$RECIPE_DIR/files"
source "$ROOT/core/lib/wizard.sh"
source "$ROOT/core/lib/render.sh"
source "$ROOT/core/lib/brains.sh"
source "$ROOT/core/lib/runtimes.sh"

need git jq curl

say "Shortcut Project Agent — setup"
cat <<'EOF'
Installs an event-driven AI agent into one of YOUR repositories:

  Shortcut webhook (HMAC-verified) → Cloudflare Worker relay → GitHub Actions → headless Claude Code

Flow: story enters your ANALYZE workflow state → the agent posts
options/questions; discuss in comments; move it to your IMPLEMENT state → it
builds the change and opens a ready-for-review PR. It never moves stories or
changes workflow states — humans own the board.

You'll need: a GitHub repo, a Shortcut API token (Settings → API Tokens),
a free Cloudflare account, and Claude auth.

Workflow states are Shortcut's board columns. The outgoing webhook is
workspace-wide: the agent only acts on stories sitting in the two state
names you pick below (matched case-insensitively across all workflows).
EOF

say "Target repository"
ask TARGET_IN "Path to the repository the agent should work in"
TARGET_IN="${TARGET_IN/#\~/$HOME}"
TARGET="$(cd "$TARGET_IN" 2>/dev/null && pwd)" || { echo "error: no such directory: $TARGET_IN" >&2; exit 1; }
[[ -d "$TARGET/.git" ]] || { echo "error: not a git repository: $TARGET" >&2; exit 1; }

AGENT_DIR="$TARGET/scripts/shortcut-agent"
CONFIG="$AGENT_DIR/automation.config.json"
cfg() { jq -r ".$1 // empty" "$CONFIG" 2>/dev/null || true; }
d() { local v; v="$(cfg "$1")"; printf '%s' "${v:-$2}"; }
[[ -f "$CONFIG" ]] && note "(existing install found — answers default to your previous choices)"

origin_url=$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)
guess_repo=$(printf '%s' "$origin_url" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
ask GITHUB_REPO "GitHub repo (owner/name)" "$(d github_repo "$guess_repo")"

say "Shortcut"
ask STATE_ANALYZE "Workflow state the agent ANALYZES stories in" "$(d state_analyze 'To Do')"
ask STATE_IMPLEMENT "Workflow state the agent IMPLEMENTS stories from" "$(d state_implement 'In Progress')"
HANDLERS="stories"

say "Conventions"
ask AGENT_NAME "Agent display name (signs every comment)" "$(d agent_name 'Project Agent')"
AGENT_MARKER="🤖 $AGENT_NAME"
ask PROJECT_NAME "Product name used in comments" "$(d project_name "$(basename "$TARGET")")"
ask AUDIENCE "Who reads these stories? (comments are written for them)" "$(d audience 'the team')"
ask STACK_NOTE "One-line stack note for the agent" "$(d stack_note 'follow the conventions in CLAUDE.md / README')"
ask BRANCH_PREFIX "Branch prefix for agent branches" "$(d branch_prefix 'ai-agent')"
default_base="$(git -C "$TARGET" symbolic-ref --short HEAD 2>/dev/null || echo main)"
ask PR_BASE "Base branch for agent PRs" "$(d pr_base "$default_base")"
ask_opt QA_COMMAND "Quick QA command before a PR (e.g. 'npm run lint')" "$(d qa_command '')"
choose_brain "$ROOT/core/ai" "$(d brain 'claude-code')"
ask AI_MODEL "Model for $BRAIN_NAME" "$(d ai_model "$AI_MODEL_DEFAULT")"
choose_runtime "$ROOT/core/runtimes" "$(d runtime 'github-actions')"

if [[ -n "$QA_COMMAND" ]]; then
  QA_NOTE="Quick check only: run \`$QA_COMMAND\` and fix what it flags. Do NOT run the full test suite or heavy tooling in this runner — that happens in the PR's CI."
else
  QA_NOTE="Do not run tests or heavy QA in this runner — the PR's CI handles that. A quick syntax sanity check of the files you changed is fine."
fi

repo_slug=$(basename "$TARGET" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
WORKER_NAME="$(d worker_name "${repo_slug}-shortcut-relay")"

say "Summary"
cat <<EOF
  Target repo        $TARGET
  GitHub repo        $GITHUB_REPO
  Analyze state      $STATE_ANALYZE
  Implement state    $STATE_IMPLEMENT
  Agent              $AGENT_MARKER · brain $BRAIN_NAME · model $AI_MODEL · runtime $RUNTIME_NAME
  Branches           $BRANCH_PREFIX/<slug> → PRs into $PR_BASE
  Quick QA           ${QA_COMMAND:-none (PR CI only)}
  Relay worker       $WORKER_NAME
EOF
confirm "Install into $TARGET?" || { echo "aborted — nothing written"; exit 1; }

say "Installing files"
RENDER_VARS="GITHUB_REPO HANDLERS STATE_ANALYZE STATE_IMPLEMENT AGENT_NAME AGENT_MARKER PROJECT_NAME AUDIENCE STACK_NOTE BRANCH_PREFIX PR_BASE QA_NOTE BRAIN_NAME AI_MODEL WORKER_NAME"

(cd "$FILES" && find . -type f ! -name '.DS_Store' | sed 's#^\./##') | while IFS= read -r rel; do
  src="$FILES/$rel"
  case "$rel" in
    *.tmpl) dest="$TARGET/${rel%.tmpl}"; render "$src" "$dest" ;;
    *) dest="$TARGET/$rel"; mkdir -p "$(dirname "$dest")"; cp "$src" "$dest" ;;
  esac
  echo "  + ${dest#"$TARGET/"}"
done

install -m 0755 "$ROOT/core/state/git-branch.sh" "$AGENT_DIR/state.sh"
echo "  + scripts/shortcut-agent/state.sh  (core/state/git-branch.sh)"
mkdir -p "$AGENT_DIR/ai"
install -m 0644 "$BRAIN_FILE" "$AGENT_DIR/ai/brain.sh"
echo "  + scripts/shortcut-agent/ai/brain.sh  ($BRAIN_NAME)"
chmod +x "$AGENT_DIR"/*.sh
runtime_render_ci "$RUNTIME_NAME" "$ROOT/core/runtimes" "$AGENT_DIR" "scripts/shortcut-agent"

jq -n \
  --arg runtime "$RUNTIME_NAME" \
  --arg github_repo "$GITHUB_REPO" --arg state_analyze "$STATE_ANALYZE" \
  --arg state_implement "$STATE_IMPLEMENT" --arg agent_name "$AGENT_NAME" \
  --arg project_name "$PROJECT_NAME" --arg audience "$AUDIENCE" \
  --arg stack_note "$STACK_NOTE" --arg branch_prefix "$BRANCH_PREFIX" \
  --arg pr_base "$PR_BASE" --arg qa_command "$QA_COMMAND" \
  --arg brain "$BRAIN_NAME" --arg ai_model "$AI_MODEL" --arg worker_name "$WORKER_NAME" \
  '{recipe: "shortcut/project-agent", runtime: $runtime, brain: $brain,
    handlers: "stories", github_repo: $github_repo, state_analyze: $state_analyze,
    state_implement: $state_implement, agent_name: $agent_name,
    project_name: $project_name, audience: $audience, stack_note: $stack_note,
    branch_prefix: $branch_prefix, pr_base: $pr_base, qa_command: $qa_command,
    ai_model: $ai_model, worker_name: $worker_name}' > "$CONFIG"
echo "  + scripts/shortcut-agent/automation.config.json"

render_check "$AGENT_DIR" "$TARGET/.github/workflows/shortcut-agent.yml" || true

say "GitHub secrets"
note "Required on $GITHUB_REPO:"
note "  SHORTCUT_TOKEN — Shortcut → Settings → API Tokens"
note "  $BRAIN_AUTH_VARS — auth for the $BRAIN_NAME brain"
if [[ "$RUNTIME_NAME" == "github-actions" ]]; then
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if confirm "Set secrets on $GITHUB_REPO now with gh?"; then
      for s in SHORTCUT_TOKEN $BRAIN_AUTH_VARS AGENT_GH_PAT; do
        if confirm "  set $s?"; then gh secret set "$s" -R "$GITHUB_REPO"; fi
      done
    fi
  else
    note "gh CLI not available/authenticated — set the secrets manually at:"
    note "  https://github.com/$GITHUB_REPO/settings/secrets/actions"
  fi
fi

say "Next steps (in order)"
cat <<EOF
1. Secrets (if any were skipped above) — see the list just printed.
   AGENT_GH_PAT (optional, classic PAT with 'repo' scope) makes agent PRs
   trigger CI automatically instead of waiting for manual approval.

2. Repo setting: Settings → Actions → General →
   check "Allow GitHub Actions to create and approve pull requests".

3. Deploy the relay (free Cloudflare account; npm i -g wrangler):
     cd $AGENT_DIR/relay
     wrangler deploy
     wrangler secret put GITHUB_PAT   # fine-grained PAT: only $GITHUB_REPO, contents: read+write
     wrangler secret put SHORTCUT_WEBHOOK_SECRET   # pick a value, e.g. \`openssl rand -hex 24\`
     # keep that value handy — the webhook form in step 4 asks for the SAME string

4. Create the outgoing webhook (Shortcut → Settings → API → Webhooks → Add):
     URL:     https://$WORKER_NAME.<your-cf-subdomain>.workers.dev/hook
     Secret:  the SHORTCUT_WEBHOOK_SECRET value from step 3
   (with a secret set, Shortcut signs every delivery via Payload-Signature —
   the relay rejects unsigned deliveries)

5. Commit the new files in $TARGET and merge them to the default branch
   (repository_dispatch only triggers workflows on the default branch).

6. Safe local test — no comments, no AI, no state pushed
   (export SHORTCUT_TOKEN first):
     cd $TARGET && DRY_RUN=1 bash scripts/shortcut-agent/agent-run.sh

Operating docs (recovery, pausing, transcripts): scripts/shortcut-agent/README.md
EOF
runtime_overlay "$RUNTIME_NAME" "scripts/shortcut-agent" "$WORKER_NAME" "$BRAIN_AUTH_VARS" "SHORTCUT_TOKEN"
