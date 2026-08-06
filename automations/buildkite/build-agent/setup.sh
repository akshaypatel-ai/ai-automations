#!/usr/bin/env bash
# Interactive installer for the Buildkite Build Agent.
# Renders files/ (+ core adapters) into a target repository.
set -euo pipefail

RECIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$RECIPE_DIR/../../.." && pwd)"
FILES="$RECIPE_DIR/files"
source "$ROOT/core/lib/wizard.sh"
source "$ROOT/core/lib/render.sh"
source "$ROOT/core/lib/brains.sh"

need git jq curl

say "Buildkite Build Agent — setup"
cat <<'EOF'
Installs an event-driven AI agent into one of YOUR repositories:

  Buildkite build.failed webhook (signature/token-verified) → Cloudflare Worker relay → GitHub Actions → headless Claude Code

Flow: a CI build of this repo fails → the agent fetches the build + the
failing job's log from Buildkite, reads this repository at the implicated
code, and files ONE GitHub issue (what failed, log excerpt, likely cause,
where to look, links). New failures of the same commit become ONE comment
on that issue — never a duplicate. It never retries or cancels builds —
Buildkite is read-only; the only writes are GitHub issues.

You'll need: a GitHub repo built by a Buildkite pipeline, a Buildkite API
token (buildkite.com/user/api-access-tokens, scopes read_builds +
read_build_logs), a free Cloudflare account, and Claude auth.

Finding slugs: the org slug is the <org> in buildkite.com/<org>; the
pipeline slug is the <pipeline> in buildkite.com/<org>/<pipeline>.
EOF

say "Target repository"
ask TARGET_IN "Path to the repository the agent should work in"
TARGET_IN="${TARGET_IN/#\~/$HOME}"
TARGET="$(cd "$TARGET_IN" 2>/dev/null && pwd)" || { echo "error: no such directory: $TARGET_IN" >&2; exit 1; }
[[ -d "$TARGET/.git" ]] || { echo "error: not a git repository: $TARGET" >&2; exit 1; }

AGENT_DIR="$TARGET/scripts/buildkite-agent"
CONFIG="$AGENT_DIR/automation.config.json"
cfg() { jq -r ".$1 // empty" "$CONFIG" 2>/dev/null || true; }
d() { local v; v="$(cfg "$1")"; printf '%s' "${v:-$2}"; }
[[ -f "$CONFIG" ]] && note "(existing install found — answers default to your previous choices)"

origin_url=$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)
guess_repo=$(printf '%s' "$origin_url" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
ask GITHUB_REPO "GitHub repo (owner/name)" "$(d github_repo "$guess_repo")"

say "Buildkite"
note "Org slug: the <org> in buildkite.com/<org>."
ask BUILDKITE_ORG "Buildkite organization slug" "$(d buildkite_org '')"
note "Pipeline slug: the <pipeline> in buildkite.com/<org>/<pipeline>."
ask BUILDKITE_PIPELINE "Buildkite pipeline slug" "$(d buildkite_pipeline '')"
HANDLERS="builds"

say "Conventions"
ask ISSUE_LABEL "Label applied to filed GitHub issues" "$(d issue_label 'ci-failure')"
ask AGENT_NAME "Agent display name (signs every issue)" "$(d agent_name 'Build Triage Agent')"
AGENT_MARKER="🤖 $AGENT_NAME"
ask PROJECT_NAME "Product name used in issues" "$(d project_name "$(basename "$TARGET")")"
ask STACK_NOTE "One-line stack note for the agent" "$(d stack_note 'follow the conventions in CLAUDE.md / README')"
choose_brain "$ROOT/core/ai" "$(d brain 'claude-code')"
ask AI_MODEL "Model for $BRAIN_NAME" "$(d ai_model "$AI_MODEL_DEFAULT")"

repo_slug=$(basename "$TARGET" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
WORKER_NAME="$(d worker_name "${repo_slug}-buildkite-relay")"

say "Summary"
cat <<EOF
  Target repo        $TARGET
  GitHub repo        $GITHUB_REPO
  Buildkite          org $BUILDKITE_ORG · pipeline $BUILDKITE_PIPELINE
  Issue label        $ISSUE_LABEL
  Agent              $AGENT_MARKER · brain $BRAIN_NAME · model $AI_MODEL
  Relay worker       $WORKER_NAME
EOF
confirm "Install into $TARGET?" || { echo "aborted — nothing written"; exit 1; }

say "Installing files"
RENDER_VARS="GITHUB_REPO HANDLERS BUILDKITE_ORG BUILDKITE_PIPELINE ISSUE_LABEL AGENT_NAME AGENT_MARKER PROJECT_NAME STACK_NOTE BRAIN_NAME AI_MODEL WORKER_NAME"

(cd "$FILES" && find . -type f ! -name '.DS_Store' | sed 's#^\./##') | while IFS= read -r rel; do
  src="$FILES/$rel"
  case "$rel" in
    *.tmpl) dest="$TARGET/${rel%.tmpl}"; render "$src" "$dest" ;;
    *) dest="$TARGET/$rel"; mkdir -p "$(dirname "$dest")"; cp "$src" "$dest" ;;
  esac
  echo "  + ${dest#"$TARGET/"}"
done

install -m 0755 "$ROOT/core/state/git-branch.sh" "$AGENT_DIR/state.sh"
echo "  + scripts/buildkite-agent/state.sh  (core/state/git-branch.sh)"
mkdir -p "$AGENT_DIR/ai"
install -m 0644 "$BRAIN_FILE" "$AGENT_DIR/ai/brain.sh"
echo "  + scripts/buildkite-agent/ai/brain.sh  ($BRAIN_NAME)"
chmod +x "$AGENT_DIR"/*.sh

jq -n \
  --arg github_repo "$GITHUB_REPO" --arg buildkite_org "$BUILDKITE_ORG" \
  --arg buildkite_pipeline "$BUILDKITE_PIPELINE" \
  --arg issue_label "$ISSUE_LABEL" --arg agent_name "$AGENT_NAME" \
  --arg project_name "$PROJECT_NAME" --arg stack_note "$STACK_NOTE" \
  --arg brain "$BRAIN_NAME" --arg ai_model "$AI_MODEL" --arg worker_name "$WORKER_NAME" \
  '{recipe: "buildkite/build-agent", runtime: "github-actions", brain: $brain,
    handlers: "builds", github_repo: $github_repo,
    buildkite_org: $buildkite_org, buildkite_pipeline: $buildkite_pipeline,
    issue_label: $issue_label, agent_name: $agent_name,
    project_name: $project_name, stack_note: $stack_note,
    ai_model: $ai_model, worker_name: $worker_name}' > "$CONFIG"
echo "  + scripts/buildkite-agent/automation.config.json"

render_check "$AGENT_DIR" "$TARGET/.github/workflows/buildkite-agent.yml" || true

say "GitHub secrets"
note "Required on $GITHUB_REPO:"
note "  BUILDKITE_TOKEN — buildkite.com/user/api-access-tokens; scopes: read_builds + read_build_logs"
note "  $BRAIN_AUTH_VARS — auth for the $BRAIN_NAME brain"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  if confirm "Set secrets on $GITHUB_REPO now with gh?"; then
    for s in BUILDKITE_TOKEN $BRAIN_AUTH_VARS AGENT_GH_PAT; do
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
   AGENT_GH_PAT (optional, classic PAT with 'repo' scope) files issues as a
   real user instead of github-actions[bot], so they notify the team and can
   trigger other workflows.

2. Create the issue label once (gh issue create fails on unknown labels):
     gh label create "$ISSUE_LABEL" -R "$GITHUB_REPO" --description "Filed by $AGENT_NAME"

3. Deploy the relay (free Cloudflare account; npm i -g wrangler):
     cd $AGENT_DIR/relay
     wrangler deploy
     wrangler secret put GITHUB_PAT                # fine-grained PAT: only $GITHUB_REPO, contents: read+write
     wrangler secret put BUILDKITE_WEBHOOK_SECRET  # the Token the webhook service shows (step 4) — it stays
                                                   # visible on the service page, so either order works

4. Create the webhook notification service (Buildkite → Organization
   Settings → Notification Services → add a Webhook; a pipeline-level
   webhook works too):
     - Events: build.failed (only this one matters here)
     - Webhook URL: https://$WORKER_NAME.<your-cf-subdomain>.workers.dev/hook
     - Copy the service's Token — that value is BUILDKITE_WEBHOOK_SECRET in
       step 3; deliveries authenticate with it (X-Buildkite-Token and, when
       enabled, X-Buildkite-Signature — the relay accepts either).

5. Commit the new files in $TARGET and merge them to the default branch
   (repository_dispatch only triggers workflows on the default branch).

6. Safe local test — no GitHub issues, no AI, no state pushed
   (export BUILDKITE_TOKEN first):
     cd $TARGET && DRY_RUN=1 bash scripts/buildkite-agent/agent-run.sh

Operating docs (recovery, pausing, transcripts): scripts/buildkite-agent/README.md
EOF
