# Notion Project Agent

The board-agent flow on a Notion database: a page enters your **analyze**
status → the agent posts an analysis (options, trade-offs, recommendation) or
clarifying questions as a page comment; discuss in comments; move it to your
**implement** status → it builds the agreed change and opens a
ready-for-review PR. It never changes properties or page content and never
merges — humans own the board.

Status: **beta** — a faithful port of the production-proven board flow to
Notion's REST API + webhooks; needs live-fire testing against a real workspace.

## Event coverage (relay routes the full webhook surface)

| Handler | Notion events | Status |
|---|---|---|
| `pages` | `page.created`, `page.properties_updated`, `page.moved`, `comment.created` (content edits + deletes dropped at the edge) | ✅ implemented (analyze / respond / implement playbooks) |
| `databases` | `database.*` schema events | Routed, skips cleanly (playbook pending) |

## Notion-specific mechanics

- **Verification token**: saving the webhook URL sends a one-time
  `{"verification_token": ...}` — the relay logs it; you paste it into the
  integration UI to verify AND store it as the relay's secret. The same token
  keys every later signature.
- **Signature**: `X-Notion-Signature` = `sha256=<hex HMAC-SHA256(body)>` —
  verified at the edge.
- **Compact events**: entity id + type only, no content — doorbells by design.
- **Status property**: works with both `status` and `select` property types;
  the reconcile query reads the property type from the database schema and
  builds the right filter. Matching is case-insensitive.
- **Comments API**: page comments via `/comments?block_id=`; recency by
  `created_time` (ISO-8601). Long comments are chunked (2000-char rich_text cap).
- **Integration capabilities**: the integration needs *Read/Insert comments*
  enabled, and the database must be connected to the integration
  (••• → Connections).

## Install

```bash
./setup.sh notion/project-agent
```

Asks for: target repo, database id (the 32-hex id in the database URL), the
status property name, the two status option names, and the standard
conventions. Secrets: `NOTION_TOKEN` (internal integration secret), Claude
auth (+ optional `AGENT_GH_PAT`); relay: `GITHUB_PAT`,
`NOTION_VERIFICATION_TOKEN` (captured during verification — the installer
prints the exact flow).

## Guardrails

Comments only (never property/content edits), PRs only against your chosen
base from `<prefix>/<slug>` branches, never merges,
`--dangerously-skip-permissions` only in the disposable CI runner, `DRY_RUN=1`
local testing, full transcript artifacts per run.

## Beta → stable checklist (live-fire against a real workspace)

- [ ] Webhook verification: token captured, pasted, stored; signature verified
- [ ] analyze → respond → implement round-trip on a test page
- [ ] Status filter against both `status` and `select` property types
- [ ] Comment chunking on a >2000-char analysis
- [ ] Database-scoping filter (event for a page in another shared database is dropped)
