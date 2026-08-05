#!/usr/bin/env bash
# Interactive installer for the Basecamp Project Agent.
# Renders files/ (+ core adapters) into a target repository.
set -euo pipefail

RECIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$RECIPE_DIR/../../.." && pwd)"
FILES="$RECIPE_DIR/files"
source "$ROOT/core/lib/wizard.sh"
source "$ROOT/core/lib/render.sh"

need git jq

say "Basecamp Project Agent — setup"
cat <<'EOF'
Installs an event-driven AI agent into one of YOUR repositories:

  Basecamp webhook → Cloudflare Worker relay → GitHub Actions → headless Claude Code

It can attach to EVERY Basecamp event stream, via toggleable handlers:

  cards      card table: analyze → discuss → implement approved cards as PRs
  todos      to-dos: answer/discuss, and build explicitly requested changes as PRs
  messages   message board: answer questions addressed to the agent (else silent)
  docs       Docs & Files: review specs/uploads against the real code when asked
  checkins   automatic check-in answers: respond when directly asked something
  schedule   calendar entries: meeting prep notes when requested

You'll need: a GitHub repo, Basecamp access, a free Cloudflare account, and a
Claude subscription token or Anthropic API key.

Where to find Basecamp IDs — open your card table in the browser:
  https://3.basecamp.com/<ACCOUNT_ID>/buckets/<PROJECT_ID>/card_tables/<CARD_TABLE_ID>
Column IDs: open a column (click its title) and copy the number from the URL:
  .../card_tables/lists/<COLUMN_ID>
Todolist IDs: open the list — .../buckets/<PROJECT_ID>/todolists/<TODOLIST_ID>
EOF

say "Target repository"
ask TARGET_IN "Path to the repository the agent should work in"
TARGET_IN="${TARGET_IN/#\~/$HOME}"
TARGET="$(cd "$TARGET_IN" 2>/dev/null && pwd)" || { echo "error: no such directory: $TARGET_IN" >&2; exit 1; }
[[ -d "$TARGET/.git" ]] || { echo "error: not a git repository: $TARGET" >&2; exit 1; }

AGENT_DIR="$TARGET/scripts/basecamp-agent"
CONFIG="$AGENT_DIR/automation.config.json"
cfg() { jq -r ".$1 // empty" "$CONFIG" 2>/dev/null || true; }
# d <config_key> <fallback> — previous install's answer wins over the guess.
d() { local v; v="$(cfg "$1")"; printf '%s' "${v:-$2}"; }
[[ -f "$CONFIG" ]] && note "(existing install found — answers default to your previous choices)"

origin_url=$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)
guess_repo=$(printf '%s' "$origin_url" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
ask GITHUB_REPO "GitHub repo (owner/name)" "$(d github_repo "$guess_repo")"

say "Event handlers"
while :; do
  ask HANDLERS "Handlers to enable (comma-separated: cards,todos,messages,docs,checkins,schedule)" "$(d handlers 'cards,todos,messages')"
  HANDLERS=$(printf '%s' "$HANDLERS" | tr -d ' ')
  bad=""
  for h in $(printf '%s' "$HANDLERS" | tr ',' ' '); do
    case "$h" in cards|todos|messages|docs|checkins|schedule) ;; *) bad="$h" ;; esac
  done
  [[ -z "$bad" && -n "$HANDLERS" ]] && break
  echo "  unknown handler: '${bad:-<empty>}' — valid: cards,todos,messages,docs,checkins,schedule"
done
has() { [[ ",$HANDLERS," == *",$1,"* ]]; }

say "Basecamp"
ask BC_ACCOUNT_ID "Basecamp account ID" "$(d bc_account_id '')"
ask BC_PROJECT_ID "Project ID" "$(d bc_project_id '')"
if has cards; then
  ask BC_CARD_TABLE_ID "Card table ID" "$(d bc_card_table_id '')"
  ask BC_COL_ANALYZE "Column ID the agent ANALYZES cards in" "$(d bc_col_analyze '')"
  ask COL_ANALYZE_NAME "  that column's display name" "$(d col_analyze_name 'Figuring it out')"
  ask BC_COL_IMPLEMENT "Column ID the agent IMPLEMENTS cards from" "$(d bc_col_implement '')"
  ask COL_IMPLEMENT_NAME "  that column's display name" "$(d col_implement_name 'In Progress')"
else
  BC_CARD_TABLE_ID=""; BC_COL_ANALYZE=""; COL_ANALYZE_NAME="-"; BC_COL_IMPLEMENT=""; COL_IMPLEMENT_NAME="-"
fi
if has todos; then
  ask_opt BC_TODOLIST_ID "Todolist ID to watch (Enter = all to-dos in the project)" "$(d bc_todolist_id '')"
else
  BC_TODOLIST_ID=""
fi

say "Conventions"
ask AGENT_NAME "Agent display name (signs every comment)" "$(d agent_name 'Project Agent')"
AGENT_MARKER="🤖 $AGENT_NAME"
ask PROJECT_NAME "Product name used in comments" "$(d project_name "$(basename "$TARGET")")"
ask AUDIENCE "Who reads this Basecamp project? (comments are written for them)" "$(d audience 'the team')"
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
WORKER_NAME="$(d worker_name "${repo_slug}-basecamp-relay")"

# Webhook event types follow the enabled handlers (Comment is always needed).
WEBHOOK_TYPES="Comment"
has cards    && WEBHOOK_TYPES="$WEBHOOK_TYPES,Kanban::Card"
has todos    && WEBHOOK_TYPES="$WEBHOOK_TYPES,Todo,Todolist"
has messages && WEBHOOK_TYPES="$WEBHOOK_TYPES,Message"
has docs     && WEBHOOK_TYPES="$WEBHOOK_TYPES,Document,Upload,Vault"
has checkins && WEBHOOK_TYPES="$WEBHOOK_TYPES,Question,Question::Answer"
has schedule && WEBHOOK_TYPES="$WEBHOOK_TYPES,Schedule::Entry"

say "Summary"
cat <<EOF
  Target repo        $TARGET
  GitHub repo        $GITHUB_REPO
  Handlers           $HANDLERS
  Webhook types      $WEBHOOK_TYPES
  Basecamp           account $BC_ACCOUNT_ID · project $BC_PROJECT_ID
EOF
if has cards; then
  cat <<EOF
  Card table         $BC_CARD_TABLE_ID
  Analyze column     $COL_ANALYZE_NAME ($BC_COL_ANALYZE)
  Implement column   $COL_IMPLEMENT_NAME ($BC_COL_IMPLEMENT)
EOF
fi
if has todos; then
  echo "  Todolist           ${BC_TODOLIST_ID:-all in project}"
fi
cat <<EOF
  Agent              $AGENT_MARKER · brain claude-code · model $CLAUDE_MODEL
  Branches           $BRANCH_PREFIX/<slug> → PRs into $PR_BASE
  Quick QA           ${QA_COMMAND:-none (PR CI only)}
  Relay worker       $WORKER_NAME
EOF
confirm "Install into $TARGET?" || { echo "aborted — nothing written"; exit 1; }

say "Installing files"
RENDER_VARS="GITHUB_REPO HANDLERS BC_ACCOUNT_ID BC_PROJECT_ID BC_CARD_TABLE_ID BC_COL_ANALYZE BC_COL_IMPLEMENT COL_ANALYZE_NAME COL_IMPLEMENT_NAME BC_TODOLIST_ID AGENT_NAME AGENT_MARKER PROJECT_NAME AUDIENCE STACK_NOTE BRANCH_PREFIX PR_BASE QA_NOTE CLAUDE_MODEL WORKER_NAME WEBHOOK_TYPES"

(cd "$FILES" && find . -type f ! -name '.DS_Store' | sed 's#^\./##') | while IFS= read -r rel; do
  src="$FILES/$rel"
  case "$rel" in
    *.tmpl)
      dest="$TARGET/${rel%.tmpl}"
      render "$src" "$dest"
      ;;
    *)
      dest="$TARGET/$rel"
      mkdir -p "$(dirname "$dest")"
      cp "$src" "$dest"
      ;;
  esac
  echo "  + ${dest#"$TARGET/"}"
done

install -m 0755 "$ROOT/core/state/git-branch.sh" "$AGENT_DIR/state.sh"
echo "  + scripts/basecamp-agent/state.sh  (core/state/git-branch.sh)"
mkdir -p "$AGENT_DIR/ai"
install -m 0644 "$ROOT/core/ai/claude-code.sh" "$AGENT_DIR/ai/brain.sh"
echo "  + scripts/basecamp-agent/ai/brain.sh  (core/ai/claude-code.sh)"
chmod +x "$AGENT_DIR"/*.sh

jq -n \
  --arg github_repo "$GITHUB_REPO" \
  --arg handlers "$HANDLERS" \
  --arg bc_account_id "$BC_ACCOUNT_ID" \
  --arg bc_project_id "$BC_PROJECT_ID" \
  --arg bc_card_table_id "$BC_CARD_TABLE_ID" \
  --arg bc_col_analyze "$BC_COL_ANALYZE" \
  --arg col_analyze_name "$COL_ANALYZE_NAME" \
  --arg bc_col_implement "$BC_COL_IMPLEMENT" \
  --arg col_implement_name "$COL_IMPLEMENT_NAME" \
  --arg bc_todolist_id "$BC_TODOLIST_ID" \
  --arg agent_name "$AGENT_NAME" \
  --arg project_name "$PROJECT_NAME" \
  --arg audience "$AUDIENCE" \
  --arg stack_note "$STACK_NOTE" \
  --arg branch_prefix "$BRANCH_PREFIX" \
  --arg pr_base "$PR_BASE" \
  --arg qa_command "$QA_COMMAND" \
  --arg claude_model "$CLAUDE_MODEL" \
  --arg worker_name "$WORKER_NAME" \
  '{recipe: "basecamp/project-agent", runtime: "github-actions", brain: "claude-code",
    github_repo: $github_repo, handlers: $handlers, bc_account_id: $bc_account_id,
    bc_project_id: $bc_project_id, bc_card_table_id: $bc_card_table_id,
    bc_col_analyze: $bc_col_analyze, col_analyze_name: $col_analyze_name,
    bc_col_implement: $bc_col_implement, col_implement_name: $col_implement_name,
    bc_todolist_id: $bc_todolist_id, agent_name: $agent_name,
    project_name: $project_name, audience: $audience, stack_note: $stack_note,
    branch_prefix: $branch_prefix, pr_base: $pr_base, qa_command: $qa_command,
    claude_model: $claude_model, worker_name: $worker_name}' > "$CONFIG"
echo "  + scripts/basecamp-agent/automation.config.json"

render_check "$AGENT_DIR" "$TARGET/.github/workflows/basecamp-agent.yml" || true

say "GitHub secrets"
note "The agent's brain needs ONE of these secrets on $GITHUB_REPO:"
note "  CLAUDE_CODE_OAUTH_TOKEN — run 'claude setup-token' locally (Claude Pro/Max subscription, no API billing)"
note "  ANTHROPIC_API_KEY       — pay-per-token (wins if both are set)"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  if confirm "Set secrets on $GITHUB_REPO now with gh?"; then
    for s in CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY AGENT_GH_PAT; do
      if confirm "  set $s?"; then gh secret set "$s" -R "$GITHUB_REPO"; fi
    done
    if [[ -f "$HOME/.config/basecamp/credentials.json" ]]; then
      if confirm "  set BASECAMP_CREDENTIALS_JSON from ~/.config/basecamp/credentials.json?"; then
        gh secret set BASECAMP_CREDENTIALS_JSON -R "$GITHUB_REPO" < "$HOME/.config/basecamp/credentials.json"
      fi
    else
      note "  No ~/.config/basecamp/credentials.json found. Create one (file-mode login), then set the secret:"
      note "    BASECAMP_NO_KEYRING=1 basecamp auth login"
      note "    gh secret set BASECAMP_CREDENTIALS_JSON -R $GITHUB_REPO < ~/.config/basecamp/credentials.json"
    fi
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
     wrangler secret put GITHUB_PAT       # fine-grained PAT: only $GITHUB_REPO, contents: read+write
     wrangler secret put WEBHOOK_SECRET   # e.g. openssl rand -hex 24 — keep it for step 4

4. Register the Basecamp webhook (same secret in the URL path):
     basecamp webhooks create "https://$WORKER_NAME.<your-cf-subdomain>.workers.dev/hook/<WEBHOOK_SECRET>" \\
       --types "$WEBHOOK_TYPES" --in $BC_PROJECT_ID

5. Commit the new files in $TARGET and merge them to the default branch
   (repository_dispatch only triggers workflows on the default branch).

6. Safe local test — no comments, no AI, no state pushed:
     cd $TARGET && DRY_RUN=1 bash scripts/basecamp-agent/agent-run.sh

Operating docs (recovery, pausing, transcripts): scripts/basecamp-agent/README.md
To change handlers later, just re-run this installer — answers are remembered.
EOF
