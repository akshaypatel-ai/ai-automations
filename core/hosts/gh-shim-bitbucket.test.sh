#!/usr/bin/env bash
# Offline tests for gh-shim-bitbucket.sh — no network, no Bitbucket account:
# `curl` and `git` are stubbed on PATH (the stub captures method/URL/JSON body
# and replays a canned response), and every supported translation is asserted:
# URL, method, request JSON (jq-normalized compare), printed output, exit
# codes, url→id extraction, both --body forms, unsupported→64, missing env→1.
#
#   bash core/hosts/gh-shim-bitbucket.test.sh                # default bash
#   SHIM_BASH=/bin/bash bash core/hosts/gh-shim-bitbucket.test.sh   # bash 3.2
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SHIM="$HERE/gh-shim-bitbucket.sh"
SHIM_BASH="${SHIM_BASH:-bash}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ghshim-bb-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
STUB="$WORK/bin" CAP_DIR="$WORK/cap"
mkdir -p "$STUB" "$CAP_DIR"
export CAP_DIR
export STUB_BODY_FILE="$WORK/resp.json"
export STUB_STATUS=200

cat > "$STUB/curl" <<'EOF'
#!/bin/bash
# curl stub: capture method/url/body, replay $STUB_BODY_FILE + $STUB_STATUS
# in the shim's `-w '\n%{http_code}'` shape (status on the final line).
method=GET url="" data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X)         method="$2"; shift 2 ;;
    --data)     data="$2";   shift 2 ;;
    -H|-w)      shift 2 ;;
    -sS|-s|-S)  shift ;;
    *)          url="$1";    shift ;;
  esac
done
printf '%s\n' "$method" > "$CAP_DIR/method"
printf '%s\n' "$url"    > "$CAP_DIR/url"
printf '%s'   "$data"   > "$CAP_DIR/data"
cat "$STUB_BODY_FILE"
printf '%s\n' "$STUB_STATUS"
EOF

cat > "$STUB/git" <<'EOF'
#!/bin/bash
# git stub: the shim only asks for the current branch name.
if [ "${1:-}" = "rev-parse" ]; then echo "feature/current-branch"; exit 0; fi
echo "git-stub: unexpected: git $*" >&2; exit 1
EOF
chmod +x "$STUB/curl" "$STUB/git"
export PATH="$STUB:$PATH"

export BITBUCKET_WORKSPACE=testws BITBUCKET_REPO_SLUG=testrepo BITBUCKET_TOKEN=tok123
BASE_URL="https://api.bitbucket.org/2.0/repositories/testws/testrepo"

pass=0 fail=0
ok() { pass=$((pass+1)); }
ko() { fail=$((fail+1)); echo "FAIL: $1" >&2; }
assert_eq() { if [ "$2" = "$3" ]; then ok; else ko "$1: expected [$2] got [$3]"; fi; }
assert_contains() { case "$3" in *"$2"*) ok ;; *) ko "$1: [$3] does not contain [$2]" ;; esac; }
json_eq() { # desc expected-json captured-file
  e="$(printf '%s' "$2" | jq -S -c .)"
  a="$(jq -S -c . "$3" 2>/dev/null || echo PARSE_ERROR)"
  assert_eq "$1" "$e" "$a"
}
run() { # run <gh args…> → sets OUT / ERR / CODE
  OUT="$("$SHIM_BASH" "$SHIM" "$@" 2>"$WORK/err")"; CODE=$?
  ERR="$(cat "$WORK/err")"
}

# ── pr create: --body form, source branch from stubbed git ──────────────────
cat > "$STUB_BODY_FILE" <<'EOF'
{"links": {"html": {"href": "https://bitbucket.org/testws/testrepo/pull-requests/7"}}}
EOF
STUB_STATUS=201
run pr create --base main --title "[CU-1] Fix login" --body "Body text"
assert_eq "pr create exit" 0 "$CODE"
assert_eq "pr create prints PR URL" "https://bitbucket.org/testws/testrepo/pull-requests/7" "$OUT"
assert_eq "pr create method" POST "$(cat "$CAP_DIR/method")"
assert_eq "pr create url" "$BASE_URL/pullrequests" "$(cat "$CAP_DIR/url")"
json_eq "pr create json (git branch as source)" \
  '{"title":"[CU-1] Fix login","description":"Body text","source":{"branch":{"name":"feature/current-branch"}},"destination":{"branch":{"name":"main"}}}' \
  "$CAP_DIR/data"

# ── pr create: --body-file form + explicit --head ───────────────────────────
printf 'File body\nline two\n' > "$WORK/prbody.md"
run pr create --base develop --title "T2" --body-file "$WORK/prbody.md" --head feat/x
assert_eq "pr create (head) exit" 0 "$CODE"
json_eq "pr create json (--head + --body-file)" \
  '{"title":"T2","description":"File body\nline two","source":{"branch":{"name":"feat/x"}},"destination":{"branch":{"name":"develop"}}}' \
  "$CAP_DIR/data"

# ── issue create: --label → title prefix, --body-file, prints URL ───────────
cat > "$STUB_BODY_FILE" <<'EOF'
{"links": {"html": {"href": "https://bitbucket.org/testws/testrepo/issues/42/deploy-failed"}}}
EOF
STUB_STATUS=201
printf 'Expected X, got Y.\nTicket 123.\n' > "$WORK/issuebody.md"
run issue create --title "Deploy failed (abc1234)" --label agent-escalation --body-file "$WORK/issuebody.md"
assert_eq "issue create exit" 0 "$CODE"
assert_eq "issue create prints issue URL" "https://bitbucket.org/testws/testrepo/issues/42/deploy-failed" "$OUT"
assert_eq "issue create method" POST "$(cat "$CAP_DIR/method")"
assert_eq "issue create url" "$BASE_URL/issues" "$(cat "$CAP_DIR/url")"
json_eq "issue create json (label → title prefix)" \
  '{"title":"[agent-escalation] Deploy failed (abc1234)","kind":"bug","content":{"raw":"Expected X, got Y.\nTicket 123."}}' \
  "$CAP_DIR/data"

# ── issue create: --body form, no label ─────────────────────────────────────
run issue create --title "Plain" --body "inline body"
json_eq "issue create json (--body, no label)" \
  '{"title":"Plain","kind":"bug","content":{"raw":"inline body"}}' "$CAP_DIR/data"

# ── issue create: 404 → issue-tracker hint, exit 1 ──────────────────────────
STUB_STATUS=404
run issue create --title "T" --body "b"
assert_eq "issue create 404 exit" 1 "$CODE"
assert_contains "issue create 404 hint" "Repository settings → Issue tracker" "$ERR"

# ── issue comment: full URL (with slug) + --body ────────────────────────────
cat > "$STUB_BODY_FILE" <<'EOF'
{"links": {"html": {"href": "https://bitbucket.org/testws/testrepo/issues/42#comment-9"}}}
EOF
STUB_STATUS=201
run issue comment "https://bitbucket.org/testws/testrepo/issues/42/deploy-failed-abc" --body "same failure on redeploy"
assert_eq "issue comment exit" 0 "$CODE"
assert_eq "issue comment url (id from URL)" "$BASE_URL/issues/42/comments" "$(cat "$CAP_DIR/url")"
json_eq "issue comment json" '{"content":{"raw":"same failure on redeploy"}}' "$CAP_DIR/data"

# ── issue comment: bare id, -R passthrough, --body-file ─────────────────────
printf 'comment from file\n' > "$WORK/comment.md"
run issue comment 7 -R testws/testrepo --body-file "$WORK/comment.md"
assert_eq "issue comment (bare id) exit" 0 "$CODE"
assert_eq "issue comment (bare id) url" "$BASE_URL/issues/7/comments" "$(cat "$CAP_DIR/url")"
json_eq "issue comment (body-file) json" '{"content":{"raw":"comment from file"}}' "$CAP_DIR/data"

# ── issue comment: unparseable target → exit 1 ──────────────────────────────
run issue comment not-a-number --body "x"
assert_eq "issue comment bad id exit" 1 "$CODE"
assert_contains "issue comment bad id msg" "cannot extract an issue id" "$ERR"

# ── issue list: state query, label dropped, client-side --search ────────────
cat > "$STUB_BODY_FILE" <<'EOF'
{"values": [
  {"id": 1, "state": "new",  "title": "[deploy] build failed (abc1234)",
   "links": {"html": {"href": "https://bitbucket.org/testws/testrepo/issues/1/x"}}},
  {"id": 2, "state": "open", "title": "other open issue",
   "links": {"html": {"href": "https://bitbucket.org/testws/testrepo/issues/2/y"}}}
]}
EOF
STUB_STATUS=200
run issue list --state open --label deploy --search "abc1234"
assert_eq "issue list exit" 0 "$CODE"
assert_eq "issue list method" GET "$(cat "$CAP_DIR/method")"
assert_eq "issue list url (state q + default pagelen)" \
  "$BASE_URL/issues?q=state%3D%22new%22+OR+state%3D%22open%22&pagelen=50" "$(cat "$CAP_DIR/url")"
assert_eq "issue list search-filtered output" \
  "$(printf '1\t[deploy] build failed (abc1234)\thttps://bitbucket.org/testws/testrepo/issues/1/x')" "$OUT"

run issue list --state open --limit 10
assert_eq "issue list --limit url" \
  "$BASE_URL/issues?q=state%3D%22new%22+OR+state%3D%22open%22&pagelen=10" "$(cat "$CAP_DIR/url")"
assert_eq "issue list unfiltered line count" 2 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"

run issue list --state open --limit 200
assert_contains "issue list pagelen capped at 100" "pagelen=100" "$(cat "$CAP_DIR/url")"

# ── issue view: state mapping → {"state":"open"|"closed"} ───────────────────
for pair in "new=open" "open=open" "on hold=open" "resolved=closed" \
            "closed=closed" "invalid=closed" "duplicate=closed" "wontfix=closed"; do
  bb="${pair%=*}" want="${pair#*=}"
  printf '{"id": 42, "state": "%s", "title": "t"}\n' "$bb" > "$STUB_BODY_FILE"
  run issue view "https://bitbucket.org/testws/testrepo/issues/42/some-slug" --json state
  assert_eq "issue view exit ($bb)" 0 "$CODE"
  assert_eq "issue view maps $bb" "{\"state\":\"$want\"}" "$OUT"
done
assert_eq "issue view url (id from URL)" "$BASE_URL/issues/42" "$(cat "$CAP_DIR/url")"

# ── API error surfaces (non-2xx, non-404-issue-create) → exit 1 ─────────────
printf '{"error": {"message": "Access denied"}}\n' > "$STUB_BODY_FILE"
STUB_STATUS=403
run issue comment 7 --body "x"
assert_eq "API 403 exit" 1 "$CODE"
assert_contains "API 403 message" "Bitbucket API returned 403" "$ERR"
STUB_STATUS=200

# ── release view / run view: friendly stubs, exit 0 ─────────────────────────
run release view v1.2.3 --json name,tagName,body,url,publishedAt
assert_eq "release view exit" 0 "$CODE"
assert_contains "release view stub text" "unavailable via shim" "$OUT"
run run view 12345 --log-failed
assert_eq "run view exit" 0 "$CODE"
assert_contains "run view stub text" "unavailable via shim" "$OUT"

# ── anything else → exit 64 with the command echoed ─────────────────────────
run api repos/foo/bar
assert_eq "gh api exit" 64 "$CODE"
assert_contains "gh api msg" "gh-shim: unsupported: gh api repos/foo/bar" "$ERR"
run pr merge 1
assert_eq "gh pr merge exit" 64 "$CODE"
run pr create --base main --title t --draft
assert_eq "unknown flag exit" 64 "$CODE"
run issue list --state closed
assert_eq "issue list --state closed exit" 64 "$CODE"

# ── missing env vars → clear error, exit 1 ──────────────────────────────────
OUT="$(env -u BITBUCKET_TOKEN "$SHIM_BASH" "$SHIM" issue create --title t --body b 2>"$WORK/err")"; CODE=$?
assert_eq "missing BITBUCKET_TOKEN exit" 1 "$CODE"
assert_contains "missing BITBUCKET_TOKEN msg" "BITBUCKET_TOKEN is not set" "$(cat "$WORK/err")"
OUT="$(env -u BITBUCKET_WORKSPACE "$SHIM_BASH" "$SHIM" pr create --base main --title t --body b 2>"$WORK/err")"; CODE=$?
assert_eq "missing BITBUCKET_WORKSPACE exit" 1 "$CODE"
assert_contains "missing BITBUCKET_WORKSPACE msg" "BITBUCKET_WORKSPACE is not set" "$(cat "$WORK/err")"
OUT="$(env -u BITBUCKET_REPO_SLUG "$SHIM_BASH" "$SHIM" issue list --state open 2>"$WORK/err")"; CODE=$?
assert_eq "missing BITBUCKET_REPO_SLUG exit" 1 "$CODE"
assert_contains "missing BITBUCKET_REPO_SLUG msg" "BITBUCKET_REPO_SLUG is not set" "$(cat "$WORK/err")"

echo "gh-shim-bitbucket tests ($("$SHIM_BASH" --version | head -1)): pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
