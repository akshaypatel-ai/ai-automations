#!/usr/bin/env bash
# Interactive installer for the GitHub Issues Agent.
# Renders files/ (+ core adapters) into a target repository.
set -euo pipefail

RECIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$RECIPE_DIR/../../.." && pwd)"
FILES="$RECIPE_DIR/files"
source "$ROOT/core/lib/wizard.sh"
source "$ROOT/core/lib/render.sh"
source "$ROOT/core/lib/brains.sh"

need git jq

say "GitHub Issues Agent — setup"
cat <<'EOF'
Installs an event-driven AI agent into one of YOUR repositories — the
relay-free recipe:

  GitHub label / comment event → GitHub Actions (native trigger) → headless Claude Code

Flow: label an issue with your ANALYZE label → the agent posts options and
questions; discuss in comments; add your IMPLEMENT label → it builds the
change and opens a ready-for-review PR. It never touches labels or merges —
humans own the tracker.

You'll need: a GitHub repo and Claude auth. That's it — no relay, no webhook,
no extra tool token.
EOF

say "Target repository"
ask TARGET_IN "Path to the repository the agent should work in"
TARGET_IN="${TARGET_IN/#\~/$HOME}"
TARGET="$(cd "$TARGET_IN" 2>/dev/null && pwd)" || { echo "error: no such directory: $TARGET_IN" >&2; exit 1; }
[[ -d "$TARGET/.git" ]] || { echo "error: not a git repository: $TARGET" >&2; exit 1; }

AGENT_DIR="$TARGET/scripts/issues-agent"
CONFIG="$AGENT_DIR/automation.config.json"
cfg() { jq -r ".$1 // empty" "$CONFIG" 2>/dev/null || true; }
d() { local v; v="$(cfg "$1")"; printf '%s' "${v:-$2}"; }
[[ -f "$CONFIG" ]] && note "(existing install found — answers default to your previous choices)"

origin_url=$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)
guess_repo=$(printf '%s' "$origin_url" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
ask GITHUB_REPO "GitHub repo (owner/name)" "$(d github_repo "$guess_repo")"

say "Labels (the 'columns' of the flow)"
ask LABEL_ANALYZE "Label that triggers ANALYSIS" "$(d label_analyze 'ai-analyze')"
ask LABEL_IMPLEMENT "Label that triggers IMPLEMENTATION" "$(d label_implement 'ai-implement')"
HANDLERS="issues"

say "Conventions"
ask AGENT_NAME "Agent display name (signs every comment)" "$(d agent_name 'Project Agent')"
AGENT_MARKER="🤖 $AGENT_NAME"
ask PROJECT_NAME "Product name used in comments" "$(d project_name "$(basename "$TARGET")")"
ask AUDIENCE "Who reads these issues? (comments are written for them)" "$(d audience 'the team')"
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

say "Summary"
cat <<EOF
  Target repo        $TARGET
  GitHub repo        $GITHUB_REPO
  Analyze label      $LABEL_ANALYZE
  Implement label    $LABEL_IMPLEMENT
  Agent              $AGENT_MARKER · brain $BRAIN_NAME · model $AI_MODEL
  Branches           $BRANCH_PREFIX/<slug> → PRs into $PR_BASE
  Quick QA           ${QA_COMMAND:-none (PR CI only)}
  Relay              none — native Actions triggers
EOF
confirm "Install into $TARGET?" || { echo "aborted — nothing written"; exit 1; }

say "Installing files"
RENDER_VARS="GITHUB_REPO HANDLERS LABEL_ANALYZE LABEL_IMPLEMENT AGENT_NAME AGENT_MARKER PROJECT_NAME AUDIENCE STACK_NOTE BRANCH_PREFIX PR_BASE QA_NOTE BRAIN_NAME AI_MODEL"

(cd "$FILES" && find . -type f ! -name '.DS_Store' | sed 's#^\./##') | while IFS= read -r rel; do
  src="$FILES/$rel"
  case "$rel" in
    *.tmpl) dest="$TARGET/${rel%.tmpl}"; render "$src" "$dest" ;;
    *) dest="$TARGET/$rel"; mkdir -p "$(dirname "$dest")"; cp "$src" "$dest" ;;
  esac
  echo "  + ${dest#"$TARGET/"}"
done

install -m 0755 "$ROOT/core/state/git-branch.sh" "$AGENT_DIR/state.sh"
echo "  + scripts/issues-agent/state.sh  (core/state/git-branch.sh)"
mkdir -p "$AGENT_DIR/ai"
install -m 0644 "$BRAIN_FILE" "$AGENT_DIR/ai/brain.sh"
echo "  + scripts/issues-agent/ai/brain.sh  ($BRAIN_NAME)"
chmod +x "$AGENT_DIR"/*.sh

jq -n \
  --arg github_repo "$GITHUB_REPO" --arg label_analyze "$LABEL_ANALYZE" \
  --arg label_implement "$LABEL_IMPLEMENT" --arg agent_name "$AGENT_NAME" \
  --arg project_name "$PROJECT_NAME" --arg audience "$AUDIENCE" \
  --arg stack_note "$STACK_NOTE" --arg branch_prefix "$BRANCH_PREFIX" \
  --arg pr_base "$PR_BASE" --arg qa_command "$QA_COMMAND" \
  --arg brain "$BRAIN_NAME" --arg ai_model "$AI_MODEL" \
  '{recipe: "github/issues-agent", runtime: "github-actions", brain: $brain,
    handlers: "issues", github_repo: $github_repo, label_analyze: $label_analyze,
    label_implement: $label_implement, agent_name: $agent_name,
    project_name: $project_name, audience: $audience, stack_note: $stack_note,
    branch_prefix: $branch_prefix, pr_base: $pr_base, qa_command: $qa_command,
    ai_model: $ai_model}' > "$CONFIG"
echo "  + scripts/issues-agent/automation.config.json"

render_check "$AGENT_DIR" "$TARGET/.github/workflows/issues-agent.yml" || true

say "GitHub secrets"
note "Required on $GITHUB_REPO:"
note "  $BRAIN_AUTH_VARS — auth for the $BRAIN_NAME brain"
note "  (no tool token needed — the built-in GITHUB_TOKEN covers the GitHub API)"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  if confirm "Set secrets on $GITHUB_REPO now with gh?"; then
    for s in $BRAIN_AUTH_VARS AGENT_GH_PAT; do
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

3. Create the two labels (once):
     gh label create "$LABEL_ANALYZE" -R "$GITHUB_REPO" -c '#1D76DB' \\
       -d 'AI agent: analyze this issue'
     gh label create "$LABEL_IMPLEMENT" -R "$GITHUB_REPO" -c '#0E8A16' \\
       -d 'AI agent: implement the agreed approach'

4. Commit the new files in $TARGET and merge them to the default branch
   (native triggers only run workflows from the default branch).

5. Safe local test — no comments, no AI, no state pushed
   (needs gh authenticated with access to $GITHUB_REPO):
     cd $TARGET && DRY_RUN=1 bash scripts/issues-agent/agent-run.sh

Operating docs (recovery, pausing, transcripts): scripts/issues-agent/README.md
EOF
