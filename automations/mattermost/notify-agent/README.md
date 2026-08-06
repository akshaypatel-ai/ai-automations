# Mattermost Notify Agent

An outbound-first shape: **AI-written notifications pushed to Mattermost**,
plus optional trigger-word Q&A. Ship and incident notifications use
GitHub-native triggers and an incoming webhook URL — **no relay, nothing to
host**; the optional `ask` handler adds a small outgoing-webhook relay.

Status: **beta** — needs live-fire testing against a real server.

| Handler | Trigger | Output |
|---|---|---|
| `ship` | `release: published` | Plain-language announcement of what's new for users (grounded — never invented) |
| `incident` | monitored `workflow_run` fails | Calm what/impact/likely-cause note with the run link |
| `ask` | trigger word (e.g. `@ai`) via outgoing webhook | Repo-grounded answer posted to the channel (Q quoted for context) |

## Design notes

- **Outbound via an incoming webhook** (Integrations → Incoming Webhooks) —
  the URL *is* the credential, so it lives in CI secrets. Mattermost renders
  markdown natively, so messages use **bold** and bullets. Posts show under
  the agent's name when "Enable integrations to override usernames" is on in
  the System Console — harmless if off.
- **`ask` uses Mattermost outgoing webhooks** (Integrations → Outgoing
  Webhooks): a trigger word in a channel POSTs to the relay. Verification is
  the `token` field against the secret shown at creation — a plain constant
  compare, **no HMAC** (that's all Mattermost offers). Outgoing webhooks fire
  only in **public** channels.
- **Dual content-type parsing**: delivery is form-encoded by default with
  JSON as a per-webhook option — the relay parses both, so either setting works.
- **The immediate reply is the courtesy ack** — Mattermost posts the relay's
  synchronous `{"text": ...}` response straight back to the channel. A CI run
  can't answer that fast, so the relay says "on it" and CI posts the real
  answer through the notify webhook. Point both at the same channel.
- **Self-hosted** — Mattermost pairs naturally with the future Docker-server
  runtime for fully on-prem installs.

## Install

```bash
./setup.sh mattermost/notify-agent
```

Asks for: target repo, which workflows to monitor for incidents, handlers,
the trigger word, and conventions. Secrets: `MATTERMOST_WEBHOOK_URL` + Claude
auth; relay (ask only): `GITHUB_PAT`, `MATTERMOST_OUTGOING_TOKEN`.

Text-only brains (Aider, raw API) work here via driver-mediated delivery — pick them at the brain question.

## Guardrails

One message per event; size cap enforced; no invented features, no
speculative root causes; `ask` never writes code; `DRY_RUN=1` local testing;
transcript artifacts per run.

## Beta → stable checklist (live-fire against a real server)

- [ ] ship round-trip on a test release
- [ ] incident round-trip on a forced CI failure
- [ ] ask round-trip: token verify → courtesy reply → channel answer, with the
      webhook set to form-encoded AND to JSON content type
- [ ] wrong/missing token rejected (401)
- [ ] public-channel-only limitation confirmed (no fires from private channels/DMs)
- [ ] username override behavior with the System Console setting on and off
