# Microsoft Teams Notify Agent

An outbound-first shape: **AI-written notifications pushed to Teams**, plus
optional @mention Q&A. Ship and incident notifications use GitHub-native
triggers and a channel webhook URL — **no relay, nothing to host**; the
optional `ask` handler adds a small outgoing-webhook relay.

Status: **beta** — needs live-fire testing against a real team.

| Handler | Trigger | Output |
|---|---|---|
| `ship` | `release: published` | Plain-language announcement of what's new for users (grounded — never invented) |
| `incident` | monitored `workflow_run` fails | Calm what/impact/likely-cause note with the run link |
| `ask` | @mention of the outgoing webhook | Repo-grounded answer posted to the channel (Q quoted for context) |

## Design notes

- **Outbound via a channel webhook URL** — messages are sent as Adaptive
  Cards, which works with the modern **Workflows** webhook ("when a webhook
  request is received") and the classic Incoming Webhook connector alike.
- **`ask` uses Teams outgoing webhooks** (Team → Manage team → Apps →
  Create an outgoing webhook): HMAC-SHA256 over the raw body, keyed with the
  base64-decoded security token, sent as `Authorization: HMAC <base64>` —
  verified at the edge.
- **The 5-second reply window** is Teams' version of Slack's 3-second ack —
  but outgoing webhooks allow *only* that one synchronous reply. So the relay
  answers "on it" inside the window and CI posts the real answer through the
  notify webhook. Point both at the same channel.
- **Mention stripping**: the relay reduces Teams' HTML-ish `<at>Bot</at>
  question` payload to the bare question before dispatching.

## Install

```bash
./setup.sh teams/notify-agent
```

Asks for: target repo, which workflows to monitor for incidents, handlers,
and conventions. Secrets: `TEAMS_WEBHOOK_URL` + Claude auth; relay (ask
only): `GITHUB_PAT`, `TEAMS_SECURITY_TOKEN`.

Text-only brains (Aider, raw API) work here via driver-mediated delivery — pick them at the brain question.

## Guardrails

One message per event; size cap enforced; no invented features, no
speculative root causes; `ask` never writes code; `DRY_RUN=1` local testing;
transcript artifacts per run.

## Beta → stable checklist (live-fire against a real team)

- [ ] ship round-trip on a test release (Workflows webhook + classic connector)
- [ ] incident round-trip on a forced CI failure
- [ ] ask round-trip: HMAC verify → courtesy reply → channel answer
- [ ] Mention-stripping against real Teams payload HTML
