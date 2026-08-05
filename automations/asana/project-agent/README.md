# Asana Project Agent

The board-agent flow on Asana: a task enters your **analyze** section (e.g.
To do) → the agent posts an analysis (options, trade-offs, recommendation) or
clarifying questions; discuss in the task's comments; move it to your
**implement** section (e.g. In progress) → it builds the agreed change and
opens a ready-for-review PR. It never moves tasks and never merges — humans
own the board.

Status: **beta** — a faithful port of the production-proven board flow to
Asana's REST API; needs live-fire testing against a real workspace.

## Event coverage (relay routes the full webhook surface)

| Handler | Asana events | Status |
|---|---|---|
| `tasks` | `task` events + `story` (comments) + `attachment` events, routed to the parent task | ✅ implemented (analyze / respond / implement playbooks) |
| `sections` | `section` events | Routed, skips cleanly (playbook pending) |
| `projects` | `project` events | Routed, skips cleanly (playbook pending) |

## Asana-specific mechanics

- **Handshake**: webhook creation sends `X-Hook-Secret`; the relay echoes it
  back *and logs it* — you grab it from `wrangler tail` and store it as the
  relay secret. Until it's stored, deliveries are rejected.
- **Signature**: every delivery carries `X-Hook-Signature` = hex HMAC-SHA256
  of the body, keyed with that hook secret — verified at the edge.
- **Compact batched events**: Asana sends `{events: [...]}` with gids and
  actions only — no content. The relay dedupes the batch and forwards one
  dispatch per unique item (cap 10; reconcile catches the rest). The doorbell
  pattern is *mandatory* here, not just resilient.
- **Sections are the columns**: a task's section lives in
  `memberships[]` scoped to the watched project; matching is case-insensitive.
- **Comments are stories** with `resource_subtype == "comment_added"`;
  recency by `created_at` (ISO-8601).
- **Heartbeats**: empty `{events: []}` deliveries are answered 200 and dropped.

## Install

```bash
./setup.sh asana/project-agent
```

Asks for: target repo, project gid (the long number in the project URL), the
two section names, and the standard conventions. Secrets: `ASANA_TOKEN`,
Claude auth (+ optional `AGENT_GH_PAT`); relay: `GITHUB_PAT`,
`ASANA_HOOK_SECRET` (captured during the handshake — the installer prints the
exact two-terminal flow).

## Guardrails

Comments only (never moves/assigns/completes), PRs only against your chosen
base from `<prefix>/<slug>` branches, never merges,
`--dangerously-skip-permissions` only in the disposable CI runner, `DRY_RUN=1`
local testing, full transcript artifacts per run.

## Beta → stable checklist (live-fire against a real workspace)

- [ ] Webhook handshake: secret captured via `wrangler tail`, stored, verified
- [ ] analyze → respond → implement round-trip on a test task
- [ ] Section matching against a board with custom section names
- [ ] Batched-delivery dedupe (move + comment in one delivery)
- [ ] Webhook reactivation after Asana deactivates a failing target
