#!/usr/bin/env bash
# Interactive installer for the Miro Board Agent.
# Renders files/ (+ core adapters) into a target repository.
set -euo pipefail

RECIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$RECIPE_DIR/../../.." && pwd)"
FILES="$RECIPE_DIR/files"
source "$ROOT/core/lib/wizard.sh"
source "$ROOT/core/lib/render.sh"
source "$ROOT/core/lib/brains.sh"

need git jq curl

say "Miro Board Agent — setup"
cat <<'EOF'
Installs a board-side Q&A agent into one of YOUR repositories:

  Miro board subscription (experimental) → Cloudflare Worker relay
  → GitHub Actions → headless Claude Code

Flow: someone writes a sticky note "@ai …" on a watched board (Miro's REST
v2 has no board-comments API, so the sticky IS the summon) → the agent reads
the question, answers FROM YOUR REPOSITORY — is this built? what does the
code do here? how hard is the change? — and places ONE reply sticky right
beside it. Everything else: silence. That reply sticky is its only write:
it never edits, moves, or deletes anything else on the board.

You'll need: a GitHub repo, a Miro app access token (Settings → Your apps →
create an app → install it to the board's team → boards:read +
boards:write), a free Cloudflare account, and Claude auth.
EOF

say "Target repository"
ask TARGET_IN "Path to the repository the agent should answer from"
TARGET_IN="${TARGET_IN/#\~/$HOME}"
TARGET="$(cd "$TARGET_IN" 2>/dev/null && pwd)" || { echo "error: no such directory: $TARGET_IN" >&2; exit 1; }
[[ -d "$TARGET/.git" ]] || { echo "error: not a git repository: $TARGET" >&2; exit 1; }

AGENT_DIR="$TARGET/scripts/miro-agent"
CONFIG="$AGENT_DIR/automation.config.json"
cfg() { jq -r ".$1 // empty" "$CONFIG" 2>/dev/null || true; }
d() { local v; v="$(cfg "$1")"; printf '%s' "${v:-$2}"; }
[[ -f "$CONFIG" ]] && note "(existing install found — answers default to your previous choices)"

origin_url=$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)
guess_repo=$(printf '%s' "$origin_url" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
ask GITHUB_REPO "GitHub repo (owner/name)" "$(d github_repo "$guess_repo")"

say "Miro"
ask MIRO_BOARD_ID "Board id to watch — the id after /app/board/ in the URL (keep the trailing '=')" "$(d miro_board_id '')"
ask TRIGGER "Trigger prefix (sticky notes starting with it summon the agent)" "$(d trigger '@ai')"
HANDLERS="stickies"

say "Conventions"
ask AGENT_NAME "Agent display name (prefixes every reply sticky)" "$(d agent_name 'Board Agent')"
AGENT_MARKER="🤖 $AGENT_NAME"
ask PROJECT_NAME "Product name used in replies" "$(d project_name "$(basename "$TARGET")")"
ask AUDIENCE "Who asks the questions? (replies are written for them)" "$(d audience 'designers and PMs')"
ask STACK_NOTE "One-line stack note for the agent" "$(d stack_note 'follow the conventions in CLAUDE.md / README')"
choose_brain "$ROOT/core/ai" "$(d brain 'claude-code')"
ask AI_MODEL "Model for $BRAIN_NAME" "$(d ai_model "$AI_MODEL_DEFAULT")"

repo_slug=$(basename "$TARGET" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
WORKER_NAME="$(d worker_name "${repo_slug}-miro-relay")"

say "Summary"
cat <<EOF
  Target repo        $TARGET
  GitHub repo        $GITHUB_REPO
  Summon             sticky notes starting with '$TRIGGER'
  Watched board      $MIRO_BOARD_ID
  Agent              $AGENT_MARKER · brain $BRAIN_NAME · model $AI_MODEL
  Writes             ONE reply sticky beside the question — never edits, moves, or deletes anything else
  Relay worker       $WORKER_NAME
EOF
confirm "Install into $TARGET?" || { echo "aborted — nothing written"; exit 1; }

say "Installing files"
RENDER_VARS="GITHUB_REPO HANDLERS MIRO_BOARD_ID TRIGGER AGENT_NAME AGENT_MARKER PROJECT_NAME AUDIENCE STACK_NOTE BRAIN_NAME AI_MODEL WORKER_NAME"

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
echo "  + scripts/miro-agent/ai/brain.sh  ($BRAIN_NAME)"
chmod +x "$AGENT_DIR"/*.sh

jq -n \
  --arg github_repo "$GITHUB_REPO" --arg miro_board_id "$MIRO_BOARD_ID" \
  --arg trigger "$TRIGGER" --arg agent_name "$AGENT_NAME" \
  --arg project_name "$PROJECT_NAME" --arg audience "$AUDIENCE" \
  --arg stack_note "$STACK_NOTE" --arg brain "$BRAIN_NAME" --arg ai_model "$AI_MODEL" \
  --arg worker_name "$WORKER_NAME" \
  '{recipe: "miro/board-agent", runtime: "github-actions", brain: $brain,
    handlers: "stickies", github_repo: $github_repo, miro_board_id: $miro_board_id,
    trigger: $trigger, agent_name: $agent_name,
    project_name: $project_name, audience: $audience,
    stack_note: $stack_note, ai_model: $ai_model,
    worker_name: $worker_name}' > "$CONFIG"
echo "  + scripts/miro-agent/automation.config.json"

render_check "$AGENT_DIR" "$TARGET/.github/workflows/miro-agent.yml" || true

say "GitHub secrets"
note "Required on $GITHUB_REPO:"
note "  MIRO_TOKEN — Miro → Settings → Your apps → app access token (boards:read + boards:write, installed to the board's team)"
note "  $BRAIN_AUTH_VARS — auth for the $BRAIN_NAME brain"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  if confirm "Set secrets on $GITHUB_REPO now with gh?"; then
    for s in MIRO_TOKEN $BRAIN_AUTH_VARS; do
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
     wrangler secret put WEBHOOK_SECRET  # e.g. openssl rand -hex 24 — keep it for step 4;
                                         # Miro's experimental webhooks carry no signature,
                                         # so the secret URL path IS the authentication

4. Create the board subscription (the endpoint is EXPERIMENTAL — if creation
   fails, check the app is installed to the board's team with boards:read):
     curl -X POST "https://api.miro.com/v2-experimental/webhooks/board_subscriptions" \\
       -H "Authorization: Bearer <MIRO_TOKEN>" -H "Content-Type: application/json" \\
       -d '{"boardId": "$MIRO_BOARD_ID",
            "callbackUrl": "https://$WORKER_NAME.<your-cf-subdomain>.workers.dev/hook/<WEBHOOK_SECRET>",
            "status": "enabled"}'
   Creation sends a challenge POST to the callback first — the relay echoes
   it back automatically, which is what enables the subscription.

5. Test: write a sticky "$TRIGGER is the login screen built?" on the board —
   the answer sticky appears right beside it. Or run it by hand: Actions →
   Miro Board Agent → Run workflow → a question (item_id optional for manual
   runs — the driver tolerates a missing item via "(origin sticky
   unavailable)" and places the reply near the board origin). No reconcile
   button here — the recipe is stateless, so the manual run IS the test.

   Safe local test — no AI, no reply (export MIRO_TOKEN first for live
   sticky content):
     cd $TARGET && DRY_RUN=1 MODE=ask ASK_TEXT="is X built?" ITEM_ID=<sticky-item-id> \\
       bash scripts/miro-agent/agent-run.sh

Operating docs: scripts/miro-agent/README.md
EOF
