#!/usr/bin/env bash
# Interactive installer for the Airtable Project Agent.
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

say "Airtable Project Agent — setup"
cat <<'EOF'
Installs an event-driven AI agent into one of YOUR repositories:

  Airtable webhook ping (MAC-verified) → Cloudflare Worker relay → GitHub Actions → headless Claude Code

Flow: a record's status field enters your ANALYZE option → the agent posts
options/questions as a record comment; discuss in comments; set it to your
IMPLEMENT option → it builds the change and opens a ready-for-review PR. It
never changes record fields — humans own the board.

Airtable's webhook notifications are thin pings with no change details; the
doorbell pattern collapses that two-step protocol into a ping — every verified
ping becomes a reconcile run that finds whatever changed.

You'll need: a GitHub repo, an Airtable personal access token
(airtable.com/create/tokens), a free Cloudflare account, and Claude auth.

Finding IDs: open the table in your browser — the URL reads
airtable.com/app…/tbl…/viw…; the app… segment is the base id, tbl… the
table id (prefer the tbl… id over the table name — renames won't break it).
EOF

say "Target repository"
ask TARGET_IN "Path to the repository the agent should work in"
TARGET_IN="${TARGET_IN/#\~/$HOME}"
TARGET="$(cd "$TARGET_IN" 2>/dev/null && pwd)" || { echo "error: no such directory: $TARGET_IN" >&2; exit 1; }
[[ -d "$TARGET/.git" ]] || { echo "error: not a git repository: $TARGET" >&2; exit 1; }

AGENT_DIR="$TARGET/scripts/airtable-agent"
CONFIG="$AGENT_DIR/automation.config.json"
cfg() { jq -r ".$1 // empty" "$CONFIG" 2>/dev/null || true; }
d() { local v; v="$(cfg "$1")"; printf '%s' "${v:-$2}"; }
[[ -f "$CONFIG" ]] && note "(existing install found — answers default to your previous choices)"

origin_url=$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)
guess_repo=$(printf '%s' "$origin_url" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
ask GITHUB_REPO "GitHub repo (owner/name)" "$(d github_repo "$guess_repo")"

say "Airtable"
ask AIRTABLE_BASE_ID "Base ID (the app… segment of the base URL)" "$(d airtable_base_id '')"
ask AIRTABLE_TABLE_ID "Table ID to watch (the tbl… segment of the URL)" "$(d airtable_table_id '')"
ask STATUS_FIELD "Status field NAME (single select or status field)" "$(d status_field 'Status')"
ask TITLE_FIELD "Title field NAME (the record's primary field)" "$(d title_field 'Name')"
ask STATUS_ANALYZE "Option the agent ANALYZES records in" "$(d status_analyze 'Todo')"
ask STATUS_IMPLEMENT "Option the agent IMPLEMENTS records from" "$(d status_implement 'In progress')"
# The webhook usually doesn't exist yet at install time — created in step 4
# below; re-run this installer (or edit env.sh) once you have the ach… id.
ask_opt AIRTABLE_WEBHOOK_ID "Webhook ID if already created (ach…)" "$(d airtable_webhook_id '')"
HANDLERS="records"

say "Conventions"
ask AGENT_NAME "Agent display name (signs every comment)" "$(d agent_name 'Project Agent')"
AGENT_MARKER="🤖 $AGENT_NAME"
ask PROJECT_NAME "Product name used in comments" "$(d project_name "$(basename "$TARGET")")"
ask AUDIENCE "Who reads these records? (comments are written for them)" "$(d audience 'the team')"
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
WORKER_NAME="$(d worker_name "${repo_slug}-airtable-relay")"

say "Summary"
cat <<EOF
  Target repo        $TARGET
  GitHub repo        $GITHUB_REPO
  Airtable           base $AIRTABLE_BASE_ID · table $AIRTABLE_TABLE_ID · field "$STATUS_FIELD"
  Analyze option     $STATUS_ANALYZE
  Implement option   $STATUS_IMPLEMENT
  Webhook            ${AIRTABLE_WEBHOOK_ID:-not created yet (step 4 below)}
  Agent              $AGENT_MARKER · brain $BRAIN_NAME · model $AI_MODEL · runtime $RUNTIME_NAME
  Branches           $BRANCH_PREFIX/<slug> → PRs into $PR_BASE
  Quick QA           ${QA_COMMAND:-none (PR CI only)}
  Relay worker       $WORKER_NAME
EOF
confirm "Install into $TARGET?" || { echo "aborted — nothing written"; exit 1; }

say "Installing files"
RENDER_VARS="GITHUB_REPO HANDLERS AIRTABLE_BASE_ID AIRTABLE_TABLE_ID STATUS_FIELD TITLE_FIELD STATUS_ANALYZE STATUS_IMPLEMENT AIRTABLE_WEBHOOK_ID AGENT_NAME AGENT_MARKER PROJECT_NAME AUDIENCE STACK_NOTE BRANCH_PREFIX PR_BASE QA_NOTE BRAIN_NAME AI_MODEL WORKER_NAME"

(cd "$FILES" && find . -type f ! -name '.DS_Store' | sed 's#^\./##') | while IFS= read -r rel; do
  src="$FILES/$rel"
  case "$rel" in
    *.tmpl) dest="$TARGET/${rel%.tmpl}"; render "$src" "$dest" ;;
    *) dest="$TARGET/$rel"; mkdir -p "$(dirname "$dest")"; cp "$src" "$dest" ;;
  esac
  echo "  + ${dest#"$TARGET/"}"
done

install -m 0755 "$ROOT/core/state/git-branch.sh" "$AGENT_DIR/state.sh"
echo "  + scripts/airtable-agent/state.sh  (core/state/git-branch.sh)"
mkdir -p "$AGENT_DIR/ai"
install -m 0644 "$BRAIN_FILE" "$AGENT_DIR/ai/brain.sh"
echo "  + scripts/airtable-agent/ai/brain.sh  ($BRAIN_NAME)"
chmod +x "$AGENT_DIR"/*.sh
runtime_render_ci "$RUNTIME_NAME" "$ROOT/core/runtimes" "$AGENT_DIR" "scripts/airtable-agent"

jq -n \
  --arg runtime "$RUNTIME_NAME" \
  --arg github_repo "$GITHUB_REPO" --arg airtable_base_id "$AIRTABLE_BASE_ID" \
  --arg airtable_table_id "$AIRTABLE_TABLE_ID" --arg status_field "$STATUS_FIELD" \
  --arg title_field "$TITLE_FIELD" --arg status_analyze "$STATUS_ANALYZE" \
  --arg status_implement "$STATUS_IMPLEMENT" --arg airtable_webhook_id "$AIRTABLE_WEBHOOK_ID" \
  --arg agent_name "$AGENT_NAME" --arg project_name "$PROJECT_NAME" \
  --arg audience "$AUDIENCE" --arg stack_note "$STACK_NOTE" \
  --arg branch_prefix "$BRANCH_PREFIX" --arg pr_base "$PR_BASE" \
  --arg qa_command "$QA_COMMAND" --arg brain "$BRAIN_NAME" --arg ai_model "$AI_MODEL" \
  --arg worker_name "$WORKER_NAME" \
  '{recipe: "airtable/project-agent", runtime: $runtime, brain: $brain,
    handlers: "records", github_repo: $github_repo, airtable_base_id: $airtable_base_id,
    airtable_table_id: $airtable_table_id, status_field: $status_field,
    title_field: $title_field, status_analyze: $status_analyze,
    status_implement: $status_implement, airtable_webhook_id: $airtable_webhook_id,
    agent_name: $agent_name, project_name: $project_name, audience: $audience,
    stack_note: $stack_note, branch_prefix: $branch_prefix, pr_base: $pr_base,
    qa_command: $qa_command, ai_model: $ai_model, worker_name: $worker_name}' > "$CONFIG"
echo "  + scripts/airtable-agent/automation.config.json"

render_check "$AGENT_DIR" "$TARGET/.github/workflows/airtable-agent.yml" || true

say "GitHub secrets"
note "Required on $GITHUB_REPO:"
note "  AIRTABLE_TOKEN — personal access token from airtable.com/create/tokens with"
note "    scopes data.records:read, data.records:write, data.recordComments:read,"
note "    data.recordComments:write, schema.bases:read, webhook:manage — and access"
note "    to base $AIRTABLE_BASE_ID"
note "  $BRAIN_AUTH_VARS — auth for the $BRAIN_NAME brain"
if [[ "$RUNTIME_NAME" == "github-actions" ]]; then
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if confirm "Set secrets on $GITHUB_REPO now with gh?"; then
      for s in AIRTABLE_TOKEN $BRAIN_AUTH_VARS AGENT_GH_PAT; do
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

4. Create the webhook (the response carries BOTH values you need next):
     curl -X POST "https://api.airtable.com/v0/bases/$AIRTABLE_BASE_ID/webhooks" \\
       -H "Authorization: Bearer <AIRTABLE_TOKEN>" -H "Content-Type: application/json" \\
       -d '{"notificationUrl": "https://$WORKER_NAME.<your-cf-subdomain>.workers.dev/hook",
            "specification": {"options": {"filters": {"dataTypes": ["tableData"], "recordChangeScope": "$AIRTABLE_TABLE_ID"}}}}'
     # copy .macSecretBase64 from the response (the base64 string as-is), then:
     wrangler secret put AIRTABLE_MAC_SECRET
     # copy .id into AIRTABLE_WEBHOOK_ID in scripts/airtable-agent/env.sh (or
     # re-run this installer) — agent runs then refresh the webhook, which
     # otherwise expires after 7 quiet days.

5. Commit the new files in $TARGET and merge them to the default branch
   (repository_dispatch only triggers workflows on the default branch).

6. Safe local test — no comments, no AI, no state pushed
   (export AIRTABLE_TOKEN first):
     cd $TARGET && DRY_RUN=1 bash scripts/airtable-agent/agent-run.sh

Operating docs (recovery, pausing, transcripts): scripts/airtable-agent/README.md
EOF
runtime_overlay "$RUNTIME_NAME" "scripts/airtable-agent" "$WORKER_NAME" "$BRAIN_AUTH_VARS" "AIRTABLE_TOKEN"
