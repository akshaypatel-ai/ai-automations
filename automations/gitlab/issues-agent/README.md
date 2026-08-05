# GitLab Issues Agent

The label-driven board flow on GitLab Issues. GitLab boards **are**
label-driven — a board column is just a label filter — so labels are the
native columns, exactly like the GitHub Issues sibling. The tracked code
repository stays on GitHub (our runtime: GitHub Actions, PRs on GitHub);
GitLab is the issue tracker — the same tracker-here / code-there pairing the
Jira recipe uses.

Label an issue **analyze** → the agent posts an analysis (options, trade-offs,
recommendation) or clarifying questions; discuss in the comments; label it
**implement** → it builds the agreed change and opens a ready-for-review PR on
the GitHub repo titled `[GL-<iid>] <issue title>`, its body linking the GitLab
issue. It never touches labels and never merges — humans own the tracker.

Status: **beta** — a faithful port of the production-proven board flow to
GitLab's REST API; needs live-fire testing against a real project.

## Event coverage (relay routes issue + note events)

| Handler | GitLab webhook events | Status |
|---|---|---|
| `issues` | Issue hooks (`open`/`update`/`reopen`; `close` dropped at the edge), note hooks on issues | ✅ implemented (analyze / respond / implement playbooks) |
| Other object kinds | `push`, `merge_request`, `pipeline`, … | Filtered at the edge by design (the agent works issues) |

## GitLab-specific mechanics

- **Labels ARE the board columns**: GitLab issue boards are label filters, so
  the analyze/implement labels drive the flow natively — no status mapping.
- **Webhook auth**: GitLab doesn't sign payloads; every delivery carries the
  webhook form's Secret token verbatim in the `X-Gitlab-Token` header — the
  relay does a plain full-string compare.
- **System notes filtered**: label changes, milestone edits, etc. arrive as
  `system: true` notes — the resolver excludes them, so label noise never
  counts as human comments.
- **Comment recency**: numeric monotonic note ids, compared numerically (like
  Jira's).
- **GitHub PRs pair with GitLab issues**: merging a GitHub PR can't auto-close
  a GitLab issue, so there's no `Closes #n` — the PR body links the issue's
  web URL and humans close it after merging.
- **Self-hosted support**: `GITLAB_API_BASE` points at gitlab.com or your own
  instance; everything else is identical.

## Install

```bash
./setup.sh gitlab/issues-agent
```

Asks for: target repo, GitLab base URL + numeric project ID, the two label
names, and the standard conventions. Secrets: `GITLAB_TOKEN` (PAT with `api`
scope), Claude auth (+ optional `AGENT_GH_PAT`); relay secrets: `GITHUB_PAT`,
`GITLAB_WEBHOOK_TOKEN`. The installer prints the `curl` commands that create
the two labels. Re-running reads `scripts/gitlab-agent/automation.config.json`
as defaults.

## Guardrails

Comments only (never labels/close/assign), PRs only against your chosen base
from `<prefix>/gl-<iid>-<slug>` branches, never merges,
`--dangerously-skip-permissions` only in the disposable CI runner, `DRY_RUN=1`
local testing, full transcript artifacts per run.

## Beta → stable checklist (live-fire against a real project)

- [ ] Webhook token verification through the relay (X-Gitlab-Token)
- [ ] analyze → respond → implement round-trip on a test issue
- [ ] System-note exclusion on a label change (no phantom "human comment")
- [ ] Reconcile label query over both watched labels
- [ ] Self-hosted instance via a custom `GITLAB_API_BASE`
