# Host shims

The playbooks and scripts in this repo speak **one** host CLI: `gh`. That is a
deliberate simplification — GitHub is the default host and runtime — but it
means a run on a GitLab- or Bitbucket-hosted repo would hit
`gh: command not found` the moment a playbook tries to open a PR or file an
escalation issue.

This directory holds the honest workaround until first-class host adapters
land (Phase 3b, remaining): **shims installed on PATH *as* `gh`** that
translate the exact `gh` surface the shipped playbooks use into the native
host's CLI or API. Exact surface only — anything outside it fails loudly
(`gh-shim: unsupported: gh …`, exit 64) so a run never silently no-ops.

## The two hosts at a glance (both experimental)

|  | GitLab — [`gh-shim-gitlab.sh`](gh-shim-gitlab.sh) | Bitbucket — [`gh-shim-bitbucket.sh`](gh-shim-bitbucket.sh) |
|---|---|---|
| Backend | [`glab`](https://gitlab.com/gitlab-org/cli) CLI — must be installed and authenticated on the runner | Bitbucket REST 2.0 via `curl` + `jq` — nothing extra to install |
| Install as | `scripts/gh-shim/gh` in the target repo | `scripts/gh-shim/gh` in the target repo |
| PATH line in CI | `export PATH="$CI_PROJECT_DIR/scripts/gh-shim:$PATH"` | `export PATH="$BITBUCKET_CLONE_DIR/scripts/gh-shim:$PATH"` |
| Auth env | `GITLAB_TOKEN` — **project access token** (role Developer, scope `api`) as a masked CI/CD variable; the default `CI_JOB_TOKEN` can clone and trigger but **cannot** create MRs, issues, or notes | `BITBUCKET_TOKEN` — repo/workspace **access token** (sent as Bearer) with `pullrequest:write` + `issue:write`, as a secured repository variable; `BITBUCKET_WORKSPACE` / `BITBUCKET_REPO_SLUG` come free from Pipelines |
| Host caveats | No JSON output modes — `--json` flags are dropped → human output (playbooks tolerate) | Issues have **no labels** — `--label` becomes a `[label] ` title prefix; the repo's **issue tracker must be enabled** (Repository settings → Issue tracker) or issue creation 404s |
| Offline tests | — | [`gh-shim-bitbucket.test.sh`](gh-shim-bitbucket.test.sh) (stubbed `curl`/`git`, runs on bash 3.2) |

## Translation table

| Playbooks say | GitLab shim runs | Bitbucket shim runs |
|---|---|---|
| `gh pr create --base X --title T --body/--body-file …` | `glab mr create --target-branch X --title T --description … --yes` (prints the MR URL) | `POST /pullrequests` — source branch = current git branch, or `--head` (prints the PR URL) |
| `gh issue create --title T --label L --body/--body-file …` | `glab issue create … --label L --yes` (prints the issue URL) | `POST /issues` — no labels on Bitbucket, `L` becomes the `[L] ` title prefix (prints the issue URL) |
| `gh issue comment <url\|num> --body/--body-file …` | `glab issue note <num> --message …` | `POST /issues/<id>/comments` — id parsed from `…/issues/<id>[/slug]` URLs |
| `gh issue list --state open --label L --search S --limit N` | `glab issue list …` (one issue per line) | `GET /issues?q=state="new" OR state="open"`, then `S` filtered client-side against titles, `L` dropped — prints `<id>` TAB `<title>` TAB `<url>` per line |
| `gh issue view <url\|num> --json state` | `glab issue view <num>` (JSON flags dropped → human output; playbooks tolerate) | `GET /issues/<id>` → prints `{"state":"open"\|"closed"}` (new/open/on hold → open; resolved/closed/invalid/duplicate/wontfix → closed) |
| `gh release view TAG --json …` | `glab release view TAG` (same JSON caveat) | prints `(release info unavailable via shim)`, exit 0 |
| `gh run view ID --log-failed` | prints `(run logs unavailable via shim)`, exit 0 | prints `(run logs unavailable via shim)`, exit 0 — notify recipes are GitHub-native anyway |
| anything else (`gh api`, `gh secret`, `gh label`, `gh workflow`, …) | **exit 64** with a clear message | **exit 64** with a clear message |

Both `gh issue list` outputs differ from real `gh` formatting — the playbook
prompts only grep that output for numbers/titles/shas, which one line per
issue satisfies on either host.

## Install (once, in the target repo)

```sh
mkdir -p scripts/gh-shim
cp <ai-automations>/core/hosts/gh-shim-<host>.sh scripts/gh-shim/gh
chmod +x scripts/gh-shim/gh
```

Then the CI job prepends it to PATH:

- **GitLab** — the commented line in
  [`core/runtimes/gitlab-ci/gitlab-ci.example.yml`](../runtimes/gitlab-ci/gitlab-ci.example.yml):

  ```yaml
  - export PATH="$CI_PROJECT_DIR/scripts/gh-shim:$PATH"
  ```

- **Bitbucket** — add to the step's `script:` in `bitbucket-pipelines.yml`,
  before `agent-run.sh` (see
  [`core/runtimes/bitbucket/README.md`](../runtimes/bitbucket/README.md)):

  ```yaml
  - export PATH="$BITBUCKET_CLONE_DIR/scripts/gh-shim:$PATH"
  ```

## Honest limits

- These are translation layers, not parity: treat implement/escalation on
  GitLab and Bitbucket as **experimental** until the first-class host
  adapters ship.
- GitLab: JSON output modes don't exist — playbooks that *parse* `--json`
  output (the GitHub-native issues-agent) are out of scope; on GitLab the
  project/triage recipes' analyze/respond/implement/escalation flows are the
  target surface.
- Bitbucket: `gh issue view --json state` is answered with real JSON (the
  sentry recipe's close-check needs it); every other JSON-shaped call is out
  of scope, same as GitLab. Labels don't exist — dedupe greps keep working
  because titles carry the `[label] ` prefix the shim writes at create time.
