# ClickUp Project Agent

The board-agent flow on ClickUp: a task enters your **analyze** status (e.g.
to do) → the agent posts an analysis (options, trade-offs, recommendation) or
clarifying questions; discuss in the task's comments; move it to your
**implement** status (e.g. in progress) → it builds the agreed change and opens
a ready-for-review PR. It never changes task statuses and never merges —
humans own the board.

Status: **beta** — a faithful port of the production-proven Basecamp/Linear
flow to ClickUp's REST v2 API; needs live-fire testing against a real workspace.

## Event coverage (relay routes the full webhook surface)

| Handler | ClickUp events | Status |
|---|---|---|
| `tasks` | `taskCreated`, `taskStatusUpdated`, `taskCommentPosted`, `taskMoved` (noisy field-edit events dropped at the edge) | ✅ implemented (analyze / respond / implement playbooks) |
| `lists` / `folders` | `list*`, `folder*`, `space*` | Routed, skips cleanly (playbook pending) |
| `goals` | `goal*`, `keyResult*` | Routed, skips cleanly (playbook pending) |
| `time` | `taskTime*` | Routed, skips cleanly (inert by design) |

## ClickUp-specific mechanics

- **Signature**: every delivery carries `X-Signature` = hex HMAC-SHA256 of the body, keyed with the secret returned at webhook creation — verified at the edge.
- **Precise doorbells**: `taskStatusUpdated` fires exactly on status changes, so there is less edge filtering to do than on Jira/Trello.
- **Statuses are per-list and lowercase** — matching is case-insensitive.
- **Comment recency**: ms-epoch `date` field, compared numerically.
- **Webhook health**: ClickUp auto-disables failing webhooks; `GET /team/<id>/webhook` shows health for debugging.

## Install

```bash
./setup.sh clickup/project-agent
```

Asks for: target repo, team (workspace) id, list id, the two status names, and
the standard conventions. Secrets: `CLICKUP_TOKEN`, Claude auth (+ optional
`AGENT_GH_PAT`); relay: `GITHUB_PAT`, `CLICKUP_WEBHOOK_SECRET`. The installer
prints the exact `curl` command that creates the webhook (which returns the
secret).

## Guardrails

Comments only (never status/assignee changes), PRs only against your chosen
base from `<prefix>/<slug>` branches, never merges,
`--dangerously-skip-permissions` only in the disposable CI runner, `DRY_RUN=1`
local testing, full transcript artifacts per run.

## Beta → stable checklist (live-fire against a real workspace)

- [ ] Webhook creation + X-Signature verification through the relay
- [ ] analyze → respond → implement round-trip on a test task
- [ ] Status-name matching against a custom status set
- [ ] Reconcile run over both watched statuses (client-side filter)
- [ ] Webhook health recovery after a failed delivery burst
