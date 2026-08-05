#!/usr/bin/env bash
# Interactive installer for the Trello Project Agent.
# Renders files/ (+ core adapters) into a target repository.
set -euo pipefail

RECIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$RECIPE_DIR/../../.." && pwd)"
FILES="$RECIPE_DIR/files"
source "$ROOT/core/lib/wizard.sh"
source "$ROOT/core/lib/render.sh"

need git jq curl

say "Trello Project Agent — setup"
cat <<'EOF'
Installs an event-driven AI agent into one of YOUR repositories:

  Trello webhook → Cloudflare Worker relay → GitHub Actions → headless Claude Code

Flow: card enters your ANALYZE list → the agent posts options/questions;
discuss in comments; move it to your IMPLEMENT list → it builds the change and
opens a ready-for-review PR. It never moves cards — humans own the board.

You'll need: a GitHub repo, a Trello API key + token
(https://trello.com/power-ups/admin → your Power-Up → API key), a free
Cloudflare account, and Claude auth.

Finding IDs: open your board and add ".json" to the URL — the board id is at
the top; list ids are under "lists". (Or: api.sh GET /1/boards/<id>/lists)
EOF

say "Target repository"
ask TARGET_IN "Path to the repository the agent should work in"
TARGET_IN="${TARGET_IN/#\~/$HOME}"
TARGET="$(cd "$TARGET_IN" 2>/dev/null && pwd)" || { echo "error: no such directory: $TARGET_IN" >&2; exit 1; }
[[ -d "$TARGET/.git" ]] || { echo "error: not a git repository: $TARGET" >&2; exit 1; }

AGENT_DIR="$TARGET/scripts/trello-agent"
CONFIG="$AGENT_DIR/automation.config.json"
cfg() { jq -r ".$1 // empty" "$CONFIG" 2>/dev/null || true; }
d() { local v; v="$(cfg "$1")"; printf '%s' "${v:-$2}"; }
[[ -f "$CONFIG" ]] && note "(existing install found — answers default to your previous choices)"

origin_url=$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)
guess_repo=$(printf '%s' "$origin_url" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
ask GITHUB_REPO "GitHub repo (owner/name)" "$(d github_repo "$guess_repo")"

say "Trello"
ask TRELLO_BOARD_ID "Board ID" "$(d trello_board_id '')"
ask LIST_ANALYZE_ID "List ID the agent ANALYZES cards in" "$(d list_analyze_id '')"
ask LIST_ANALYZE_NAME "  that list's display name" "$(d list_analyze_name 'To Do')"
ask LIST_IMPLEMENT_ID "List ID the agent IMPLEMENTS cards from" "$(d list_implement_id '')"
ask LIST_IMPLEMENT_NAME "  that list's display name" "$(d list_implement_name 'In Progress')"
HANDLERS="cards"

say "Conventions"
ask AGENT_NAME "Agent display name (signs every comment)" "$(d agent_name 'Project Agent')"
AGENT_MARKER="🤖 $AGENT_NAME"
ask PROJECT_NAME "Product name used in comments" "$(d project_name "$(basename "$TARGET")")"
ask AUDIENCE "Who reads this board? (comments are written for them)" "$(d audience 'the team')"
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
WORKER_NAME="$(d worker_name "${repo_slug}-trello-relay")"

say "Summary"
cat <<EOF
  Target repo        $TARGET
  GitHub repo        $GITHUB_REPO
  Board              $TRELLO_BOARD_ID
  Analyze list       $LIST_ANALYZE_NAME ($LIST_ANALYZE_ID)
  Implement list     $LIST_IMPLEMENT_NAME ($LIST_IMPLEMENT_ID)
  Agent              $AGENT_MARKER · brain claude-code · model $CLAUDE_MODEL
  Branches           $BRANCH_PREFIX/<slug> → PRs into $PR_BASE
  Quick QA           ${QA_COMMAND:-none (PR CI only)}
  Relay worker       $WORKER_NAME
EOF
confirm "Install into $TARGET?" || { echo "aborted — nothing written"; exit 1; }

say "Installing files"
RENDER_VARS="GITHUB_REPO HANDLERS TRELLO_BOARD_ID LIST_ANALYZE_ID LIST_ANALYZE_NAME LIST_IMPLEMENT_ID LIST_IMPLEMENT_NAME AGENT_NAME AGENT_MARKER PROJECT_NAME AUDIENCE STACK_NOTE BRANCH_PREFIX PR_BASE QA_NOTE CLAUDE_MODEL WORKER_NAME"

(cd "$FILES" && find . -type f ! -name '.DS_Store' | sed 's#^\./##') | while IFS= read -r rel; do
  src="$FILES/$rel"
  case "$rel" in
    *.tmpl) dest="$TARGET/${rel%.tmpl}"; render "$src" "$dest" ;;
    *) dest="$TARGET/$rel"; mkdir -p "$(dirname "$dest")"; cp "$src" "$dest" ;;
  esac
  echo "  + ${dest#"$TARGET/"}"
done

install -m 0755 "$ROOT/core/state/git-branch.sh" "$AGENT_DIR/state.sh"
echo "  + scripts/trello-agent/state.sh  (core/state/git-branch.sh)"
mkdir -p "$AGENT_DIR/ai"
install -m 0644 "$ROOT/core/ai/claude-code.sh" "$AGENT_DIR/ai/brain.sh"
echo "  + scripts/trello-agent/ai/brain.sh  (core/ai/claude-code.sh)"
chmod +x "$AGENT_DIR"/*.sh

jq -n \
  --arg github_repo "$GITHUB_REPO" --arg trello_board_id "$TRELLO_BOARD_ID" \
  --arg list_analyze_id "$LIST_ANALYZE_ID" --arg list_analyze_name "$LIST_ANALYZE_NAME" \
  --arg list_implement_id "$LIST_IMPLEMENT_ID" --arg list_implement_name "$LIST_IMPLEMENT_NAME" \
  --arg agent_name "$AGENT_NAME" --arg project_name "$PROJECT_NAME" \
  --arg audience "$AUDIENCE" --arg stack_note "$STACK_NOTE" \
  --arg branch_prefix "$BRANCH_PREFIX" --arg pr_base "$PR_BASE" \
  --arg qa_command "$QA_COMMAND" --arg claude_model "$CLAUDE_MODEL" \
  --arg worker_name "$WORKER_NAME" \
  '{recipe: "trello/project-agent", runtime: "github-actions", brain: "claude-code",
    handlers: "cards", github_repo: $github_repo, trello_board_id: $trello_board_id,
    list_analyze_id: $list_analyze_id, list_analyze_name: $list_analyze_name,
    list_implement_id: $list_implement_id, list_implement_name: $list_implement_name,
    agent_name: $agent_name, project_name: $project_name, audience: $audience,
    stack_note: $stack_note, branch_prefix: $branch_prefix, pr_base: $pr_base,
    qa_command: $qa_command, claude_model: $claude_model, worker_name: $worker_name}' > "$CONFIG"
echo "  + scripts/trello-agent/automation.config.json"

render_check "$AGENT_DIR" "$TARGET/.github/workflows/trello-agent.yml" || true

say "GitHub secrets"
note "Required on $GITHUB_REPO:"
note "  TRELLO_KEY + TRELLO_TOKEN — trello.com/power-ups/admin → API key, then generate a token"
note "  CLAUDE_CODE_OAUTH_TOKEN — 'claude setup-token' (subscription) OR ANTHROPIC_API_KEY (pay-per-token)"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  if confirm "Set secrets on $GITHUB_REPO now with gh?"; then
    for s in TRELLO_KEY TRELLO_TOKEN CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY AGENT_GH_PAT; do
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
     wrangler secret put GITHUB_PAT         # fine-grained PAT: only $GITHUB_REPO, contents: read+write
     wrangler secret put WEBHOOK_SECRET     # e.g. openssl rand -hex 24 — keep it for step 4
     wrangler secret put TRELLO_API_SECRET  # optional: your API secret, enables signature verification

4. Create the webhook (the relay answers Trello's HEAD probe automatically):
     curl -X POST "https://api.trello.com/1/webhooks?key=<TRELLO_KEY>&token=<TRELLO_TOKEN>" \\
       -d "idModel=$TRELLO_BOARD_ID" \\
       -d "description=ai-automations trello agent" \\
       -d "callbackURL=https://$WORKER_NAME.<your-cf-subdomain>.workers.dev/hook/<WEBHOOK_SECRET>"

5. Commit the new files in $TARGET and merge them to the default branch
   (repository_dispatch only triggers workflows on the default branch).

6. Safe local test — no comments, no AI, no state pushed
   (export TRELLO_KEY + TRELLO_TOKEN first):
     cd $TARGET && DRY_RUN=1 bash scripts/trello-agent/agent-run.sh

Operating docs (recovery, pausing, transcripts): scripts/trello-agent/README.md
EOF
