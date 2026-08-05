# Jira Project Agent

The board-agent flow on Jira Cloud: an issue enters your **analyze** status
(e.g. To Do) → the agent posts an analysis (options, trade-offs,
recommendation) or clarifying questions; discuss in the issue's comments; move
it to your **implement** status (e.g. In Progress) → it builds the agreed
change and opens a ready-for-review PR titled with the issue key (Jira's
GitHub integration links it). It never transitions issues and never merges —
humans own the board.

Status: **beta** — a faithful port of the production-proven Basecamp/Linear
flow to Jira's REST API; needs live-fire testing against a real site.

## Event coverage (relay routes the full webhook surface)

| Handler | Jira webhook events | Status |
|---|---|---|
| `issues` | `jira:issue_created/updated/deleted`, `comment_created/updated` | ✅ implemented (analyze / respond / implement playbooks) |
| `sprints` | `sprint_created/started/closed` | Routed, skips cleanly (playbook pending) |
| `versions` | `jira:version_created/released` | Routed, skips cleanly (playbook pending) |
| `worklogs` | `worklog_created/updated` | Routed, skips cleanly (inert by design) |

## Jira-specific mechanics

- **Auth**: Basic `email:api_token` (both CI secrets). Comments use the v2 endpoints (plain-text/wiki-markup bodies — no ADF wrangling); reconcile searches use the current v3 `/search/jql` endpoint.
- **Webhook**: admin-registered (Settings → System → WebHooks) with a JQL filter; Jira doesn't sign these, so authentication is the secret-in-URL pattern.
- **Edge noise filtering**: `jira:issue_updated` fires on every field edit — the relay forwards only status transitions into watched statuses (from the payload's changelog), creations in one, and non-agent comments.
- **Comment recency**: numeric increasing ids — tracked like Basecamp's.
- **Done detection**: issues whose status category is `done` are skipped.

## Install

```bash
./setup.sh jira/project-agent
```

Asks for: target repo, site URL, project key, the two status names, and the
standard conventions. Secrets: `JIRA_EMAIL` + `JIRA_API_TOKEN`, Claude auth
(+ optional `AGENT_GH_PAT`); relay secrets: `GITHUB_PAT`, `WEBHOOK_SECRET`.
Re-running reads `scripts/jira-agent/automation.config.json` as defaults.

## Guardrails

Comments only (never transitions/assignments), PRs only against your chosen
base from `<prefix>/<key>-<slug>` branches, never merges,
`--dangerously-skip-permissions` only in the disposable CI runner, `DRY_RUN=1`
local testing, full transcript artifacts per run.

## Beta → stable checklist (live-fire against a real site)

- [ ] Webhook delivery through the relay (create issue in watched status)
- [ ] analyze → respond → implement round-trip on a test issue
- [ ] v2 issue/comment endpoints available on the site (else switch to v3 + ADF)
- [ ] Reconcile via `/rest/api/3/search/jql` pagination on >100 issues
- [ ] Attachment download inside the analyze playbook
