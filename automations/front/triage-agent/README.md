# Front Triage Agent

Support triage with a human between the agent and the customer: a conversation
arrives → the agent reads it, grounds itself in your product's repository, and
posts ONE **internal comment** — a category plus a draft reply the human
teammate can send nearly verbatim; real product bugs get escalated as GitHub
issues. Customer follow-ups refresh the comment; when a teammate has already
replied, the agent stays silent. It never messages customers and never
archives, assigns, or tags conversations — humans own the queue.

Status: **beta** — ports the production-proven Zendesk triage flow to Front's
rule-webhook model; needs live-fire testing against a real Front workspace.

## Event coverage (relay routes whatever your rules send)

| Handler | Fed by | Status |
|---|---|---|
| `conversations` | Front rule "Inbound message is received" → "Send to a webhook" (optionally a second rule on "Outbound reply is sent") | ✅ implemented (triage / respond playbooks) |
| anything else | any other rule/webhook pointed at the relay | Routed, skips cleanly (no `cnv_…` id → ignored at the edge) |

## Front-specific mechanics

- **Unsigned rule webhooks**: Front's "Send to a webhook" rule action carries no HMAC — there is nothing to verify at the edge. Authentication is the secret embedded in the URL path (`/hook/<WEBHOOK_SECRET>`), the same model as the Freshdesk/Jira/monday/Confluence recipes: treat the full URL like a password. (Front's signed application webhooks exist, but they require building a developer app — the hardening path once you outgrow the URL secret.)
- **The payload is a conversation preview**: the relay extracts the id defensively — `body.conversation.id` or `body.id` — and it must start with `cnv_`; anything else is ignored at the edge with a hint.
- **Comments vs messages = structural loop protection**: the agent writes COMMENTS (`POST /conversations/{id}/comments` — a separate internal stream Front never sends to customers), and the resolver counts only MESSAGES for recency — the agent's own output can never ring its own doorbell. No marker check needed (the marker is still prefixed, for humans).
- **Plain-text comments**: Front comments take plain text/markdown, so `note.sh` posts the playbook's text as-is — the only triage sibling without an HTML converter.
- **Message recency is an epoch float**: `created_at` is e.g. `1722945600.123` — compared numerically in jq (`--argjson`), never as a string and never in bash.
- **Teammate replies count as new human messages**: an outbound message (`is_inbound: false`) is exactly the human-handled signal the respond playbook goes silent on; drafts (`is_draft: true`) never count.

## Install

```bash
./setup.sh front/triage-agent
```

Asks for: target repo, escalation label, and the standard conventions.
Secrets: `FRONT_TOKEN` (Settings → Developers → API tokens), Claude auth
(+ optional `AGENT_GH_PAT`); relay: `GITHUB_PAT`, `WEBHOOK_SECRET`. The
installer prints the exact rule setup — When "Inbound message is received" →
Then "Send to a webhook" — plus the optional teammate-reply rule.

Text-only brains (Aider, raw API) work here via driver-mediated delivery — pick them at the brain question.

## Guardrails

Internal comments only (`note.sh` posts to the `/comments` endpoint — a stream
Front never sends to customers, structurally unable to reply), never
archives/assigns/tags, at most one comment per run, never escalates twice
(issue URL tracked in state), no customer personal data in GitHub issues,
`--dangerously-skip-permissions` only in the disposable CI runner, `DRY_RUN=1`
local testing, full transcript artifacts per run.

## Beta → stable checklist (live-fire against a real Front workspace)

- [ ] URL-secret round-trip through the relay (rule test-fire → dispatched workflow run; wrong secret → 404)
- [ ] triage → respond round-trip on a test conversation
- [ ] Teammate-reply silence: the agent posts nothing when a teammate already replied (outbound message)
- [ ] Escalation dedupe: a bug follow-up comments on the existing issue instead of opening a second one
- [ ] Rule scoping: the rule fires only for the inboxes you actually want triaged
