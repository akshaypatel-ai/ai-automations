# Airtable Project Agent

The board-agent flow on Airtable: a record's status field enters your
**analyze** option (e.g. Todo) → the agent posts an analysis (options,
trade-offs, recommendation) or clarifying questions as a record comment;
discuss in the record's comments; set the field to your **implement** option
(e.g. In progress) → it builds the agreed change and opens a ready-for-review
PR. It never changes record fields and never merges — humans own the board.

Status: **beta** — a faithful port of the production-proven Basecamp/Linear
flow to Airtable's Web API; needs live-fire testing against a real base.

## Event coverage (thin pings — the reconcile does the routing)

| Handler | Airtable notifications | Status |
|---|---|---|
| `records` | any `tableData` change on the watched table (records created/edited/moved between options, comments) — delivered as detail-free pings, so every ping triggers a reconcile scan | ✅ implemented (analyze / respond / implement playbooks) |

## Airtable-specific mechanics

- **Thin-ping webhooks**: notifications carry only `{base, webhook, timestamp}` — change details would require the separate payloads-cursor API. The doorbell pattern collapses Airtable's two-step webhook protocol into a ping: the relay verifies the MAC and dispatches a reconcile run; the agent's scan finds whatever changed. No cursor bookkeeping, ever.
- **MAC**: header `X-Airtable-Content-MAC` = `hmac-sha256=<hex>` — HMAC-SHA256 of the raw body, keyed with the base64-DECODED `macSecretBase64` returned at webhook creation (the relay stores the base64 string as-is and decodes it itself).
- **7-day expiry**: Airtable webhooks lapse after 7 days unless refreshed — every agent run refreshes the webhook best-effort, so an active board keeps itself alive; a dormant repo needs a manual poke after 7 quiet days.
- **Status field flavors**: a single select (plain string value) and a status-type field (object with a name) are both handled; option matching is case-insensitive.
- **Reconcile**: server-side `filterByFormula` (`{Status}='Todo'`, URL-encoded) over both watched options — field names with spaces are fine inside the braces; an option name containing a single quote is a known formula-escaping edge (checklist below).
- **Comment recency**: ISO-8601 `createdTime`, compared as strings.
- **Token scopes**: `data.records:read` + `write`, `data.recordComments:read` + `write` (the comments API needs the recordComments scopes), `schema.bases:read`, `webhook:manage`.

## Install

```bash
./setup.sh airtable/project-agent
```

Asks for: target repo, base id (app…), table id (tbl… — prefer the id from
the URL over the table name), the status + title field names, the two option
names, and the standard conventions. Secrets: `AIRTABLE_TOKEN`, Claude auth
(+ optional `AGENT_GH_PAT`); relay: `GITHUB_PAT`, `AIRTABLE_MAC_SECRET`. The
installer prints the exact `curl` command that creates the webhook (which
returns the MAC secret and the webhook id).

## Guardrails

Comments only (never field or status changes), PRs only against your chosen
base from `<prefix>/<slug>` branches, never merges,
`--dangerously-skip-permissions` only in the disposable CI runner, `DRY_RUN=1`
local testing, full transcript artifacts per run.

## Beta → stable checklist (live-fire against a real base)

- [ ] MAC verification round-trip through the relay (`hmac-sha256=` header, base64-decoded key)
- [ ] analyze → respond → implement round-trip on a test record
- [ ] filterByFormula escaping with a spaced status-field name (and an option name containing a quote)
- [ ] Webhook refresh-on-every-run + expiry behavior after 7 quiet days
- [ ] Status-type field vs single-select extraction against a real base
