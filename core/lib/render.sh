#!/usr/bin/env bash
# {{TOKEN}} template renderer.
#
# Set RENDER_VARS to a space-separated list of variable names, then:
#   render <src> <dest>
# Pure bash substitution — values may safely contain /, &, emoji, and quotes
# (the classic sed pitfalls).

render() {
  local __src="$1" __dest="$2" __content __v
  __content="$(cat "$__src")"
  for __v in $RENDER_VARS; do
    __content="${__content//\{\{$__v\}\}/${!__v}}"
  done
  mkdir -p "$(dirname "$__dest")"
  printf '%s\n' "$__content" > "$__dest"
}

# render_check <path>... — warn (return 1) if unrendered {{TOKENS}} remain.
render_check() {
  local leftovers
  leftovers=$(grep -R -n '{{[A-Z_][A-Z_]*}}' "$@" 2>/dev/null || true)
  if [[ -n "$leftovers" ]]; then
    echo "warning: unrendered placeholders remain:" >&2
    echo "$leftovers" >&2
    return 1
  fi
  return 0
}
