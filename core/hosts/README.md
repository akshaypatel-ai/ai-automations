# Host shims

The playbooks and scripts in this repo speak **one** host CLI: `gh`. That is a
deliberate simplification — GitHub is the default host and runtime — but it
means a run on a GitLab-hosted repo would hit `gh: command not found` the
moment a playbook tries to open an MR or file an escalation issue.

This directory holds the honest workaround until first-class host adapters
land (Phase 3b, remaining): **shims installed on PATH *as* `gh`** that
translate the exact `gh` surface the shipped playbooks use into the native
host's CLI. Exact surface only — anything outside it fails loudly
(`gh-shim: unsupported: gh …`, exit 64) so a run never silently no-ops.

## `gh-shim-gitlab.sh` (experimental)

Translates to [`glab`](https://gitlab.com/gitlab-org/cli) (must be installed
and authenticated on the runner):

| Playbooks say | Shim runs |
|---|---|
| `gh pr create --base X --title T --body/--body-file …` | `glab mr create --target-branch X --title T --description … --yes` (prints the MR URL) |
| `gh issue create --title T --label L --body/--body-file …` | `glab issue create … --yes` (prints the issue URL) |
| `gh issue comment <url\|num> --body/--body-file …` | `glab issue note <num> --message …` |
| `gh issue list --state open --label L --search S --limit N` | `glab issue list …` (one issue per line — enough for the dedupe greps) |
| `gh issue view <url\|num> --json …` | `glab issue view <num>` (JSON flags dropped → human output; playbooks tolerate) |
| `gh release view TAG --json …` | `glab release view TAG` (same JSON caveat) |
| `gh run view ID --log-failed` | prints `(run logs unavailable via shim)`, exit 0 — notify recipes are GitHub-native anyway |
| anything else (`gh api`, `gh secret`, `gh label`, `gh workflow`, …) | **exit 64** with a clear message |

### Install (once, in the target GitLab repo)

```sh
mkdir -p scripts/gh-shim
cp <ai-automations>/core/hosts/gh-shim-gitlab.sh scripts/gh-shim/gh
chmod +x scripts/gh-shim/gh
```

Then the CI job prepends it to PATH (the commented line in
[`core/runtimes/gitlab-ci/gitlab-ci.example.yml`](../runtimes/gitlab-ci/gitlab-ci.example.yml)):

```yaml
- export PATH="$CI_PROJECT_DIR/scripts/gh-shim:$PATH"
```

### Auth

`glab` needs a token that can write: set a **project access token** (role
Developer, scope `api`) as a masked CI/CD variable `GITLAB_TOKEN`. The
default `CI_JOB_TOKEN` can clone and trigger but **cannot** create MRs,
issues, or notes — the shim will run, and glab will fail with GitLab's own
permission error.

### Honest limits

- JSON output modes don't exist here — playbooks that *parse* `--json` output
  (the GitHub-native issues-agent) are out of scope; on GitLab the
  project/triage recipes' analyze/respond/implement/escalation flows are the
  target surface.
- `gh issue list` output formatting differs from `gh` — the playbook prompts
  only grep it for numbers/titles, which glab's one-line-per-issue table
  satisfies.
- This is a translation layer, not parity: treat implement/escalation on
  GitLab as **experimental** until the first-class host adapters ship.
