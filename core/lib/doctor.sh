#!/usr/bin/env bash
# Post-install health check: `./setup.sh doctor <target-repo-path>`.
# Finds every installed agent in the target repo and verifies what CAN be
# verified locally. Secrets live in GitHub/Cloudflare stores, so credential
# presence is a WARN (expected locally), never a FAIL.

DOCTOR_PASS=0
DOCTOR_WARN=0
DOCTOR_FAIL=0

_ok()   { DOCTOR_PASS=$((DOCTOR_PASS + 1)); printf '  ✓ %s\n' "$1"; }
_warn() { DOCTOR_WARN=$((DOCTOR_WARN + 1)); printf '  ! %s\n' "$1"; }
_bad()  { DOCTOR_FAIL=$((DOCTOR_FAIL + 1)); printf '  ✗ %s\n' "$1"; }

doctor_agent() { # doctor_agent <root> <target> <agent_dir>
  local root="$1" target="$2" dir="$3"
  local config="$dir/automation.config.json"
  local recipe brain model manifest req wf name

  name="$(basename "$dir")"
  recipe=$(jq -r '.recipe // "?"' "$config" 2>/dev/null)
  brain=$(jq -r '.brain // .ai_brain // "?"' "$config" 2>/dev/null)
  model=$(jq -r '.ai_model // .claude_model // "?"' "$config" 2>/dev/null)
  echo
  echo "── $name  (recipe: $recipe · brain: $brain · model: $model)"

  # 1. Config parses.
  if jq -e . "$config" >/dev/null 2>&1; then
    _ok "automation.config.json valid"
  else
    _bad "automation.config.json missing or invalid"
  fi

  # 2. Every script parses; env.sh sources.
  local f bad=0
  for f in "$dir"/*.sh; do
    bash -n "$f" 2>/dev/null || { _bad "syntax error: ${f#"$target/"}"; bad=1; }
  done
  [[ $bad -eq 0 ]] && _ok "all scripts parse"
  if [[ -f "$dir/env.sh" ]] && bash -c "source '$dir/env.sh'" 2>/dev/null; then
    _ok "env.sh sources cleanly"
  else
    _bad "env.sh missing or fails to source"
  fi

  # 3. No leftover template tokens anywhere in the install.
  if grep -rqE '\{\{[A-Z_]+\}\}' "$dir" 2>/dev/null; then
    _bad "unrendered {{TOKENS}} remain (re-run the installer)"
  else
    _ok "no leftover template tokens"
  fi

  # 4. Brain adapter present; deps checked (credentials are a warn locally).
  if [[ -f "$dir/ai/brain.sh" ]]; then
    local ai_name
    ai_name=$(bash -c "source '$dir/ai/brain.sh' && printf '%s' \"\$AI_NAME\"" 2>/dev/null)
    _ok "brain installed: ${ai_name:-unknown}"
    if bash -c "source '$dir/env.sh' 2>/dev/null; source '$dir/ai/brain.sh' && ai_check" >/dev/null 2>&1; then
      _ok "brain deps + credentials usable here"
    else
      _warn "brain check not passing locally (fine if credentials only live in CI)"
    fi
  else
    _bad "ai/brain.sh missing"
  fi

  # 5. Workflow installed on this repo.
  wf=$(ls "$target/.github/workflows/"*"${name%-agent}"* 2>/dev/null | head -1)
  if [[ -n "$wf" ]]; then
    _ok "workflow present: ${wf#"$target/"}"
  else
    _warn "no matching workflow found under .github/workflows/"
  fi

  # 6. Relay (when the recipe has one): rendered wrangler.toml.
  if [[ -d "$dir/relay" ]]; then
    if [[ -f "$dir/relay/wrangler.toml" ]]; then
      _ok "relay present (deploy state can't be checked offline — 'wrangler deployments list' shows it)"
    else
      _bad "relay/wrangler.toml missing (re-run the installer)"
    fi
  fi

  # 7. Recipe requirements installed on this machine.
  manifest="$root/automations/$recipe/recipe.json"
  if [[ -f "$manifest" ]]; then
    for req in $(jq -r '.requires[]' "$manifest" 2>/dev/null); do
      if command -v "$req" >/dev/null 2>&1; then
        _ok "requirement: $req"
      else
        _warn "requirement not on this machine: $req"
      fi
    done
  fi

  # 8. State branch (stateful recipes only — env.sh declares STATE_BRANCH).
  local state_branch
  state_branch=$(bash -c "source '$dir/env.sh' 2>/dev/null && printf '%s' \"\${STATE_BRANCH:-}\"" 2>/dev/null)
  if [[ -n "$state_branch" ]]; then
    if git -C "$target" ls-remote --exit-code origin "$state_branch" >/dev/null 2>&1; then
      _ok "state branch exists on origin: $state_branch"
    else
      _warn "state branch '$state_branch' not on origin yet (created on the first real run)"
    fi
  fi
}

doctor() { # doctor <root> <target-path>
  local root="$1" target_in="$2" target dir found=0
  target_in="${target_in/#\~/$HOME}"
  target="$(cd "$target_in" 2>/dev/null && pwd)" || { echo "error: no such directory: $target_in" >&2; return 1; }
  [[ -d "$target/.git" ]] || { echo "error: not a git repository: $target" >&2; return 1; }

  echo "doctor: $target"
  for dir in "$target"/scripts/*-agent; do
    [[ -f "$dir/automation.config.json" ]] || continue
    found=1
    doctor_agent "$root" "$target" "$dir"
  done
  [[ $found -eq 1 ]] || { echo "no installed agents found (looked for scripts/*-agent/automation.config.json)"; return 1; }

  echo
  echo "── summary: $DOCTOR_PASS ok · $DOCTOR_WARN warnings · $DOCTOR_FAIL failures"
  [[ $DOCTOR_FAIL -eq 0 ]]
}
