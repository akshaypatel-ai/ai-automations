#!/usr/bin/env bash
# State backend: git orphan branch. Installed into a target repo as
# <agent-dir>/state.sh. Restores/saves per-item JSON state kept on a dedicated
# branch (default name comes from the recipe's env.sh via STATE_BRANCH).
#
# Usage: state.sh restore | state.sh save [commit message]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

STATE_BRANCH="${STATE_BRANCH:-agent-state}"

remote_url() {
  if [[ -n "${GH_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
    echo "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
  else
    git config --get remote.origin.url
  fi
}

restore() {
  rm -rf "$STATE_DIR"
  if git ls-remote --exit-code --heads "$(remote_url)" "$STATE_BRANCH" >/dev/null 2>&1; then
    git clone --quiet --depth 1 --branch "$STATE_BRANCH" "$(remote_url)" "$STATE_DIR"
  else
    git init --quiet --initial-branch "$STATE_BRANCH" "$STATE_DIR"
    git -C "$STATE_DIR" remote add origin "$(remote_url)"
  fi
  mkdir -p "$STATE_DIR/state"
  echo "state: restored into $STATE_DIR"
}

save() {
  local message="${1:-agent: update state}"
  git -C "$STATE_DIR" add -A
  if git -C "$STATE_DIR" diff --cached --quiet; then
    echo "state: nothing to save"
    return 0
  fi
  git -C "$STATE_DIR" \
    -c user.name="ai-automations-agent" \
    -c user.email="agent@users.noreply.github.com" \
    commit --quiet -m "$message"
  for _attempt in 1 2 3; do
    if git -C "$STATE_DIR" push --quiet origin "HEAD:$STATE_BRANCH" 2>/dev/null; then
      echo "state: saved"
      return 0
    fi
    git -C "$STATE_DIR" pull --quiet --rebase origin "$STATE_BRANCH" || true
  done
  echo "state: push failed after retries" >&2
  return 1
}

case "${1:-}" in
  restore) restore ;;
  save) shift; save "$@" ;;
  *) echo "usage: state.sh restore|save [message]" >&2; exit 1 ;;
esac
