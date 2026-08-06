# PagerDuty Triage Agent

A head start on every page: an incident triggers → the agent fetches the
incident + ALL of its alerts, opens THIS repository at the implicated code
(the alert details' stack traces, endpoints, and config), and posts ONE note
on the incident — what happened, who/what is affected, the likely cause
(hedged, verified against the code), and where to look. Responders see it
right where they already work, before they've finished opening their laptops.
The agent never acknowledges, resolves, assigns, or escalates — the note is
its only write; humans own the incident.

Status: **beta** — the triage-family driver (Zendesk-proven) pointed at
PagerDuty's incident/alert API; needs live-fire testing against a real
account.

## Event coverage (relay routes the v3 webhook surface)

| Handler | PagerDuty events | Status |
|---|---|---|
| `incidents` | `incident.triggered`, `incident.reopened`, `incident.escalated` | ✅ implemented (analyze playbook) |
| — | `incident.annotated` (our own notes echoing back), acknowledge/assign/resolve/priority churn, non-incident events | Acknowledged at the edge (200), never dispatched |

## PagerDuty-specific mechanics

- **Signature**: every delivery carries `X-PagerDuty-Signature` — a comma-separated list like `v1=<hex>,v1=<hex>` (one entry per active signing secret, so rotation overlaps). The delivery is authentic when ANY `v1=` entry equals the hex HMAC-SHA256 of the raw body — verified at the edge. The secret is shown ONCE when the webhook subscription is created.
- **Loop protection at the edge**: the agent's own notes come back as `incident.annotated` deliveries — the relay drops them (with the rest of the responder-action noise) before anything is dispatched, so the agent can never wake itself.
- **Notes need a From header**: `POST /incidents/<id>/notes` requires `From: <email>` naming a real PagerDuty user. `PAGERDUTY_FROM_EMAIL` is an installer question stored in `env.sh` (an email is config, not a secret) and `note.sh` adds the header itself. Notes are plain text.
- **Alerts carry the payload**: the incident is only the envelope — `GET /incidents/<id>/alerts` → `.alerts[].body.details` usually holds the real error (stack traces, hosts, metrics). That's what gets grounded against the repo.
- **Note-once dedupe**: state marks each incident `noted`; duplicate deliveries, retriggers, and reopens of an annotated incident all skip. One incident, one note, ever.

## Install

```bash
./setup.sh pagerduty/triage-agent
```

Asks for: target repo, the From email for note attribution, and the standard
conventions. Secrets: `PAGERDUTY_TOKEN`, Claude auth (+ optional
`AGENT_GH_PAT`); relay: `GITHUB_PAT`, `PAGERDUTY_WEBHOOK_SECRET`. The
installer prints the exact clicks that create the v3 webhook subscription —
and warns that its signing secret is shown only once.

Text-only brains (Aider, raw API) work here via driver-mediated delivery — pick them at the brain question.

## Guardrails

Notes only — the agent never acknowledges, resolves, assigns, escalates, or
snoozes (responders own the incident); ONE note per incident ever (phase-based
dedupe, annotated-echo dropped at the edge); read-only toward PagerDuty beyond
that single note; no PII from alert payloads (describe, don't paste); never
writes code; `--dangerously-skip-permissions` only in the disposable CI
runner; `DRY_RUN=1` local testing; full transcript artifacts per run.

## Beta → stable checklist (live-fire against a real account)

- [ ] Signature verification through the relay, including a multi-entry `v1=…,v1=…` header (secret rotation)
- [ ] incident.triggered → analyze → note round-trip on a real incident
- [ ] The posted note's `incident.annotated` echo is dropped at the edge (no self-wake loop)
- [ ] Dedupe on retrigger/reopen: a second delivery for a noted incident skips with "already noted"
- [ ] Note attribution: the `From:` user shows as the note's author in the PagerDuty UI
