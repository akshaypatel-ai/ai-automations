#!/usr/bin/env bash
# gh-shim-gitlab — a `gh` lookalike for GitLab-hosted repos.
#
# The playbooks in this framework speak the `gh` CLI. On a GitLab-hosted repo
# this shim (installed on PATH *as* `gh`) translates the EXACT surface the
# shipped playbooks and scripts use into `glab` calls. Anything outside that
# surface fails loudly with exit 64 — a run must never silently no-op.
#
# Supported surface (enumerated from every shipped playbook/script):
#   gh pr create --base <b> --title <t> (--body <s>|--body-file <f>)   → glab mr create (prints MR URL)
#   gh issue create --title <t> [--label <l>] (--body <s>|--body-file <f>) → glab issue create (prints URL)
#   gh issue comment <url|num> (--body <s>|--body-file <f>)            → glab issue note
#   gh issue list [--state ...] [--label <l>] [--search <q>] [--limit <n>] → glab issue list (one issue per line)
#   gh issue view <url|num> [--json ...]   → glab issue view (JSON flags ignored — human output)
#   gh release view <tag> [--json ...]     → glab release view (JSON flags ignored — human output)
#   gh run view <id> --log-failed          → stub line, exit 0 (no GitLab equivalent; notify recipes are GitHub-native)
#   anything else (gh api, gh secret, gh label, gh workflow, …)        → exit 64
#
# Install once in the target repo (see core/hosts/README.md), then CI prepends
# the shim dir to PATH. Auth: glab must be authenticated on the runner
# (GITLAB_TOKEN project access token — CI_JOB_TOKEN cannot create MRs/issues).
set -euo pipefail

ORIG="$*"
unsupported() { echo "gh-shim: unsupported: gh $ORIG" >&2; exit 64; }

num_from() { # issue URL / "#123" / plain number → plain number
  case "$1" in
    http://*|https://*) printf '%s\n' "${1##*/}" ;;
    '#'*)               printf '%s\n' "${1#\#}" ;;
    *)                  printf '%s\n' "$1" ;;
  esac
}

cmd="${1:-}" sub="${2:-}"
case "$cmd $sub" in

  'pr create')
    shift 2
    base="" title="" body=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --base)      base="$2";          shift 2 ;;
        --title)     title="$2";         shift 2 ;;
        --body)      body="$2";          shift 2 ;;
        --body-file) body="$(cat "$2")"; shift 2 ;;
        --head)      shift 2 ;;  # source branch = current branch, glab's default
        -R|--repo)   shift 2 ;;  # repo comes from the GitLab remote
        *)           unsupported ;;
      esac
    done
    [ -n "$base" ] && [ -n "$title" ] || unsupported
    exec glab mr create --target-branch "$base" --title "$title" --description "$body" --yes
    ;;

  'issue create')
    shift 2
    title="" body=""
    labels=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --title)     title="$2";           shift 2 ;;
        --label)     labels+=("$2");       shift 2 ;;
        --body)      body="$2";            shift 2 ;;
        --body-file) body="$(cat "$2")";   shift 2 ;;
        -R|--repo)   shift 2 ;;
        *)           unsupported ;;
      esac
    done
    [ -n "$title" ] || unsupported
    args=(--title "$title" --description "$body")
    for l in ${labels[@]+"${labels[@]}"}; do args+=(--label "$l"); done
    exec glab issue create "${args[@]}" --yes
    ;;

  'issue comment')
    shift 2
    target="" body=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --body)      body="$2";          shift 2 ;;
        --body-file) body="$(cat "$2")"; shift 2 ;;
        -R|--repo)   shift 2 ;;
        -*)          unsupported ;;
        *)           target="$1";        shift ;;
      esac
    done
    [ -n "$target" ] || unsupported
    exec glab issue note "$(num_from "$target")" --message "$body"
    ;;

  'issue list')
    shift 2
    args=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --state)
          case "$2" in
            open)   ;;                     # glab's default
            closed) args+=(--closed) ;;
            all)    args+=(--all) ;;
            *)      unsupported ;;
          esac; shift 2 ;;
        --label)   args+=(--label "$2");    shift 2 ;;
        --search)  args+=(--search "$2");   shift 2 ;;
        --limit)   args+=(--per-page "$2"); shift 2 ;;
        -R|--repo) shift 2 ;;
        *)         unsupported ;;            # incl. --json/--jq — no JSON here
      esac
    done
    # Best-effort: glab prints one issue per line (number + title) — close
    # enough for the playbooks' dedupe greps.
    exec glab issue list ${args[@]+"${args[@]}"}
    ;;

  'issue view')
    shift 2
    target=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --json|--jq) shift 2 ;;  # unsupported → human output; playbooks tolerate
        -R|--repo)   shift 2 ;;
        -*)          unsupported ;;
        *)           target="$1"; shift ;;
      esac
    done
    [ -n "$target" ] || unsupported
    exec glab issue view "$(num_from "$target")"
    ;;

  'release view')
    shift 2
    tag=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --json)    shift 2 ;;    # unsupported → human output; playbooks tolerate
        -R|--repo) shift 2 ;;
        -*)        unsupported ;;
        *)         tag="$1"; shift ;;
      esac
    done
    [ -n "$tag" ] || unsupported
    exec glab release view "$tag"
    ;;

  'run view')
    echo "(run logs unavailable via shim)"
    exit 0
    ;;

  *)
    unsupported
    ;;
esac
