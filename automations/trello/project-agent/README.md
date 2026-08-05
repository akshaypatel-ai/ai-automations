# Trello Project Agent

The board-agent flow on Trello: a card enters your **analyze** list → the
agent posts an analysis (options, trade-offs, recommendation) or clarifying
questions; discuss in the card's comments; move it to your **implement** list
→ it builds the agreed change and opens a ready-for-review PR titled
`[TR-<idShort>]`. It never moves cards and never merges — humans own the board.

Status: **beta** — a faithful port of the production-proven Basecamp flow to
Trello's REST API; needs live-fire testing against a real board.

## Event coverage (relay routes all board actions)

| Handler | Trello action types | Status |
|---|---|---|
| `cards` | `createCard`, `updateCard` (list moves), `commentCard`, `addAttachmentToCard`, … | ✅ implemented (analyze / respond / implement playbooks) |
| `lists` | `createList`, `updateList`, `moveList*` | Routed, skips cleanly (playbook pending) |
| `members` | `addMemberToCard`, `removeMemberFromCard` | Routed, skips cleanly (playbook pending) |
| `checklists` | checklist/check-item actions | Routed, skips cleanly (inert by design) |

## Trello-specific mechanics

- **Webhook handshake**: Trello probes the callback URL with HEAD and requires a 200 before creating the webhook — the Worker answers it.
- **Signature**: deliveries carry `x-trello-webhook` = base64 HMAC-SHA1(body + callbackURL); verified when the optional `TRELLO_API_SECRET` worker secret is set, with the URL secret as the baseline auth either way.
- **Edge noise filtering**: `updateCard` fires on every field edit — only moves into watched lists are forwarded (`data.listAfter`); comments arrive as their own `commentCard` actions.
- **Comment recency**: tracked by action `date` (ISO-8601).
- **Auth**: API key + token as query params; no CLI install needed (curl + jq).

## Install

```bash
./setup.sh trello/project-agent
```

Asks for: target repo, board id, the two list ids + display names, and the
standard conventions (tip: append `.json` to your board URL to see all ids).
Secrets: `TRELLO_KEY` + `TRELLO_TOKEN`, Claude auth (+ optional
`AGENT_GH_PAT`); relay: `GITHUB_PAT`, `WEBHOOK_SECRET`, optional
`TRELLO_API_SECRET`. The installer prints the exact `curl` command that
creates the webhook.

## Guardrails

Comments only (never moves/archives cards), PRs only against your chosen base
from `<prefix>/<slug>` branches, never merges, `--dangerously-skip-permissions`
only in the disposable CI runner, `DRY_RUN=1` local testing, full transcript
artifacts per run.

## Beta → stable checklist (live-fire against a real board)

- [ ] Webhook creation handshake (HEAD probe) through the relay
- [ ] Signature verification with `TRELLO_API_SECRET` set
- [ ] analyze → respond → implement round-trip on a test card
- [ ] Attachment download + viewing inside the analyze playbook
- [ ] Reconcile run over both watched lists
