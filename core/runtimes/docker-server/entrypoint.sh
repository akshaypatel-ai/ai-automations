#!/usr/bin/env bash
# Docker-server runtime entrypoint: clone/refresh the target repo, install
# the brains the installed agents actually use, then start the receiver.
set -euo pipefail

: "${GITHUB_REPO:?set GITHUB_REPO (owner/name) in .env}"
: "${GITHUB_PAT:?set GITHUB_PAT in .env (contents: read+write on that repo)}"

if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "cloning $GITHUB_REPO into $REPO_DIR"
  git clone "https://x-access-token:${GITHUB_PAT}@github.com/${GITHUB_REPO}.git" "$REPO_DIR"
else
  git -C "$REPO_DIR" pull --rebase --quiet || true
fi
git config --global --add safe.directory "$REPO_DIR"

# gh auth for the drivers (PRs, issues, release/run context).
export GH_TOKEN="$GITHUB_PAT"

# Install each installed agent's brain CLI once at boot.
for brain in "$REPO_DIR"/scripts/*-agent/ai/brain.sh; do
  [[ -f "$brain" ]] || continue
  # shellcheck disable=SC1090
  ( source "$brain" && echo "installing brain: $AI_NAME" && ai_install ) || \
    echo "warn: ai_install failed for $brain (runs will fail ai_check until fixed)"
done

exec node /srv/receiver.mjs
