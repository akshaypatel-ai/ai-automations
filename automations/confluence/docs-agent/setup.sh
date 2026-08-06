#!/usr/bin/env bash
# Interactive installer for the Confluence Docs Agent.
# Renders files/ (+ core adapters) into a target repository.
set -euo pipefail

RECIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$RECIPE_DIR/../../.." && pwd)"
FILES="$RECIPE_DIR/files"
source "$ROOT/core/lib/wizard.sh"
source "$ROOT/core/lib/render.sh"
source "$ROOT/core/lib/brains.sh"

need git jq curl

say "Confluence Docs Agent — setup"
cat <<'EOF'
Installs an event-driven AI docs-review agent into one of YOUR repositories:

  Confluence Automation rule → web request → Cloudflare Worker relay → GitHub Actions → headless Claude Code

Flow: label a page for review → the agent reads it, compares the spec against
what the code in your repository actually does, and posts ONE footer comment:
what's aligned, what's missing, what contradicts the code, plus numbered
questions. New comments on a tracked page get ONE grounded reply — or silence
when they aren't addressed to the agent. Comments only: it never edits pages
and never changes labels.

You'll need: a GitHub repo, an Atlassian API token (id.atlassian.com — the
same token type Jira uses), a free Cloudflare account, and Claude auth.
Confluence Automation rules need a Premium+ plan; on Standard the manual
Run-workflow button is the doorbell instead.
EOF

say "Target repository"
ask TARGET_IN "Path to the repository the agent should work in"
TARGET_IN="${TARGET_IN/#\~/$HOME}"
TARGET="$(cd "$TARGET_IN" 2>/dev/null && pwd)" || { echo "error: no such directory: $TARGET_IN" >&2; exit 1; }
[[ -d "$TARGET/.git" ]] || { echo "error: not a git repository: $TARGET" >&2; exit 1; }

AGENT_DIR="$TARGET/scripts/confluence-agent"
CONFIG="$AGENT_DIR/automation.config.json"
cfg() { jq -r ".$1 // empty" "$CONFIG" 2>/dev/null || true; }
d() { local v; v="$(cfg "$1")"; printf '%s' "${v:-$2}"; }
[[ -f "$CONFIG" ]] && note "(existing install found — answers default to your previous choices)"

origin_url=$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)
guess_repo=$(printf '%s' "$origin_url" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
ask GITHUB_REPO "GitHub repo (owner/name)" "$(d github_repo "$guess_repo")"

say "Confluence"
ask CONFLUENCE_SITE "Confluence site (the <site> in <site>.atlassian.net)" "$(d confluence_site '')"
ask REVIEW_LABEL "Review label (adding it to a page requests a review)" "$(d review_label 'ai-review')"
HANDLERS="pages"

say "Conventions"
ask AGENT_NAME "Agent display name (signs every comment)" "$(d agent_name 'Docs Agent')"
AGENT_MARKER="🤖 $AGENT_NAME"
ask PROJECT_NAME "Product name used in comments" "$(d project_name "$(basename "$TARGET")")"
ask AUDIENCE "Who is the audience? (comments are written for them)" "$(d audience 'the team reading these docs')"
ask STACK_NOTE "One-line stack note for the agent" "$(d stack_note 'follow the conventions in CLAUDE.md / README')"
choose_brain "$ROOT/core/ai" "$(d brain 'claude-code')"
ask AI_MODEL "Model for $BRAIN_NAME" "$(d ai_model "$AI_MODEL_DEFAULT")"

repo_slug=$(basename "$TARGET" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
WORKER_NAME="$(d worker_name "${repo_slug}-confluence-relay")"

say "Summary"
cat <<EOF
  Target repo        $TARGET
  GitHub repo        $GITHUB_REPO
  Confluence         $CONFLUENCE_SITE.atlassian.net/wiki
  Review label       '$REVIEW_LABEL' on a page requests a review
  Agent              $AGENT_MARKER · brain $BRAIN_NAME · model $AI_MODEL
  Writes             footer comments only — never edits pages or labels
  Relay worker       $WORKER_NAME
EOF
confirm "Install into $TARGET?" || { echo "aborted — nothing written"; exit 1; }

say "Installing files"
RENDER_VARS="GITHUB_REPO HANDLERS CONFLUENCE_SITE REVIEW_LABEL AGENT_NAME AGENT_MARKER PROJECT_NAME AUDIENCE STACK_NOTE BRAIN_NAME AI_MODEL WORKER_NAME"

(cd "$FILES" && find . -type f ! -name '.DS_Store' | sed 's#^\./##') | while IFS= read -r rel; do
  src="$FILES/$rel"
  case "$rel" in
    *.tmpl) dest="$TARGET/${rel%.tmpl}"; render "$src" "$dest" ;;
    *) dest="$TARGET/$rel"; mkdir -p "$(dirname "$dest")"; cp "$src" "$dest" ;;
  esac
  echo "  + ${dest#"$TARGET/"}"
done

install -m 0755 "$ROOT/core/state/git-branch.sh" "$AGENT_DIR/state.sh"
echo "  + scripts/confluence-agent/state.sh  (core/state/git-branch.sh)"
mkdir -p "$AGENT_DIR/ai"
install -m 0644 "$BRAIN_FILE" "$AGENT_DIR/ai/brain.sh"
echo "  + scripts/confluence-agent/ai/brain.sh  ($BRAIN_NAME)"
chmod +x "$AGENT_DIR"/*.sh

jq -n \
  --arg github_repo "$GITHUB_REPO" --arg confluence_site "$CONFLUENCE_SITE" \
  --arg review_label "$REVIEW_LABEL" --arg agent_name "$AGENT_NAME" \
  --arg project_name "$PROJECT_NAME" --arg audience "$AUDIENCE" \
  --arg stack_note "$STACK_NOTE" --arg brain "$BRAIN_NAME" --arg ai_model "$AI_MODEL" \
  --arg worker_name "$WORKER_NAME" \
  '{recipe: "confluence/docs-agent", runtime: "github-actions", brain: $brain,
    handlers: "pages", github_repo: $github_repo,
    confluence_site: $confluence_site, review_label: $review_label,
    agent_name: $agent_name, project_name: $project_name, audience: $audience,
    stack_note: $stack_note, ai_model: $ai_model,
    worker_name: $worker_name}' > "$CONFIG"
echo "  + scripts/confluence-agent/automation.config.json"

render_check "$AGENT_DIR" "$TARGET/.github/workflows/confluence-agent.yml" || true

say "GitHub secrets"
note "Required on $GITHUB_REPO:"
note "  CONFLUENCE_EMAIL — the agent's Atlassian sign-in email (basic auth pairs email + token)"
note "  CONFLUENCE_API_TOKEN — id.atlassian.com → Security → API tokens (the same token type Jira uses)"
note "  $BRAIN_AUTH_VARS — auth for the $BRAIN_NAME brain"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  if confirm "Set secrets on $GITHUB_REPO now with gh?"; then
    for s in CONFLUENCE_EMAIL CONFLUENCE_API_TOKEN $BRAIN_AUTH_VARS AGENT_GH_PAT; do
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
   AGENT_GH_PAT is optional here (no PRs, no issues) — the built-in token
   pushes the state branch fine once step 2 is done.

2. Repo setting: Settings → Actions → General → Workflow permissions →
   "Read and write permissions" (state-branch pushes need it).

3. Deploy the relay (free Cloudflare account; npm i -g wrangler):
     cd $AGENT_DIR/relay
     wrangler deploy
     wrangler secret put GITHUB_PAT       # fine-grained PAT: only $GITHUB_REPO, contents: read+write
     wrangler secret put WEBHOOK_SECRET   # e.g. openssl rand -hex 24 — keep it for step 4

4. Create TWO Confluence Automation rules (Premium+ plans — Space settings →
   Automation, or Global automation), each ending in the action
   "Send web request":
     URL for both (<SECRET> is the WEBHOOK_SECRET value from step 3):
       https://$WORKER_NAME.<your-cf-subdomain>.workers.dev/hook/<SECRET>
     Method POST, web request body = Custom data, written exactly as below —
     Confluence fills the smart value:
     rule 1 — trigger "Label added", label '$REVIEW_LABEL':
       {"page_id": "{{page.id}}", "event": "label-added"}
     rule 2 — trigger "Comment added":
       {"page_id": "{{page.id}}", "event": "comment-added"}

   No Automation (Standard plan)? The recipe still works — label pages, then
   press Actions → Confluence Docs Agent → Run workflow (empty item_id
   reconciles every labeled page). The doorbell pattern doesn't care how
   it's rung.

5. Commit the new files in $TARGET and merge them to the default branch
   (repository_dispatch only triggers workflows on the default branch).

6. Safe local test — no comments, no AI, no state pushed
   (export CONFLUENCE_EMAIL and CONFLUENCE_API_TOKEN first):
     cd $TARGET && DRY_RUN=1 bash scripts/confluence-agent/agent-run.sh

Operating docs (recovery, pausing, transcripts): scripts/confluence-agent/README.md
EOF
