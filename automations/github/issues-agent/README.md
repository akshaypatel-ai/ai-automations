# GitHub Issues Agent

The board-agent flow on GitHub Issues, and the **cheapest recipe in the
collection**: GitHub is both the tool and the runtime, so there is **no relay,
no webhook, no Cloudflare account, and no extra tool token** — native Actions
triggers and the built-in `GITHUB_TOKEN` do everything.

Label an issue **analyze** → the agent posts an analysis (options, trade-offs,
recommendation) or clarifying questions; discuss in the comments; label it
**implement** → it builds the agreed change and opens a ready-for-review PR.
It never touches labels and never merges — humans own the tracker.

Status: **beta** — a faithful port of the production-proven board flow;
needs live-fire testing on a real repository.

## Event coverage (native triggers replace the relay)

| Handler | GitHub events | Status |
|---|---|---|
| `issues` | `issues: labeled` (watched labels only), `issue_comment: created` | ✅ implemented (analyze / respond / implement playbooks) |
| Pull requests | `issue_comment` on PRs | Filtered at the edge by design (the agent works issues, not PR review) |

## GitHub-specific mechanics

- **Zero relay**: the workflow's `if:` guard does the edge filtering a relay
  would — watched labels only, no bot comments, no marker echoes, no PRs.
- **Labels are the columns**: `labeled` events fire exactly once per label
  application — precise doorbells, no transition inference needed.
- **Public-repo security model**: strangers can open issues, but nothing runs
  until a maintainer applies a watched label.
- **Comment recency**: numeric comment ids, compared numerically.
- **Loop protection is double-layered**: with the default `GITHUB_TOKEN`,
  GitHub never triggers workflows from the agent's own comments; with
  `AGENT_GH_PAT`, the marker guard catches them at the edge.

## Install

```bash
./setup.sh github/issues-agent
```

Asks for: target repo, the two label names, and the standard conventions.
Secrets: Claude auth only (+ optional `AGENT_GH_PAT` so agent PRs trigger CI).
The installer prints the `gh label create` commands.

## Guardrails

Comments only (never labels/close/assign), PRs only against your chosen base
from `<prefix>/<slug>` branches, never merges, `--dangerously-skip-permissions`
only in the disposable CI runner, `DRY_RUN=1` local testing, full transcript
artifacts per run.

## Beta → stable checklist (live-fire on a real repository)

- [ ] analyze → respond → implement round-trip on a test issue
- [ ] Edge guard: bot comments, marker echoes, and PR comments never trigger runs
- [ ] Reconcile run over both watched labels
- [ ] `AGENT_GH_PAT` path: agent PRs trigger the repo's own CI
- [ ] >100-comment issue (pagination) behaves sanely
