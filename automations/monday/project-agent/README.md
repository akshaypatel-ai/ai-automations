# Monday.com Project Agent

The board-agent flow on monday.com: an item enters your **analyze** status →
the agent posts an analysis (options, trade-offs, recommendation) or
clarifying questions as an update; discuss in the item's updates; move it to
your **implement** status → it builds the agreed change and opens a
ready-for-review PR. It never changes statuses or columns and never merges —
humans own the board.

Status: **beta** — a faithful port of the production-proven board flow to
monday.com's GraphQL API; needs live-fire testing against a real workspace.

## Event coverage (relay routes the full webhook surface)

| Handler | monday.com events | Status |
|---|---|---|
| `items` | `create_pulse`, `update_column_value` (status column only — other columns dropped at the edge), `update_name`, `create_update`, `edit_update` | ✅ implemented (analyze / respond / implement playbooks) |
| `subitems` | `create_subitem`, `change_subitem_column_value`, … | Routed, skips cleanly (playbook pending) |

## monday.com-specific mechanics

- **Challenge echo**: webhook creation POSTs `{"challenge": ...}` — the relay
  echoes it back verbatim, so `create_webhook` succeeds with zero manual steps.
- **URL-secret auth**: API-created board webhooks don't carry a portable HMAC,
  so authentication is an unguessable URL path — the same model as the
  Basecamp and Jira recipes.
- **GraphQL everywhere**: reads, comment writes (`create_update`), and
  reconcile (`items_page_by_column_values`) are all one endpoint.
- **Status columns are per-board with custom labels** — the agent watches one
  status column id and matches labels case-insensitively.
- **Comments are "updates"**; recency by `created_at` (ISO-8601).

## Install

```bash
./setup.sh monday/project-agent
```

Asks for: target repo, board id (the number in the board URL), status column
id (default `status`), the two status labels, and the standard conventions.
Secrets: `MONDAY_TOKEN` (avatar → Developers → My access tokens), Claude auth
(+ optional `AGENT_GH_PAT`); relay: `GITHUB_PAT`, `WEBHOOK_SECRET`. The
installer prints the three `create_webhook` mutations with your values.

## Guardrails

Updates only (never status/column changes), PRs only against your chosen base
from `<prefix>/<slug>` branches, never merges, `--dangerously-skip-permissions`
only in the disposable CI runner, `DRY_RUN=1` local testing, full transcript
artifacts per run.

## Beta → stable checklist (live-fire against a real workspace)

- [ ] Challenge echo verified by successful `create_webhook`
- [ ] analyze → respond → implement round-trip on a test item
- [ ] Status-label matching against a customized status column
- [ ] Reconcile via `items_page_by_column_values` on both labels
- [ ] Non-status column edits confirmed dropped at the edge
