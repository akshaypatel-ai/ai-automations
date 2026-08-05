# Trello Project Agent — design (not yet built)

The multi-event agent pattern applied to a Trello board. Status: **designed** —
this document is the implementation spec; Basecamp is the closest reference
implementation (Trello is also column-based).

## Event coverage (webhook actions → handler families)

Trello webhooks fire on a *model* (watch the board) and deliver `action`
objects. Families by `action.type`:

| Handler | Trello action types | Interaction pattern |
|---|---|---|
| `cards` | `createCard`, `updateCard` (incl. list moves via `data.listAfter`), `commentCard`, `addAttachmentToCard` | Board flow: analyze list → options/questions; implement list → PR; comments route to their card |
| `lists` | `createList`, `updateList`, `moveListFromBoard` | Inert by default (routed, skipped with a logged reason) |
| `members` | `addMemberToCard`, `removeMemberFromCard` | Optional trigger: assigning the agent's member = "analyze this" |
| `checklists` | `addChecklistToCard`, `updateCheckItemStateOnCard` | Inert by default |

## Mechanics

- **API**: REST (`https://api.trello.com/1/...`), auth via `key` + `token` query params. Plain-text comments (`POST /cards/{id}/actions/comments`).
- **Webhook creation quirk**: `POST /1/webhooks` with `idModel=<board id>` — Trello immediately sends a `HEAD` request to the callback URL and requires a 200 **before** creating the webhook. The relay Worker must answer `HEAD` (and `GET`) with 200 — a two-line addition to the Basecamp worker.
- **List moves**: `updateCard` with `data.listAfter.name` — the resolver diffs list ids exactly like Basecamp columns. Watch two lists (analyze/implement) by id.
- **Comment recency**: action ids are chronological — usable like Basecamp's comment ids (or use `date`).
- **Deactivation**: `PUT /1/webhooks/{id}` with `active=false` (pause switch).

## Installer questions

Board id, analyze/implement list ids + names, handlers, standard conventions.
Secrets: `TRELLO_KEY` + `TRELLO_TOKEN`, brain auth, `AGENT_GH_PAT`.
Relay secrets: `GITHUB_PAT`, `WEBHOOK_SECRET` (Trello sends an HMAC header
`x-trello-webhook` — verify it in the Worker: base64 HMAC-SHA1 of body+callbackURL).
