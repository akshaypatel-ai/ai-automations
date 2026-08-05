# Jira Project Agent — design (not yet built)

The multi-event agent pattern applied to a Jira Cloud project. Status:
**designed** — this document is the implementation spec; the Basecamp and
Linear recipes are the reference implementations to port from.

## Event coverage (full webhook surface → handler families)

| Handler | Jira webhook events | Interaction pattern |
|---|---|---|
| `issues` | `jira:issue_created`, `jira:issue_updated`, `jira:issue_deleted`, `comment_created`, `comment_updated` | Board flow via status transitions: analyze status (e.g. *To Do*) → options/questions; implement status (e.g. *In Progress*) → PR. Comments route to their issue |
| `sprints` | `sprint_created`, `sprint_started`, `sprint_closed` | Sprint-start scope summary / sprint-close recap on request — silent by default |
| `versions` | `jira:version_created`, `jira:version_released` | Release-notes draft from the version's issues, posted as a version comment/issue comment, on request |
| `worklogs` | `worklog_created`, `worklog_updated` | Inert by default (routed, skipped with a logged reason) |

## Mechanics

- **API**: REST v3 (`https://<site>.atlassian.net/rest/api/3/...`), Basic auth `email:api_token` (base64). ADF (Atlassian Document Format) for comment bodies — the helper must wrap plain markdown into ADF or use the `/rest/api/2/` endpoints which accept wiki-markup text (simpler; prefer v2 for comments).
- **Webhooks**: registered by a Jira admin (Settings → System → WebHooks) with a JQL filter (e.g. `project = NOVA`) — no signing; use the secret-in-URL pattern like Basecamp. Dynamic webhooks via OAuth apps exist but the admin-registered path is the plug-and-play one.
- **Status transitions**: the resolver diffs `fields.status.name` against saved state — identical logic to Linear's state names. Configurable analyze/implement status names.
- **Identifiers**: issue keys (`NOVA-123`) → branch `<prefix>/nova-123-<slug>`, PR title `[NOVA-123] …`. Jira's GitHub integration auto-links PRs by key.
- **Comment recency**: comment ids are numeric and increasing → the Basecamp `last_comment_id` logic ports as-is.

## Installer questions

Site URL, project key, analyze/implement status names, handlers, then the
standard conventions block. Secrets: `JIRA_EMAIL` + `JIRA_API_TOKEN`,
brain auth, `AGENT_GH_PAT`. Relay secrets: `GITHUB_PAT`, `WEBHOOK_SECRET`.

## Open questions for the build

- v2 vs v3 comment bodies (recommend v2 text for simplicity, v3 read).
- Whether to filter transitions at the edge (payload carries `changelog` — yes, mirror Linear's state-change filter).
