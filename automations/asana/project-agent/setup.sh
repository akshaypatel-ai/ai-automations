#!/usr/bin/env bash
# Interactive installer for the Asana Project Agent.
# Renders files/ (+ core adapters) into a target repository.
set -euo pipefail

RECIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$RECIPE_DIR/../../.." && pwd)"
FILES="$RECIPE_DIR/files"
source "$ROOT/core/lib/wizard.sh"
source "$ROOT/core/lib/render.sh"

need git jq curl

say "Asana Project Agent — setup"
cat <<'EOF'
Installs an event-driven AI agent into one of YOUR repositories:

  Asana webhook (handshake + HMAC) → Cloudflare Worker relay → GitHub Actions → headless Claude Code

Flow: task enters your ANALYZE section → the agent posts options/questions;
discuss in comments; move it to your IMPLEMENT section → it builds the change
and opens a ready-for-review PR. It never moves tasks — humans own the board.

You'll need: a GitHub repo, an Asana personal access token
(Settings → Apps → Developer apps → Create token), a free Cloudflare account,
and Claude auth.

Finding the project gid: it's the long number in the project URL
(app.asana.com/0/<project_gid>/... or .../project/<project_gid>/...).
EOF

say "Target repository"
ask TARGET_IN "Path to the repository the agent should work in"
TARGET_IN="${TARGET_IN/#\~/$HOME}"
TARGET="$(cd "$TARGET_IN" 2>/dev/null && pwd)" || { echo "error: no such directory: $TARGET_IN" >&2; exit 1; }
[[ -d "$TARGET/.git" ]] || { echo "error: not a git repository: $TARGET" >&2; exit 1; }

AGENT_DIR="$TARGET/scripts/asana-agent"
CONFIG="$AGENT_DIR/automation.config.json"
cfg() { jq -r ".$1 // empty" "$CONFIG" 2>/dev/null || true; }
d() { local v; v="$(cfg "$1")"; printf '%s' "${v:-$2}"; }
[[ -f "$CONFIG" ]] && note "(existing install found — answers default to your previous choices)"

origin_url=$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)
guess_repo=$(printf '%s' "$origin_url" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
ask GITHUB_REPO "GitHub repo (owner/name)" "$(d github_repo "$guess_repo")"

say "Asana"
ask ASANA_PROJECT_GID "Project gid to watch" "$(d asana_project_gid '')"
ask SECTION_ANALYZE "Section the agent ANALYZES tasks in" "$(d section_analyze 'To do')"
ask SECTION_IMPLEMENT "Section the agent IMPLEMENTS tasks from" "$(d section_implement 'In progress')"
HANDLERS="tasks"

say "Conventions"
ask AGENT_NAME "Agent display name (signs every comment)" "$(d agent_name 'Project Agent')"
AGENT_MARKER="🤖 $AGENT_NAME"
ask PROJECT_NAME "Product name used in comments" "$(d project_name "$(basename "$TARGET")")"
ask AUDIENCE "Who reads these tasks? (comments are written for them)" "$(d audience 'the team')"
ask STACK_NOTE "One-line stack note for the agent" "$(d stack_note 'follow the conventions in CLAUDE.md / README')"
ask BRANCH_PREFIX "Branch prefix for agent branches" "$(d branch_prefix 'ai-agent')"
default_base="$(git -C "$TARGET" symbolic-ref --short HEAD 2>/dev/null || echo main)"
ask PR_BASE "Base branch for agent PRs" "$(d pr_base "$default_base")"
ask_opt QA_COMMAND "Quick QA command before a PR (e.g. 'npm run lint')" "$(d qa_command '')"
ask CLAUDE_MODEL "Claude model" "$(d claude_model 'claude-sonnet-5')"

if [[ -n "$QA_COMMAND" ]]; then
  QA_NOTE="Quick check only: run \`$QA_COMMAND\` and fix what it flags. Do NOT run the full test suite or heavy tooling in this runner — that happens in the PR's CI."
else
  QA_NOTE="Do not run tests or heavy QA in this runner — the PR's CI handles that. A quick syntax sanity check of the files you changed is fine."
fi

repo_slug=$(basename "$TARGET" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
WORKER_NAME="$(d worker_name "${repo_slug}-asana-relay")"

say "Summary"
cat <<EOF
  Target repo        $TARGET
  GitHub repo        $GITHUB_REPO
  Asana project      $ASANA_PROJECT_GID
  Analyze section    $SECTION_ANALYZE
  Implement section  $SECTION_IMPLEMENT
  Agent              $AGENT_MARKER · brain claude-code · model $CLAUDE_MODEL
  Branches           $BRANCH_PREFIX/<slug> → PRs into $PR_BASE
  Quick QA           ${QA_COMMAND:-none (PR CI only)}
  Relay worker       $WORKER_NAME
EOF
confirm "Install into $TARGET?" || { echo "aborted — nothing written"; exit 1; }

say "Installing files"
RENDER_VARS="GITHUB_REPO HANDLERS ASANA_PROJECT_GID SECTION_ANALYZE SECTION_IMPLEMENT AGENT_NAME AGENT_MARKER PROJECT_NAME AUDIENCE STACK_NOTE BRANCH_PREFIX PR_BASE QA_NOTE CLAUDE_MODEL WORKER_NAME"

(cd "$FILES" && find . -type f ! -name '.DS_Store' | sed 's#^\./##') | while IFS= read -r rel; do
  src="$FILES/$rel"
  case "$rel" in
    *.tmpl) dest="$TARGET/${rel%.tmpl}"; render "$src" "$dest" ;;
    *) dest="$TARGET/$rel"; mkdir -p "$(dirname "$dest")"; cp "$src" "$dest" ;;
  esac
  echo "  + ${dest#"$TARGET/"}"
done

install -m 0755 "$ROOT/core/state/git-branch.sh" "$AGENT_DIR/state.sh"
echo "  + scripts/asana-agent/state.sh  (core/state/git-branch.sh)"
mkdir -p "$AGENT_DIR/ai"
install -m 0644 "$ROOT/core/ai/claude-code.sh" "$AGENT_DIR/ai/brain.sh"
echo "  + scripts/asana-agent/ai/brain.sh  (core/ai/claude-code.sh)"
chmod +x "$AGENT_DIR"/*.sh

jq -n \
  --arg github_repo "$GITHUB_REPO" --arg asana_project_gid "$ASANA_PROJECT_GID" \
  --arg section_analyze "$SECTION_ANALYZE" --arg section_implement "$SECTION_IMPLEMENT" \
  --arg agent_name "$AGENT_NAME" --arg project_name "$PROJECT_NAME" \
  --arg audience "$AUDIENCE" --arg stack_note "$STACK_NOTE" \
  --arg branch_prefix "$BRANCH_PREFIX" --arg pr_base "$PR_BASE" \
  --arg qa_command "$QA_COMMAND" --arg claude_model "$CLAUDE_MODEL" \
  --arg worker_name "$WORKER_NAME" \
  '{recipe: "asana/project-agent", runtime: "github-actions", brain: "claude-code",
    handlers: "tasks", github_repo: $github_repo, asana_project_gid: $asana_project_gid,
    section_analyze: $section_analyze, section_implement: $section_implement,
    agent_name: $agent_name, project_name: $project_name, audience: $audience,
    stack_note: $stack_note, branch_prefix: $branch_prefix, pr_base: $pr_base,
    qa_command: $qa_command, claude_model: $claude_model, worker_name: $worker_name}' > "$CONFIG"
echo "  + scripts/asana-agent/automation.config.json"

render_check "$AGENT_DIR" || true

say "GitHub secrets"
note "Required on $GITHUB_REPO:"
note "  ASANA_TOKEN — Asana → Settings → Apps → Developer apps → Create token"
note "  CLAUDE_CODE_OAUTH_TOKEN — 'claude setup-token' (subscription) OR ANTHROPIC_API_KEY (pay-per-token)"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  if confirm "Set secrets on $GITHUB_REPO now with gh?"; then
    for s in ASANA_TOKEN CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY AGENT_GH_PAT; do
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
   AGENT_GH_PAT (optional, classic PAT with 'repo' scope) makes agent PRs
   trigger CI automatically instead of waiting for manual approval.

2. Repo setting: Settings → Actions → General →
   check "Allow GitHub Actions to create and approve pull requests".

3. Deploy the relay (free Cloudflare account; npm i -g wrangler):
     cd $AGENT_DIR/relay
     wrangler deploy
     wrangler secret put GITHUB_PAT   # fine-grained PAT: only $GITHUB_REPO, contents: read+write

4. Create the webhook — TWO terminals (Asana's handshake sends the secret to
   the relay, which logs it):
     terminal A:  cd $AGENT_DIR/relay && wrangler tail
     terminal B:  curl -X POST "https://app.asana.com/api/1.0/webhooks" \\
       -H "Authorization: Bearer <ASANA_TOKEN>" -H "Content-Type: application/json" \\
       -d '{"data": {"resource": "$ASANA_PROJECT_GID",
            "target": "https://$WORKER_NAME.<your-cf-subdomain>.workers.dev/hook"}}'
     # terminal A prints "ASANA HOOK SECRET: <value>" — store it immediately:
     wrangler secret put ASANA_HOOK_SECRET

5. Commit the new files in $TARGET and merge them to the default branch
   (repository_dispatch only triggers workflows on the default branch).

6. Safe local test — no comments, no AI, no state pushed
   (export ASANA_TOKEN first):
     cd $TARGET && DRY_RUN=1 bash scripts/asana-agent/agent-run.sh

Operating docs (recovery, pausing, transcripts): scripts/asana-agent/README.md
EOF
