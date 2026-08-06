#!/usr/bin/env bash
# Interactive installer for the Figma Design Agent.
# Renders files/ (+ core adapters) into a target repository.
set -euo pipefail

RECIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$RECIPE_DIR/../../.." && pwd)"
FILES="$RECIPE_DIR/files"
source "$ROOT/core/lib/wizard.sh"
source "$ROOT/core/lib/render.sh"
source "$ROOT/core/lib/brains.sh"

need git jq curl

say "Figma Design Agent — setup"
cat <<'EOF'
Installs a design-to-code Q&A agent into one of YOUR repositories:

  Figma FILE_COMMENT webhook → Cloudflare Worker relay → GitHub Actions → headless Claude Code

Flow: someone comments "@ai …" on a watched design (Figma can't @mention a
bot, so a trigger prefix is the summon) → the agent reads the comment thread,
answers FROM YOUR REPOSITORY — is this built? what does the current version
do? how hard is the change? — and replies in the same thread. Everything
else: silence. Comments only: it never edits designs and never resolves
threads.

You'll need: a GitHub repo, a Figma personal access token (scopes
file_comments:write + files:read + webhooks:write for creation), a team on a
paid Figma plan (v2 webhooks are team-scoped), a free Cloudflare account,
and Claude auth.
EOF

say "Target repository"
ask TARGET_IN "Path to the repository the agent should answer from"
TARGET_IN="${TARGET_IN/#\~/$HOME}"
TARGET="$(cd "$TARGET_IN" 2>/dev/null && pwd)" || { echo "error: no such directory: $TARGET_IN" >&2; exit 1; }
[[ -d "$TARGET/.git" ]] || { echo "error: not a git repository: $TARGET" >&2; exit 1; }

AGENT_DIR="$TARGET/scripts/figma-agent"
CONFIG="$AGENT_DIR/automation.config.json"
cfg() { jq -r ".$1 // empty" "$CONFIG" 2>/dev/null || true; }
d() { local v; v="$(cfg "$1")"; printf '%s' "${v:-$2}"; }
[[ -f "$CONFIG" ]] && note "(existing install found — answers default to your previous choices)"

origin_url=$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)
guess_repo=$(printf '%s' "$origin_url" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
ask GITHUB_REPO "GitHub repo (owner/name)" "$(d github_repo "$guess_repo")"

say "Figma"
ask TRIGGER "Trigger prefix (comments starting with it summon the agent)" "$(d trigger '@ai')"
ask_opt WATCHED_FILE "File key to watch — the <key> in figma.com/design/<key>/… (Enter = every file the webhook's team emits)" "$(d watched_file '')"
HANDLERS="comments"

say "Conventions"
ask AGENT_NAME "Agent display name (signs every reply)" "$(d agent_name 'Design Agent')"
AGENT_MARKER="🤖 $AGENT_NAME"
ask PROJECT_NAME "Product name used in replies" "$(d project_name "$(basename "$TARGET")")"
ask AUDIENCE "Who asks the questions? (replies are written for them)" "$(d audience 'designers and PMs')"
ask STACK_NOTE "One-line stack note for the agent" "$(d stack_note 'follow the conventions in CLAUDE.md / README')"
choose_brain "$ROOT/core/ai" "$(d brain 'claude-code')"
ask AI_MODEL "Model for $BRAIN_NAME" "$(d ai_model "$AI_MODEL_DEFAULT")"

repo_slug=$(basename "$TARGET" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
WORKER_NAME="$(d worker_name "${repo_slug}-figma-relay")"

say "Summary"
cat <<EOF
  Target repo        $TARGET
  GitHub repo        $GITHUB_REPO
  Summon             comments starting with '$TRIGGER'
  Watched file       ${WATCHED_FILE:-(all team files)}
  Agent              $AGENT_MARKER · brain $BRAIN_NAME · model $AI_MODEL
  Writes             thread replies only — never edits designs or resolves threads
  Relay worker       $WORKER_NAME
EOF
confirm "Install into $TARGET?" || { echo "aborted — nothing written"; exit 1; }

say "Installing files"
RENDER_VARS="GITHUB_REPO HANDLERS TRIGGER WATCHED_FILE AGENT_NAME AGENT_MARKER PROJECT_NAME AUDIENCE STACK_NOTE BRAIN_NAME AI_MODEL WORKER_NAME"

(cd "$FILES" && find . -type f ! -name '.DS_Store' | sed 's#^\./##') | while IFS= read -r rel; do
  src="$FILES/$rel"
  case "$rel" in
    *.tmpl) dest="$TARGET/${rel%.tmpl}"; render "$src" "$dest" ;;
    *) dest="$TARGET/$rel"; mkdir -p "$(dirname "$dest")"; cp "$src" "$dest" ;;
  esac
  echo "  + ${dest#"$TARGET/"}"
done

mkdir -p "$AGENT_DIR/ai"
install -m 0644 "$BRAIN_FILE" "$AGENT_DIR/ai/brain.sh"
echo "  + scripts/figma-agent/ai/brain.sh  ($BRAIN_NAME)"
chmod +x "$AGENT_DIR"/*.sh

jq -n \
  --arg github_repo "$GITHUB_REPO" --arg trigger "$TRIGGER" \
  --arg watched_file "$WATCHED_FILE" --arg agent_name "$AGENT_NAME" \
  --arg project_name "$PROJECT_NAME" --arg audience "$AUDIENCE" \
  --arg stack_note "$STACK_NOTE" --arg brain "$BRAIN_NAME" --arg ai_model "$AI_MODEL" \
  --arg worker_name "$WORKER_NAME" \
  '{recipe: "figma/design-agent", runtime: "github-actions", brain: $brain,
    handlers: "comments", github_repo: $github_repo, trigger: $trigger,
    watched_file: $watched_file, agent_name: $agent_name,
    project_name: $project_name, audience: $audience,
    stack_note: $stack_note, ai_model: $ai_model,
    worker_name: $worker_name}' > "$CONFIG"
echo "  + scripts/figma-agent/automation.config.json"

render_check "$AGENT_DIR" "$TARGET/.github/workflows/figma-agent.yml" || true

say "GitHub secrets"
note "Required on $GITHUB_REPO:"
note "  FIGMA_TOKEN — figma.com/settings → Personal access tokens (scopes: file_comments:write + files:read)"
note "  $BRAIN_AUTH_VARS — auth for the $BRAIN_NAME brain"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  if confirm "Set secrets on $GITHUB_REPO now with gh?"; then
    for s in FIGMA_TOKEN $BRAIN_AUTH_VARS; do
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

2. Commit the new files in $TARGET and merge them to the default branch
   (repository_dispatch only triggers workflows on the default branch).

3. Deploy the relay (free Cloudflare account; npm i -g wrangler):
     cd $AGENT_DIR/relay
     wrangler deploy
     wrangler secret put GITHUB_PAT      # fine-grained PAT: only $GITHUB_REPO, contents: read+write
     wrangler secret put FIGMA_PASSCODE  # e.g. openssl rand -hex 24 — keep it for step 4;
                                         # it's Figma's ONLY delivery verification (no HMAC)

4. Create the Figma webhook (needs a team on a PAID plan — v2 webhooks are
   team-scoped — and a token with webhooks:write):
     curl -X POST https://api.figma.com/v2/webhooks \\
       -H "X-Figma-Token: <FIGMA_TOKEN>" -H "Content-Type: application/json" \\
       -d '{"event_type": "FILE_COMMENT",
            "team_id": "<TEAM_ID — the number in figma.com/files/team/<id>/…>",
            "endpoint": "https://$WORKER_NAME.<your-cf-subdomain>.workers.dev/hook",
            "passcode": "<FIGMA_PASSCODE>"}'
   Creation fires a PING delivery first — the relay answers it 200, which is
   what marks the webhook healthy.

5. Test: comment "$TRIGGER is the login screen built?" on a watched design —
   the answer appears in the same thread. Or run it by hand: Actions →
   Figma Design Agent → Run workflow → a question + file key + root comment
   id. (No reconcile button here — the recipe is stateless, so the manual
   workflow run IS the test.)

   Safe local test — no AI, no reply (export FIGMA_TOKEN first for live
   thread context):
     cd $TARGET && DRY_RUN=1 MODE=ask ASK_TEXT="is X built?" FILE_KEY=<key> ROOT_ID=<comment-id> \\
       bash scripts/figma-agent/agent-run.sh

Operating docs: scripts/figma-agent/README.md
EOF
