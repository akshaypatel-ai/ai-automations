#!/usr/bin/env bash
# Brain selection for installers. Source after wizard.sh.
#
#   choose_brain <core/ai dir> [default-name] [mode]
#
# mode (optional 3rd arg):
#   tools     (default) Only adapters whose capabilities satisfy tool-driven
#             playbooks (CAN_RUN_TOOLS=1 — posting comments / running gh via
#             helper scripts) are selectable. Text-only adapters are listed
#             as unavailable with the reason.
#   mediated  Text-only adapters (CAN_RUN_TOOLS=0: aider, api-*) are ALSO
#             selectable — the recipe's driver delivers the brain's text
#             itself (driver-mediated write-back).
#
# Asks the user, and sets:
#   BRAIN_NAME   adapter identifier (e.g. claude-code)
#   BRAIN_FILE   absolute path to the adapter file to install as ai/brain.sh
#   AI_MODEL_DEFAULT  the adapter's default model (seed for the model question)
#   BRAIN_AUTH_VARS   space-separated secret names the workflow/CI needs

choose_brain() {
  local dir="$1" default="${2:-claude-code}" mode="${3:-tools}"
  local f names=() files=() models=() auths=() i=1 pick line suffix
  say "AI brain"
  for f in "$dir"/*.sh; do
    # Subshell so adapter vars never leak between candidates.
    line=$( (
      # shellcheck disable=SC1090
      source "$f"
      if [[ "${CAN_RUN_TOOLS:-0}" == "1" ]]; then
        printf 'ok|%s|%s|%s' "$AI_NAME" "${AI_DEFAULT_MODEL:-}" "${AI_AUTH_VARS:-}"
      elif [[ "$mode" == "mediated" ]]; then
        printf 'med|%s|%s|%s' "$AI_NAME" "${AI_DEFAULT_MODEL:-}" "${AI_AUTH_VARS:-}"
      else
        printf 'no|%s' "$AI_NAME"
      fi
    ) )
    if [[ "$line" == ok\|* || "$line" == med\|* ]]; then
      IFS='|' read -r _kind _name _model _auth <<<"$line"
      names+=("$_name"); files+=("$f"); models+=("$_model"); auths+=("$_auth")
      suffix=""
      [[ "$_kind" == "med" ]] && suffix="  (driver-mediated — the driver delivers the brain's text)"
      if [[ "$_name" == "$default" ]]; then
        note "  $i) $_name  (default)$suffix"
      else
        note "  $i) $_name$suffix"
      fi
      i=$((i + 1))
    else
      note "     ${line#no|} — text-only, not usable with these playbooks yet"
    fi
  done
  ask pick "Brain (number or name)" "$default"
  BRAIN_NAME="" BRAIN_FILE="" AI_MODEL_DEFAULT="" BRAIN_AUTH_VARS=""
  for i in "${!names[@]}"; do
    if [[ "$pick" == "${names[$i]}" || "$pick" == "$((i + 1))" ]]; then
      BRAIN_NAME="${names[$i]}"
      BRAIN_FILE="${files[$i]}"
      AI_MODEL_DEFAULT="${models[$i]}"
      BRAIN_AUTH_VARS="${auths[$i]}"
      break
    fi
  done
  [[ -n "$BRAIN_NAME" ]] || { echo "error: unknown brain '$pick'" >&2; return 1; }
}
