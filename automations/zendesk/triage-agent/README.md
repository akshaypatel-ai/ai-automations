# Zendesk Triage Agent

Support triage with a human between the agent and the customer: a ticket
arrives → the agent reads it, grounds itself in your product's repository, and
posts ONE **internal note** — a category plus a draft reply the human agent can
send nearly verbatim; real product bugs get escalated as GitHub issues.
Customer follow-ups refresh the note; when a human has already replied, the
agent stays silent. It never messages customers and never touches ticket
status — humans own the queue.

Status: **beta** — ports the production-proven board-agent loop to Zendesk's
signed-webhook + trigger model; needs live-fire testing against a real
Zendesk instance.

## Event coverage (relay routes whatever your triggers send)

| Handler | Fed by | Status |
|---|---|---|
| `tickets` | Zendesk triggers "ticket created" + "comment added" (JSON bodies below) | ✅ implemented (triage / respond playbooks) |
| anything else | any other trigger/webhook event pointed at the relay | Routed, skips cleanly (no `ticket_id` → ignored at the edge) |

## Zendesk-specific mechanics

- **Signed webhooks**: every delivery carries `X-Zendesk-Webhook-Signature` = base64 HMAC-SHA256 of `timestamp + body`, keyed with the webhook's signing secret; the timestamp rides in `X-Zendesk-Webhook-Signature-Timestamp`. Verified at the edge.
- **Triggers define the payload**: unlike ClickUp/Linear, a Zendesk webhook delivers whatever JSON body its trigger defines. This recipe uses two triggers with the literal bodies `{"ticket_id": "{{ticket.id}}", "event": "created"}` (on Ticket Is Created) and `{"ticket_id": "{{ticket.id}}", "event": "commented"}` (on Comment Is Public).
- **Comment recency**: comment ids are numeric and monotonic — compared numerically, no timestamp parsing.
- **Internal notes are private comments**: `PUT /tickets/{id}.json` with `{"ticket": {"comment": {"body": ..., "public": false}}}` — `note.sh` hardcodes `public: false`, so the agent structurally cannot post a customer-facing reply.

## Install

```bash
./setup.sh zendesk/triage-agent
```

Asks for: target repo, Zendesk subdomain, escalation label, and the standard
conventions. Secrets: `ZENDESK_EMAIL`, `ZENDESK_API_TOKEN`, Claude auth
(+ optional `AGENT_GH_PAT`); relay: `GITHUB_PAT`, `ZENDESK_WEBHOOK_SECRET`.
The installer prints the exact Admin Center steps for the webhook and the two
triggers whose JSON bodies define the payload.

Text-only brains (Aider, raw API) work here via driver-mediated delivery — pick them at the brain question.

## Guardrails

Internal notes only (`note.sh` hardcodes `public: false` — structurally cannot
reply to customers), never changes status/assignee, at most one note per run,
never escalates twice (issue URL tracked in state), no customer personal data
in GitHub issues, `--dangerously-skip-permissions` only in the disposable CI
runner, `DRY_RUN=1` local testing, full transcript artifacts per run.

## Beta → stable checklist (live-fire against a real Zendesk instance)

- [ ] Signature verification round-trip through the relay (Zendesk webhook test delivery)
- [ ] triage → respond round-trip on a test ticket
- [ ] Escalation dedupe: a bug follow-up comments on the existing issue instead of opening a second one
- [ ] No-PII check on escalated issues (customer names/emails described, never pasted)
- [ ] Human-reply silence: the agent posts nothing when a support agent already answered
