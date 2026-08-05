#!/usr/bin/env bash
# Interactive wizard helpers shared by recipe installers. bash 3.2-safe (macOS).

say()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
note() { printf '%s\n' "$*"; }

# ask VAR "prompt" ["default"] — empty/missing default makes the answer required.
ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __reply
  if [[ -n "$__default" ]]; then
    read -rp "$__prompt [$__default]: " __reply || true
    printf -v "$__var" '%s' "${__reply:-$__default}"
  else
    while :; do
      read -rp "$__prompt: " __reply || true
      if [[ -n "$__reply" ]]; then
        printf -v "$__var" '%s' "$__reply"
        break
      fi
      echo "  (required)"
    done
  fi
}

# ask_opt VAR "prompt" ["default"] — Enter with no default leaves the value empty.
ask_opt() {
  local __var="$1" __prompt="$2" __default="${3:-}" __reply
  if [[ -n "$__default" ]]; then
    read -rp "$__prompt [$__default]: " __reply || true
    printf -v "$__var" '%s' "${__reply:-$__default}"
  else
    read -rp "$__prompt (Enter to skip): " __reply || true
    printf -v "$__var" '%s' "$__reply"
  fi
}

# confirm "prompt" — returns 0 only on an explicit yes.
confirm() {
  local __reply
  read -rp "$1 [y/N] " __reply || true
  [[ "$__reply" =~ ^[Yy] ]]
}

# need <cmd>... — exit with one combined message when dependencies are missing.
need() {
  local missing=0 c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { echo "error: '$c' is required" >&2; missing=1; }
  done
  [[ $missing -eq 0 ]] || exit 1
}
