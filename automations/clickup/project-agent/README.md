# ClickUp Project Agent — design (not yet built)

The multi-event agent pattern applied to a ClickUp space/list. Status:
**designed** — this document is the implementation spec; Basecamp and Linear
are the reference implementations to port from.

## Event coverage (webhook events → handler families)

ClickUp webhooks are created via API on a team, optionally scoped to a
space/folder/list, with an explicit `events` array:

| Handler | ClickUp events | Interaction pattern |
|---|---|---|
| `tasks` | `taskCreated`, `taskUpdated`, `taskStatusUpdated`, `taskCommentPosted`, `taskAssigneeUpdated`, `taskPriorityUpdated`, `taskDueDateUpdated`, `taskMoved`, `taskDeleted` | Board flow via statuses: analyze status → options/questions; implement status → PR; comments route to their task |
| `lists` | `listCreated`, `listUpdated`, `listDeleted` | Inert by default |
| `folders`/`spaces` | `folderCreated/Updated/Deleted`, `spaceCreated/Updated/Deleted` | Inert by default |
| `goals` | `goalCreated`, `goalUpdated`, `keyResultCreated`, `keyResultUpdated` | Progress summary on request — silent by default |
| `time` | `taskTimeEstimateUpdated`, `taskTimeTrackedUpdated` | Inert by default |

## Mechanics

- **API**: REST v2 (`https://api.clickup.com/api/v2/...`), auth: personal token in the `Authorization` header. Comments: `POST /task/{id}/comment` with `comment_text` (plain text/markdown).
- **Webhook signing**: creating the webhook returns a `secret`; every delivery carries `X-Signature` = HMAC-SHA256(body) — verify in the Worker (same WebCrypto code as Linear).
- **Statuses**: per-list status names — the resolver diffs `status.status` against saved state; configurable analyze/implement status names (like Linear/Jira).
- **`taskStatusUpdated`** gives precise doorbells (no noisy-field filtering needed); `taskUpdated` can stay unrouted.
- **Comment recency**: comment ids are numeric-ish strings with a `date` field — use `date` like Linear's `createdAt`.
- **Webhook health**: ClickUp auto-disables failing webhooks and reports `health` on `GET /team/{id}/webhook` — surface in the doctor command.

## Installer questions

Team (workspace) id, list/space scope, analyze/implement status names,
handlers, standard conventions. Secrets: `CLICKUP_TOKEN`, brain auth,
`AGENT_GH_PAT`. Relay secrets: `GITHUB_PAT`, `CLICKUP_WEBHOOK_SECRET`.
