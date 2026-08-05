# Shortcut Project Agent

The board-agent flow on Shortcut (ex-Clubhouse): a story enters your
**analyze** workflow state (e.g. To Do) → the agent posts an analysis (options,
trade-offs, recommendation) or clarifying questions; discuss in the story's
comments; move it to your **implement** state (e.g. In Progress) → it builds
the agreed change and opens a ready-for-review PR titled `[SC-<story_id>] …`.
It never moves stories or changes workflow states and never merges — humans
own the board.

Status: **beta** — a faithful port of the production-proven Basecamp/Linear
flow to Shortcut's REST v3 API; needs live-fire testing against a real workspace.

## Event coverage (relay routes the full webhook surface)

| Handler | Shortcut actions | Status |
|---|---|---|
| `stories` | `story` create · `story` update (only when `changes` includes `workflow_state_id` — other field edits dropped at the edge) · `story-comment` create | ✅ implemented (analyze / respond / implement playbooks) |
| `epics` | `epic*` | Routed, skips cleanly (playbook pending) |
| `iterations` | `iteration*` | Routed, skips cleanly (playbook pending) |

## Shortcut-specific mechanics

- **Signature**: with a secret set in the webhook form, every delivery carries `Payload-Signature` = hex HMAC-SHA256 of the raw body — the relay REQUIRES it (the installer has you set a secret).
- **Batched deliveries**: one webhook POST carries many `actions` — the relay dedupes ids across the batch and dispatches at most 10 per delivery (a reconcile run catches the rest).
- **Workflow states arrive as numeric ids** — the resolver maps them to names via `/workflows` and matches case-insensitively.
- **Comments ride inline** on the story fetch — one `GET /stories/<id>` returns story + thread.
- **Comment recency**: numeric, monotonically increasing comment ids, compared numerically.
- **Reconcile**: the search API (`state:"<name>" !is:archived`) lists stories in both watched states.

## Install

```bash
./setup.sh shortcut/project-agent
```

Asks for: target repo, the two workflow-state names, and the standard
conventions. Secrets: `SHORTCUT_TOKEN`, Claude auth (+ optional
`AGENT_GH_PAT`); relay: `GITHUB_PAT`, `SHORTCUT_WEBHOOK_SECRET` (you pick the
value — the same string goes into the webhook form). The installer prints the
exact Settings path that creates the outgoing webhook.

## Guardrails

Comments only (never workflow-state/owner changes), PRs only against your
chosen base from `<prefix>/<slug>` branches, never merges,
`--dangerously-skip-permissions` only in the disposable CI runner, `DRY_RUN=1`
local testing, full transcript artifacts per run.

## Beta → stable checklist (live-fire against a real workspace)

- [ ] Payload-Signature verification through the relay (secret set in the webhook form)
- [ ] analyze → respond → implement round-trip on a test story
- [ ] Workflow-state-name mapping against a custom (non-default) workflow
- [ ] Batch dedupe on a multi-action delivery (one dispatch per story)
- [ ] Search reconcile over a state name containing a space
