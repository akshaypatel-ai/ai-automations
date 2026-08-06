# Intercom Triage Agent

Support triage with a human between the agent and the customer: a conversation
arrives → the agent reads it, grounds itself in your product's repository, and
posts ONE **internal note** — a category plus a draft reply the human teammate
can send nearly verbatim; real product bugs get escalated as GitHub issues.
Customer follow-ups refresh the note; when an admin has already replied, the
agent stays silent. It never messages customers and never closes, assigns, or
snoozes — humans own the inbox.

Status: **beta** — ports the production-proven Zendesk triage flow to
Intercom's REST API (2.11); needs live-fire testing against a real workspace.

## Event coverage (relay routes the conversation topics)

| Handler | Intercom topics | Status |
|---|---|---|
| `conversations` | `conversation.user.created`, `conversation.user.replied`, `conversation.admin.replied` — `conversation.admin.noted` dropped at the edge (the agent's own note echo) | ✅ implemented (triage / respond playbooks) |
| anything else | any other subscribed topic | Routed, skips cleanly (no `conversation.` prefix → ignored at the edge) |

## Intercom-specific mechanics

- **Signed webhooks**: every delivery carries `X-Hub-Signature` = `sha1=` + hex HMAC-SHA1 of the raw body, keyed with the app's client secret. Verified at the edge with a constant-time compare.
- **HEAD probe**: Intercom sends a HEAD request when the webhook endpoint URL is saved — the relay answers 200 before any verification.
- **Bodies are HTML**: the customer's first message is `.source.body`, everything after lives in `conversation_parts` — the resolver strips tags before marker checks, and attachments arrive as links inside the bodies.
- **Part recency**: part ids are strings, so ordering is by `created_at` (epoch seconds), compared numerically.
- **Internal notes ride the reply API**: `POST /conversations/{id}/reply` with `message_type: "note"` — `note.sh` hardcodes it (and resolves the admin id from `GET /me` at runtime), so the agent structurally cannot message customers. It also converts the playbook's plain text into the simple HTML Intercom expects.
- **Admin replies are the human-handled signal**: `conversation.admin.replied` is forwarded, and the respond playbook goes silent when a human closed the loop.

## Install

```bash
./setup.sh intercom/triage-agent
```

Asks for: target repo, escalation label, and the standard conventions.
Secrets: `INTERCOM_TOKEN`, Claude auth (+ optional `AGENT_GH_PAT`); relay:
`GITHUB_PAT`, `INTERCOM_CLIENT_SECRET`. The installer prints the exact
Developer Hub steps — the webhook endpoint, the three topics to subscribe,
and where the access token and client secret live.

Text-only brains (Aider, raw API) work here via driver-mediated delivery — pick them at the brain question.

## Guardrails

Internal notes only (`note.sh` hardcodes `message_type: "note"` — structurally
cannot message customers), never closes/assigns/snoozes conversations, at most
one note per run, never escalates twice (issue URL tracked in state), no
customer personal data in GitHub issues, `--dangerously-skip-permissions` only
in the disposable CI runner, `DRY_RUN=1` local testing, full transcript
artifacts per run.

## Beta → stable checklist (live-fire against a real workspace)

- [ ] Signature verification round-trip through the relay (incl. the HEAD probe on endpoint save)
- [ ] triage → respond round-trip on a test conversation
- [ ] HTML-to-text fidelity: note.sh escaping (`&` `<` `>`) and paragraph wrapping render cleanly in the inbox
- [ ] Escalation dedupe: a bug follow-up comments on the existing issue instead of opening a second one
- [ ] Human-reply silence: the agent posts nothing when an admin already answered
