# Todoist Project Agent

The board-agent flow on Todoist: a task moves into your **analyze** section
(e.g. To Do) → the agent posts an analysis (options, trade-offs,
recommendation) or clarifying questions; discuss in the task's comments; move
it to your **implement** section (e.g. In Progress) → it builds the agreed
change and opens a ready-for-review PR. It never moves tasks and never merges
— humans own the board.

Status: **beta** — a faithful port of the production-proven board flow to
Todoist's REST v2 API; needs live-fire testing against a real account.

## Event coverage (relay routes the full webhook surface)

| Handler | Todoist events | Status |
|---|---|---|
| `tasks` | `item:*` events + `note:*` (comments), routed to the parent task | ✅ implemented (analyze / respond / implement playbooks) |
| `sections` | `section:*` events | Routed, skips cleanly (playbook pending) |
| `projects` | `project:*` events | Routed, skips cleanly (playbook pending) |

## Todoist-specific mechanics

- **App-level webhooks**: configured in the App Management console
  ([developer.todoist.com/appconsole.html](https://developer.todoist.com/appconsole.html))
  — create an app, set its Webhook callback URL, pick events. **Honest
  quirk**: webhooks only fire for accounts that have *authorized* the app —
  for personal use you complete the app's OAuth flow once with your own
  account to switch deliveries on. Until then, webhooks stay silent.
- **Signature**: every delivery carries `X-Todoist-Hmac-SHA256` = **base64**
  (not hex) HMAC-SHA256 of the raw body, keyed with the app's Client Secret —
  verified at the edge.
- **Sections are the columns**: board view = sections in a project. The task
  carries only a `section_id`, so the resolver maps id → name via the
  project's section list (case-insensitive); a task with no section (plain
  list view) skips cleanly.
- **Comments are notes**: `GET /comments?task_id=<id>`; recency by `posted_at`
  (ISO-8601). The agent's own comment echoes back as a `note:added` event —
  dropped at the edge by marker (the resolver skips marker comments too).
- **Reconcile is client-side**: REST v2 has no tasks-by-section endpoint —
  the scan resolves section names → ids, then filters
  `GET /tasks?project_id=…` by `section_id`.

## Install

```bash
./setup.sh todoist/project-agent
```

Asks for: target repo, project id (from the project URL), the two section
names, and the standard conventions. Secrets: `TODOIST_TOKEN`, Claude auth
(+ optional `AGENT_GH_PAT`); relay: `GITHUB_PAT`, `TODOIST_CLIENT_SECRET`
(from the App Management console — the installer prints the exact app +
webhook + authorize-once flow).

## Guardrails

Comments only (never moves/completes/reschedules), PRs only against your
chosen base from `<prefix>/<slug>` branches, never merges,
`--dangerously-skip-permissions` only in the disposable CI runner, `DRY_RUN=1`
local testing, full transcript artifacts per run.

## Beta → stable checklist (live-fire against a real account)

- [ ] HMAC verify: base64 signature accepted, tampered body rejected (401)
- [ ] analyze → respond → implement round-trip on a test task
- [ ] Section mapping against a board with custom section names
- [ ] App OAuth activation quirk verified (webhooks silent until authorized once)
- [ ] Note echo dropped at the edge (marker check in the relay)
