#!/usr/bin/env bash
# Interactive installer for the Notion Project Agent.
# Renders files/ (+ core adapters) into a target repository.
set -euo pipefail

RECIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$RECIPE_DIR/../../.." && pwd)"
FILES="$RECIPE_DIR/files"
source "$ROOT/core/lib/wizard.sh"
source "$ROOT/core/lib/render.sh"
source "$ROOT/core/lib/brains.sh"

need git jq curl

say "Notion Project Agent — setup"
cat <<'EOF'
Installs an event-driven AI agent into one of YOUR repositories:

  Notion webhook (HMAC-verified) → Cloudflare Worker relay → GitHub Actions → headless Claude Code

Flow: page enters your ANALYZE status → the agent posts options/questions as
a page comment; discuss in comments; move it to your IMPLEMENT status → it
builds the change and opens a ready-for-review PR. It never changes
properties — humans own the board.

You'll need: a GitHub repo, a Notion internal integration
(notion.so/profile/integrations — enable Read + Insert comment capabilities,
and connect your database to it), a free Cloudflare account, and Claude auth.

Finding the database id: the 32-hex string in the database URL
(notion.so/<workspace>/<database_id>?v=...).
EOF

say "Target repository"
ask TARGET_IN "Path to the repository the agent should work in"
TARGET_IN="${TARGET_IN/#\~/$HOME}"
TARGET="$(cd "$TARGET_IN" 2>/dev/null && pwd)" || { echo "error: no such directory: $TARGET_IN" >&2; exit 1; }
[[ -d "$TARGET/.git" ]] || { echo "error: not a git repository: $TARGET" >&2; exit 1; }

AGENT_DIR="$TARGET/scripts/notion-agent"
CONFIG="$AGENT_DIR/automation.config.json"
cfg() { jq -r ".$1 // empty" "$CONFIG" 2>/dev/null || true; }
d() { local v; v="$(cfg "$1")"; printf '%s' "${v:-$2}"; }
[[ -f "$CONFIG" ]] && note "(existing install found — answers default to your previous choices)"

origin_url=$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)
guess_repo=$(printf '%s' "$origin_url" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
ask GITHUB_REPO "GitHub repo (owner/name)" "$(d github_repo "$guess_repo")"

say "Notion"
ask NOTION_DATABASE_ID "Database ID to watch" "$(d notion_database_id '')"
ask STATUS_PROP "Status property name" "$(d status_prop 'Status')"
ask STATUS_ANALYZE "Status the agent ANALYZES pages in" "$(d status_analyze 'In progress')"
ask STATUS_IMPLEMENT "Status the agent IMPLEMENTS pages from" "$(d status_implement 'Ready to build')"
HANDLERS="pages"

say "Conventions"
ask AGENT_NAME "Agent display name (signs every comment)" "$(d agent_name 'Project Agent')"
AGENT_MARKER="🤖 $AGENT_NAME"
ask PROJECT_NAME "Product name used in comments" "$(d project_name "$(basename "$TARGET")")"
ask AUDIENCE "Who reads this database? (comments are written for them)" "$(d audience 'the team')"
ask STACK_NOTE "One-line stack note for the agent" "$(d stack_note 'follow the conventions in CLAUDE.md / README')"
ask BRANCH_PREFIX "Branch prefix for agent branches" "$(d branch_prefix 'ai-agent')"
default_base="$(git -C "$TARGET" symbolic-ref --short HEAD 2>/dev/null || echo main)"
ask PR_BASE "Base branch for agent PRs" "$(d pr_base "$default_base")"
ask_opt QA_COMMAND "Quick QA command before a PR (e.g. 'npm run lint')" "$(d qa_command '')"
choose_brain "$ROOT/core/ai" "$(d brain 'claude-code')"
ask AI_MODEL "Model for $BRAIN_NAME" "$(d ai_model "$AI_MODEL_DEFAULT")"

if [[ -n "$QA_COMMAND" ]]; then
  QA_NOTE="Quick check only: run \`$QA_COMMAND\` and fix what it flags. Do NOT run the full test suite or heavy tooling in this runner — that happens in the PR's CI."
else
  QA_NOTE="Do not run tests or heavy QA in this runner — the PR's CI handles that. A quick syntax sanity check of the files you changed is fine."
fi

repo_slug=$(basename "$TARGET" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
WORKER_NAME="$(d worker_name "${repo_slug}-notion-relay")"

say "Summary"
cat <<EOF
  Target repo        $TARGET
  GitHub repo        $GITHUB_REPO
  Notion database    $NOTION_DATABASE_ID
  Status property    $STATUS_PROP
  Analyze status     $STATUS_ANALYZE
  Implement status   $STATUS_IMPLEMENT
  Agent              $AGENT_MARKER · brain $BRAIN_NAME · model $AI_MODEL
  Branches           $BRANCH_PREFIX/<slug> → PRs into $PR_BASE
  Quick QA           ${QA_COMMAND:-none (PR CI only)}
  Relay worker       $WORKER_NAME
EOF
confirm "Install into $TARGET?" || { echo "aborted — nothing written"; exit 1; }

say "Installing files"
RENDER_VARS="GITHUB_REPO HANDLERS NOTION_DATABASE_ID STATUS_PROP STATUS_ANALYZE STATUS_IMPLEMENT AGENT_NAME AGENT_MARKER PROJECT_NAME AUDIENCE STACK_NOTE BRANCH_PREFIX PR_BASE QA_NOTE BRAIN_NAME AI_MODEL WORKER_NAME"

(cd "$FILES" && find . -type f ! -name '.DS_Store' | sed 's#^\./##') | while IFS= read -r rel; do
  src="$FILES/$rel"
  case "$rel" in
    *.tmpl) dest="$TARGET/${rel%.tmpl}"; render "$src" "$dest" ;;
    *) dest="$TARGET/$rel"; mkdir -p "$(dirname "$dest")"; cp "$src" "$dest" ;;
  esac
  echo "  + ${dest#"$TARGET/"}"
done

install -m 0755 "$ROOT/core/state/git-branch.sh" "$AGENT_DIR/state.sh"
echo "  + scripts/notion-agent/state.sh  (core/state/git-branch.sh)"
mkdir -p "$AGENT_DIR/ai"
install -m 0644 "$BRAIN_FILE" "$AGENT_DIR/ai/brain.sh"
echo "  + scripts/notion-agent/ai/brain.sh  ($BRAIN_NAME)"
chmod +x "$AGENT_DIR"/*.sh

jq -n \
  --arg github_repo "$GITHUB_REPO" --arg notion_database_id "$NOTION_DATABASE_ID" \
  --arg status_prop "$STATUS_PROP" --arg status_analyze "$STATUS_ANALYZE" \
  --arg status_implement "$STATUS_IMPLEMENT" --arg agent_name "$AGENT_NAME" \
  --arg project_name "$PROJECT_NAME" --arg audience "$AUDIENCE" \
  --arg stack_note "$STACK_NOTE" --arg branch_prefix "$BRANCH_PREFIX" \
  --arg pr_base "$PR_BASE" --arg qa_command "$QA_COMMAND" \
  --arg brain "$BRAIN_NAME" --arg ai_model "$AI_MODEL" --arg worker_name "$WORKER_NAME" \
  '{recipe: "notion/project-agent", runtime: "github-actions", brain: $brain,
    handlers: "pages", github_repo: $github_repo, notion_database_id: $notion_database_id,
    status_prop: $status_prop, status_analyze: $status_analyze,
    status_implement: $status_implement, agent_name: $agent_name,
    project_name: $project_name, audience: $audience, stack_note: $stack_note,
    branch_prefix: $branch_prefix, pr_base: $pr_base, qa_command: $qa_command,
    ai_model: $ai_model, worker_name: $worker_name}' > "$CONFIG"
echo "  + scripts/notion-agent/automation.config.json"

render_check "$AGENT_DIR" || true

say "GitHub secrets"
note "Required on $GITHUB_REPO:"
note "  NOTION_TOKEN — the internal integration secret (notion.so/profile/integrations)"
note "  $BRAIN_AUTH_VARS — auth for the $BRAIN_NAME brain"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  if confirm "Set secrets on $GITHUB_REPO now with gh?"; then
    for s in NOTION_TOKEN $BRAIN_AUTH_VARS AGENT_GH_PAT; do
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

3. Notion integration checklist (notion.so/profile/integrations):
   - Capabilities: Read content + Read comments + Insert comments
   - Connect the database to the integration (database ••• → Connections)

4. Deploy the relay (free Cloudflare account; npm i -g wrangler):
     cd $AGENT_DIR/relay
     wrangler deploy
     wrangler secret put GITHUB_PAT   # fine-grained PAT: only $GITHUB_REPO, contents: read+write

5. Create the webhook subscription — TWO terminals:
     terminal A:  cd $AGENT_DIR/relay && wrangler tail
     terminal B:  integration settings → Webhooks → add endpoint:
                  https://$WORKER_NAME.<your-cf-subdomain>.workers.dev/hook
                  subscribe to: page.created, page.properties_updated,
                  page.moved, comment.created
     # terminal A prints "NOTION VERIFICATION TOKEN: <value>" —
     # paste it into the Notion UI to verify, then store it:
     wrangler secret put NOTION_VERIFICATION_TOKEN

6. Commit the new files in $TARGET and merge them to the default branch
   (repository_dispatch only triggers workflows on the default branch).

7. Safe local test — no comments, no AI, no state pushed
   (export NOTION_TOKEN first):
     cd $TARGET && DRY_RUN=1 bash scripts/notion-agent/agent-run.sh

Operating docs (recovery, pausing, transcripts): scripts/notion-agent/README.md
EOF
