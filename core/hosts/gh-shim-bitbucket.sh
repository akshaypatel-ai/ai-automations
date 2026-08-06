#!/usr/bin/env bash
# gh-shim-bitbucket — a `gh` lookalike for Bitbucket-hosted repos.
#
# The playbooks in this framework speak the `gh` CLI. On a Bitbucket-hosted
# repo this shim (installed on PATH *as* `gh`) translates the EXACT surface
# the shipped playbooks and scripts use into Bitbucket REST 2.0 calls —
# pure curl + jq, no host CLI to install. Anything outside that surface
# fails loudly with exit 64 — a run must never silently no-op.
#
# Supported surface (enumerated from every shipped playbook/script):
#   gh pr create --base <b> --title <t> (--body <s>|--body-file <f>) [--head <h>]
#       → POST /pullrequests {source: --head or current git branch} → prints PR URL
#   gh issue create --title <t> [--label <l>] (--body <s>|--body-file <f>)
#       → POST /issues → prints issue URL
#         CAVEAT: Bitbucket issues have NO labels — each --label becomes a
#         "[<label>] " title prefix instead (the playbooks' dedupe greps
#         match titles, so this stays greppable).
#         CAVEAT: the repo's issue tracker must be enabled (Repository
#         settings → Issue tracker); a 404 here means it isn't.
#   gh issue comment <url|num> (--body <s>|--body-file <f>)
#       → POST /issues/<id>/comments (id parsed from …/issues/<id>[/slug] URLs)
#   gh issue list --state open [--label <l>] [--search <s>] [--limit <n>]
#       → GET /issues?q=state="new" OR state="open", then filter client-side:
#         --search matches against titles; --label is DROPPED (no labels on
#         Bitbucket — titles carry the [label] prefix, so grepping the output
#         still works). Prints one issue per line: <id>\t<title>\t<html url>
#   gh issue view <url|num> --json state
#       → GET /issues/<id> → prints {"state":"open"|"closed"}
#         (new/open/on hold → open; resolved/closed/invalid/duplicate/wontfix → closed)
#   gh release view … / gh run view …   → friendly stub line, exit 0
#   anything else (gh api, gh secret, gh label, gh workflow, …)  → exit 64
#
# Install once in the target repo (see core/hosts/README.md), then the
# pipeline prepends the shim dir to PATH. Config — all from the environment:
#   BITBUCKET_WORKSPACE, BITBUCKET_REPO_SLUG  — set automatically by Pipelines
#   BITBUCKET_TOKEN — repo/workspace access token (sent as Bearer) with
#                     pullrequest:write + issue:write scopes
set -euo pipefail

ORIG="$*"
unsupported() { echo "gh-shim: unsupported: gh $ORIG" >&2; exit 64; }
die() { echo "gh-shim: $*" >&2; exit 1; }

need_env() {
  [ -n "${BITBUCKET_WORKSPACE:-}" ] || die "BITBUCKET_WORKSPACE is not set (Bitbucket Pipelines sets it automatically)"
  [ -n "${BITBUCKET_REPO_SLUG:-}" ] || die "BITBUCKET_REPO_SLUG is not set (Bitbucket Pipelines sets it automatically)"
  [ -n "${BITBUCKET_TOKEN:-}" ] || die "BITBUCKET_TOKEN is not set (repo access token with pullrequest:write + issue:write)"
  API="https://api.bitbucket.org/2.0/repositories/$BITBUCKET_WORKSPACE/$BITBUCKET_REPO_SLUG"
}

api() { # METHOD PATH [JSON] → sets RESP (body) + STATUS (HTTP code)
  if [ $# -ge 3 ]; then
    out="$(curl -sS -X "$1" -H "Authorization: Bearer $BITBUCKET_TOKEN" \
           -H "Content-Type: application/json" --data "$3" \
           -w '\n%{http_code}' "$API$2")"
  else
    out="$(curl -sS -X "$1" -H "Authorization: Bearer $BITBUCKET_TOKEN" \
           -w '\n%{http_code}' "$API$2")"
  fi
  STATUS="${out##*$'\n'}"
  RESP="${out%$'\n'*}"
}
ok() { case "$STATUS" in 2*) ;; *) die "Bitbucket API returned $STATUS: ${RESP:0:300}" ;; esac; }

issue_id() { # issue URL (…/issues/<id>[/slug]) / "#123" / plain number → number
  id="$1"
  case "$id" in
    http://*|https://*) id="${id##*/issues/}"; id="${id%%[/?#]*}" ;;
    '#'*)               id="${id#\#}" ;;
  esac
  case "$id" in
    ''|*[!0-9]*) die "cannot extract an issue id from: $1" ;;
  esac
  printf '%s\n' "$id"
}

cmd="${1:-}" sub="${2:-}"
case "$cmd $sub" in

  'pr create')
    need_env; shift 2
    base="" title="" body="" head=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --base)      base="$2";          shift 2 ;;
        --title)     title="$2";         shift 2 ;;
        --body)      body="$2";          shift 2 ;;
        --body-file) body="$(cat "$2")"; shift 2 ;;
        --head)      head="$2";          shift 2 ;;
        -R|--repo)   shift 2 ;;  # repo comes from the Pipelines env
        *)           unsupported ;;
      esac
    done
    [ -n "$base" ] && [ -n "$title" ] || unsupported
    [ -n "$head" ] || head="$(git rev-parse --abbrev-ref HEAD)"
    api POST /pullrequests "$(jq -n --arg t "$title" --arg d "$body" --arg s "$head" --arg b "$base" \
      '{title:$t, description:$d, source:{branch:{name:$s}}, destination:{branch:{name:$b}}}')"
    ok
    printf '%s\n' "$RESP" | jq -r '.links.html.href'
    ;;

  'issue create')
    need_env; shift 2
    title="" body="" prefix=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --title)     title="$2";            shift 2 ;;
        --label)     prefix="$prefix[$2] "; shift 2 ;;  # no labels on Bitbucket → title prefix
        --body)      body="$2";             shift 2 ;;
        --body-file) body="$(cat "$2")";    shift 2 ;;
        -R|--repo)   shift 2 ;;
        *)           unsupported ;;
      esac
    done
    [ -n "$title" ] || unsupported
    api POST /issues "$(jq -n --arg t "$prefix$title" --arg b "$body" \
      '{title:$t, kind:"bug", content:{raw:$b}}')"
    [ "$STATUS" != 404 ] || die "issue create got a 404 — the repo's issue tracker is probably disabled; enable it under Repository settings → Issue tracker"
    ok
    printf '%s\n' "$RESP" | jq -r '.links.html.href'
    ;;

  'issue comment')
    need_env; shift 2
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
    id="$(issue_id "$target")"
    api POST "/issues/$id/comments" "$(jq -n --arg b "$body" '{content:{raw:$b}}')"
    ok
    printf '%s\n' "$RESP" | jq -r '.links.html.href // empty'
    ;;

  'issue list')
    need_env; shift 2
    search="" limit=50
    while [ $# -gt 0 ]; do
      case "$1" in
        --state)   [ "$2" = open ] || unsupported; shift 2 ;;  # open is the only shipped use
        --label)   shift 2 ;;  # dropped — titles carry the [label] prefix instead
        --search)  search="$2"; shift 2 ;;
        --limit)   limit="$2";  shift 2 ;;
        -R|--repo) shift 2 ;;
        *)         unsupported ;;
      esac
    done
    [ "$limit" -le 100 ] 2>/dev/null || limit=100  # Bitbucket's pagelen cap
    api GET "/issues?q=state%3D%22new%22+OR+state%3D%22open%22&pagelen=$limit"
    ok
    printf '%s\n' "$RESP" | jq -r --arg s "$search" \
      '.values[] | select(($s == "") or (.title | contains($s)))
       | [(.id|tostring), .title, .links.html.href] | @tsv'
    ;;

  'issue view')
    need_env; shift 2
    target=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --json)    shift 2 ;;  # only `state` ships; the answer is always {"state": …}
        -R|--repo) shift 2 ;;
        -*)        unsupported ;;
        *)         target="$1"; shift ;;
      esac
    done
    [ -n "$target" ] || unsupported
    id="$(issue_id "$target")"
    api GET "/issues/$id"
    ok
    printf '%s\n' "$RESP" | jq -c \
      '{state: (if (.state // "") | IN("new", "open", "on hold") then "open" else "closed" end)}'
    ;;

  'release view') echo "(release info unavailable via shim)"; exit 0 ;;
  'run view')     echo "(run logs unavailable via shim)";     exit 0 ;;

  *)
    unsupported
    ;;
esac
