# Freshdesk Triage Agent

Support triage with a human between the agent and the customer: a ticket
arrives → the agent reads it, grounds itself in your product's repository, and
posts ONE **private note** — a category plus a draft reply the human agent can
send nearly verbatim; real product bugs get escalated as GitHub issues.
Customer follow-ups refresh the note; when a human has already replied, the
agent stays silent. It never messages customers and never touches ticket
status — humans own the queue.

Status: **beta** — ports the production-proven Zendesk triage flow to
Freshdesk's automation-rule webhook model; needs live-fire testing against a
real Freshdesk instance.

## Event coverage (relay routes whatever your automation rules send)

| Handler | Fed by | Status |
|---|---|---|
| `tickets` | Freshdesk automation rules on "Ticket Creation" + "Ticket Updates: Note/Reply added" (JSON bodies below) | ✅ implemented (triage / respond playbooks) |
| anything else | any other rule/webhook pointed at the relay | Routed, skips cleanly (no `ticket_id` → ignored at the edge) |

## Freshdesk-specific mechanics

- **Unsigned automation webhooks**: Freshdesk's "Trigger Webhook" rule action carries no HMAC — there is nothing to verify at the edge. Authentication is the secret embedded in the URL path (`/hook/<WEBHOOK_SECRET>`), the same model as the Jira/monday/Confluence recipes: treat the full URL like a password.
- **Rules define the payload**: this recipe uses two automation rules with the literal bodies `{"ticket_id": "{{ticket.id}}", "event": "created"}` (on Ticket Creation) and `{"ticket_id": "{{ticket.id}}", "event": "updated"}` (on Ticket Updates → Note/Reply added).
- **API key as basic-auth username**: `curl -u "$FRESHDESK_API_KEY:X"` — the password is ignored.
- **Numeric statuses**: 2=open, 3=pending, 4=resolved, 5=closed — the resolver maps them to words for the decision JSON and skips resolved/closed tickets.
- **The opening message is not a conversation**: the requester's first message is the ticket's `description_text`; only follow-ups live in `GET /tickets/{id}/conversations` (as `body_text`). Untracked tickets go to triage regardless, so nothing is lost.
- **Conversation recency**: conversation ids are numeric and monotonic — compared numerically, no timestamp parsing.
- **Private notes**: `POST /tickets/{id}/notes` with `{"body": <html>, "private": true}` — `note.sh` hardcodes `private: true`, so the agent structurally cannot post a customer-facing reply; it also converts the playbook's plain text into the simple HTML Freshdesk expects.

## Install

```bash
./setup.sh freshdesk/triage-agent
```

Asks for: target repo, Freshdesk domain, escalation label, and the standard
conventions. Secrets: `FRESHDESK_API_KEY`, Claude auth (+ optional
`AGENT_GH_PAT`); relay: `GITHUB_PAT`, `WEBHOOK_SECRET`. The installer prints
the exact Admin steps for the two automation rules whose JSON bodies define
the payload.

## Guardrails

Private notes only (`note.sh` hardcodes `private: true` — structurally cannot
reply to customers), never changes status/priority/assignee, at most one note
per run, never escalates twice (issue URL tracked in state), no customer
personal data in GitHub issues, `--dangerously-skip-permissions` only in the
disposable CI runner, `DRY_RUN=1` local testing, full transcript artifacts
per run.

## Beta → stable checklist (live-fire against a real Freshdesk instance)

- [ ] URL-secret round-trip through the relay (automation rule test-fire → dispatched workflow run; wrong secret → 404)
- [ ] triage → respond round-trip on a test ticket
- [ ] HTML conversion fidelity: note.sh escaping (`&` `<` `>`) and paragraph wrapping render cleanly in the ticket view
- [ ] Escalation dedupe: a bug follow-up comments on the existing issue instead of opening a second one
- [ ] Human-reply silence: the agent posts nothing when a support agent already replied publicly
