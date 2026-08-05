# Linear Project Agent

The board-agent flow, on Linear: an issue enters your **analyze** workflow
state (e.g. Todo/Triage) → the agent posts an analysis (options, trade-offs,
recommendation) or clarifying questions; discuss with it in the issue's
comments; move the issue to your **implement** state (e.g. In Progress) → it
builds the agreed change and opens a ready-for-review PR titled with the issue
identifier (Linear auto-links it). It never changes issue states and never
merges — humans own the board.

Status: **beta** — a faithful port of the production-proven Basecamp flow to
Linear's GraphQL API; needs live-fire testing against a real workspace
(see the checklist below).

```
Linear webhook (HMAC-SHA256 verified at the edge)
  → Cloudflare Worker relay             files/scripts/linear-agent/relay/worker.js
  → repository_dispatch                 files/.github/workflows/linear-agent.yml
  → agent-run.sh                        restore state → resolve → playbook → save state
       → resolve-item.sh                diff Linear vs saved state → analyze|respond|implement|skip
       → run-playbook.sh                headless AI runs playbooks/<name>.md via ai/brain.sh
```

## Event coverage

The relay routes all Linear webhook resource types by handler family —
`issues` (Issue + Comment), `projects` (Project + ProjectUpdate), `cycles`,
`docs` (Document). **Fully implemented today: `issues`.** The other families
skip cleanly at the resolver with a logged reason until their playbooks land —
subscribing the webhook to extra resource types is harmless.

Linear-specific mechanics worth knowing:

- **Signature verification, not URL secrets** — Linear signs every delivery (HMAC-SHA256, `linear-signature` header); the Worker verifies before parsing.
- **Edge noise filtering** — issue *update* events fire on every field edit; the relay forwards only state changes into watched states (creation included). Comments arrive as their own events.
- **UUID comment ids** — recency is tracked by `createdAt` (ISO-8601), not id ordering.
- **No CLI needed** — the runner talks GraphQL via `curl`+`jq` (`api.sh`, `comment.sh` helpers; the same helpers are handed to the AI in its prompt).

## Install

```bash
./setup.sh linear/project-agent
```

Asks for: target repo, team key (the `ENG` in `ENG-123`), the two workflow
state names, and the usual conventions (agent name, audience, branch prefix,
PR base, quick-QA command, model). Re-running reads
`scripts/linear-agent/automation.config.json` as defaults. Secrets:
`LINEAR_API_KEY` + one Claude auth secret (+ optional `AGENT_GH_PAT`);
relay secrets: `GITHUB_PAT`, `LINEAR_WEBHOOK_SECRET`.

## Guardrails

Same contract as every recipe: comments only (never state/assignee/label
changes), PRs only against your chosen base from `<prefix>/<identifier>-<slug>`
branches, never merges, `--dangerously-skip-permissions` only in the disposable
CI runner, `DRY_RUN=1` for safe local testing, full transcript artifacts per run.

## Beta → stable checklist (live-fire against a real workspace)

- [ ] Webhook delivery + signature verification (create issue in watched state)
- [ ] analyze → respond → implement round-trip on a test issue
- [ ] Comment recency logic with rapid back-to-back comments
- [ ] Reconcile run with empty `item_id` (both watched states)
- [ ] Identifier-based manual run (`ENG-123` as `item_id`)
- [ ] PR auto-linking from the identifier in the PR title
