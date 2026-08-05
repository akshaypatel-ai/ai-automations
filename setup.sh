#!/usr/bin/env bash
# ai-automations — plug-and-play AI automation installer.
#
# Usage:
#   ./setup.sh                      interactive picker
#   ./setup.sh --list               list available recipes
#   ./setup.sh <tool>/<recipe>      run one directly, e.g. ./setup.sh basecamp/board-agent
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required (brew install jq / apt install jq)" >&2; exit 1; }

recipes=()
while IFS= read -r manifest; do
  recipes+=("$manifest")
done < <(find "$ROOT/automations" -mindepth 3 -maxdepth 3 -name recipe.json 2>/dev/null | sort)

[[ ${#recipes[@]} -gt 0 ]] || { echo "error: no recipes found under automations/" >&2; exit 1; }

list() {
  local i=1 manifest dir id name desc status
  for manifest in "${recipes[@]}"; do
    dir="$(dirname "$manifest")"
    id="${dir#"$ROOT/automations/"}"
    name=$(jq -r '.name // "?"' "$manifest")
    desc=$(jq -r '.description // ""' "$manifest")
    status=$(jq -r '.status // "stable"' "$manifest")
    printf '%2d) %-26s [%s] %s\n' "$i" "$id" "$status" "$name"
    printf '    %s\n' "$desc"
    i=$((i + 1))
  done
}

run_recipe() {
  local dir="$ROOT/automations/$1"
  if [[ ! -d "$dir" ]]; then
    echo "error: unknown recipe '$1' (try ./setup.sh --list)" >&2
    exit 1
  fi
  if [[ ! -f "$dir/setup.sh" ]]; then
    echo "'$1' is designed but not yet built — the implementation spec lives at:" >&2
    echo "  automations/$1/README.md" >&2
    echo "Contributions welcome (see CONTRIBUTING.md)." >&2
    exit 1
  fi
  exec bash "$dir/setup.sh"
}

case "${1:-}" in
  --list|-l)
    list
    ;;
  "")
    echo "ai-automations — pick an automation to set up:"
    echo
    list
    echo
    read -rp "Number: " n
    [[ "$n" =~ ^[0-9]+$ ]] || { echo "error: invalid choice" >&2; exit 1; }
    idx=$((n - 1))
    [[ $idx -ge 0 && $idx -lt ${#recipes[@]} ]] || { echo "error: invalid choice" >&2; exit 1; }
    dir="$(dirname "${recipes[$idx]}")"
    run_recipe "${dir#"$ROOT/automations/"}"
    ;;
  *)
    run_recipe "$1"
    ;;
esac
