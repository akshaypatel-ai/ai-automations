#!/usr/bin/env bash
# Interactive installer for the Freshdesk Triage Agent.
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

say "Freshdesk Triage Agent — setup"
cat <<'EOF'
Installs an event-driven AI support-triage agent into one of YOUR repositories:

  Freshdesk automation rule → webhook → Cloudflare Worker relay → GitHub Actions → headless Claude Code

Flow: a ticket arrives → the agent grounds itself in your product's repo and
posts ONE private note (category + a draft reply a human can send nearly
verbatim); real product bugs get escalated as GitHub issues. It NEVER messages
customers and never touches ticket status — humans own the queue.

You'll need: a GitHub repo, your Freshdesk API key (Profile settings → View
API key), a free Cloudflare account, and Claude auth.
EOF

say "Target repository"
ask TARGET_IN "Path to the repository the agent should work in"
TARGET_IN="${TARGET_IN/#\~/$HOME}"
TARGET="$(cd "$TARGET_IN" 2>/dev/null && pwd)" || { echo "error: no such directory: $TARGET_IN" >&2; exit 1; }
[[ -d "$TARGET/.git" ]] || { echo "error: not a git repository: $TARGET" >&2; exit 1; }

AGENT_DIR="$TARGET/scripts/freshdesk-agent"
CONFIG="$AGENT_DIR/automation.config.json"
cfg() { jq -r ".$1 // empty" "$CONFIG" 2>/dev/null || true; }
d() { local v; v="$(cfg "$1")"; printf '%s' "${v:-$2}"; }
[[ -f "$CONFIG" ]] && note "(existing install found — answers default to your previous choices)"

origin_url=$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)
guess_repo=$(printf '%s' "$origin_url" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
ask GITHUB_REPO "GitHub repo (owner/name)" "$(d github_repo "$guess_repo")"

say "Freshdesk"
ask FRESHDESK_DOMAIN "Freshdesk domain (the <domain> in <domain>.freshdesk.com)" "$(d freshdesk_domain '')"
ask ESCALATION_LABEL "Label for escalated GitHub issues" "$(d escalation_label 'from-support')"
HANDLERS="tickets"

say "Conventions"
ask AGENT_NAME "Agent display name (signs every private note)" "$(d agent_name 'Support Triage Agent')"
AGENT_MARKER="🤖 $AGENT_NAME"
ask PROJECT_NAME "Product name used in notes" "$(d project_name "$(basename "$TARGET")")"
ask AUDIENCE "Who is the audience? (draft replies are written for them)" "$(d audience 'customers and support agents')"
ask STACK_NOTE "One-line stack note for the agent" "$(d stack_note 'follow the conventions in CLAUDE.md / README')"
choose_brain "$ROOT/core/ai" "$(d brain 'claude-code')" mediated
ask AI_MODEL "Model for $BRAIN_NAME" "$(d ai_model "$AI_MODEL_DEFAULT")"
choose_runtime "$ROOT/core/runtimes" "$(d runtime 'github-actions')"

repo_slug=$(basename "$TARGET" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
WORKER_NAME="$(d worker_name "${repo_slug}-freshdesk-relay")"

say "Summary"
cat <<EOF
  Target repo        $TARGET
  GitHub repo        $GITHUB_REPO
  Freshdesk          $FRESHDESK_DOMAIN.freshdesk.com
  Escalation         GitHub issues labeled '$ESCALATION_LABEL'
  Agent              $AGENT_MARKER · brain $BRAIN_NAME · model $AI_MODEL · runtime $RUNTIME_NAME
  Writes             private notes only — humans send every customer reply
  Relay worker       $WORKER_NAME
EOF
confirm "Install into $TARGET?" || { echo "aborted — nothing written"; exit 1; }

say "Installing files"
RENDER_VARS="GITHUB_REPO HANDLERS FRESHDESK_DOMAIN ESCALATION_LABEL AGENT_NAME AGENT_MARKER PROJECT_NAME AUDIENCE STACK_NOTE BRAIN_NAME AI_MODEL WORKER_NAME"

(cd "$FILES" && find . -type f ! -name '.DS_Store' | sed 's#^\./##') | while IFS= read -r rel; do
  src="$FILES/$rel"
  case "$rel" in
    *.tmpl) dest="$TARGET/${rel%.tmpl}"; render "$src" "$dest" ;;
    *) dest="$TARGET/$rel"; mkdir -p "$(dirname "$dest")"; cp "$src" "$dest" ;;
  esac
  echo "  + ${dest#"$TARGET/"}"
done

install -m 0755 "$ROOT/core/state/git-branch.sh" "$AGENT_DIR/state.sh"
echo "  + scripts/freshdesk-agent/state.sh  (core/state/git-branch.sh)"
mkdir -p "$AGENT_DIR/ai"
install -m 0644 "$BRAIN_FILE" "$AGENT_DIR/ai/brain.sh"
echo "  + scripts/freshdesk-agent/ai/brain.sh  ($BRAIN_NAME)"
chmod +x "$AGENT_DIR"/*.sh
runtime_render_ci "$RUNTIME_NAME" "$ROOT/core/runtimes" "$AGENT_DIR" "scripts/freshdesk-agent"

jq -n \
  --arg runtime "$RUNTIME_NAME" \
  --arg github_repo "$GITHUB_REPO" --arg freshdesk_domain "$FRESHDESK_DOMAIN" \
  --arg escalation_label "$ESCALATION_LABEL" --arg agent_name "$AGENT_NAME" \
  --arg project_name "$PROJECT_NAME" --arg audience "$AUDIENCE" \
  --arg stack_note "$STACK_NOTE" --arg brain "$BRAIN_NAME" --arg ai_model "$AI_MODEL" \
  --arg worker_name "$WORKER_NAME" \
  '{recipe: "freshdesk/triage-agent", runtime: $runtime, brain: $brain,
    handlers: "tickets", github_repo: $github_repo,
    freshdesk_domain: $freshdesk_domain, escalation_label: $escalation_label,
    agent_name: $agent_name, project_name: $project_name, audience: $audience,
    stack_note: $stack_note, ai_model: $ai_model,
    worker_name: $worker_name}' > "$CONFIG"
echo "  + scripts/freshdesk-agent/automation.config.json"

render_check "$AGENT_DIR" "$TARGET/.github/workflows/freshdesk-agent.yml" || true

say "GitHub secrets"
note "Required on $GITHUB_REPO:"
note "  FRESHDESK_API_KEY — Freshdesk → Profile settings → View API key"
note "  $BRAIN_AUTH_VARS — auth for the $BRAIN_NAME brain"
if [[ "$RUNTIME_NAME" == "github-actions" ]]; then
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if confirm "Set secrets on $GITHUB_REPO now with gh?"; then
      for s in FRESHDESK_API_KEY $BRAIN_AUTH_VARS AGENT_GH_PAT; do
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
   AGENT_GH_PAT (optional, classic PAT with 'repo' scope) makes escalated
   issues trigger your 'issues:' workflows (the built-in GITHUB_TOKEN
   suppresses them).

2. Repo setting: Settings → Actions → General → Workflow permissions →
   "Read and write permissions" (state-branch pushes and 'gh issue create'
   need it when no AGENT_GH_PAT is set).

3. Deploy the relay (free Cloudflare account; npm i -g wrangler):
     cd $AGENT_DIR/relay
     wrangler deploy
     wrangler secret put GITHUB_PAT       # fine-grained PAT: only $GITHUB_REPO, contents: read+write
     wrangler secret put WEBHOOK_SECRET   # e.g. openssl rand -hex 24 — keep it for step 4

4. Create TWO automation rules (Admin → Workflows → Automations), each ending
   in the action "Trigger Webhook" — request type POST, encoding JSON,
   content "Advanced" with the bodies exactly as below (Freshdesk fills the
   placeholder). These webhooks are unsigned, so the URL secret IS the
   authentication — treat the full URL like a password:
     URL for both (<SECRET> is the WEBHOOK_SECRET value from step 3):
       https://$WORKER_NAME.<your-cf-subdomain>.workers.dev/hook/<SECRET>
     rule 1 — "Ticket Creation" (runs when a ticket is created):
       {"ticket_id": "{{ticket.id}}", "event": "created"}
     rule 2 — "Ticket Updates", condition "Note/Reply added" (reply or note
     added to the ticket):
       {"ticket_id": "{{ticket.id}}", "event": "updated"}

5. Commit the new files in $TARGET and merge them to the default branch
   (repository_dispatch only triggers workflows on the default branch).

6. Safe local test — no notes, no AI, no state pushed
   (export FRESHDESK_API_KEY first):
     cd $TARGET && DRY_RUN=1 bash scripts/freshdesk-agent/agent-run.sh

Operating docs (recovery, pausing, transcripts): scripts/freshdesk-agent/README.md
EOF
runtime_overlay "$RUNTIME_NAME" "scripts/freshdesk-agent" "$WORKER_NAME" "$BRAIN_AUTH_VARS" "FRESHDESK_API_KEY"
