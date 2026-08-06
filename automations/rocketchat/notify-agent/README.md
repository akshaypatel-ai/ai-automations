# Rocket.Chat Notify Agent

An outbound-first shape: **AI-written notifications pushed to Rocket.Chat**,
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

- **Outbound via an incoming webhook** (Admin → Integrations → Incoming
  WebHook, Script off) — the URL (`https://<server>/hooks/<id>/<token>`)
  *embeds* the token, so the URL itself is the credential and lives in CI
  secrets. Rocket.Chat renders markdown natively, so messages use **bold**
  and bullets. The display-name override field is **`alias`** (Mattermost's
  is `username`) — harmless if the server restricts overriding.
- **`ask` uses Rocket.Chat outgoing webhooks** (Admin → Integrations →
  Outgoing WebHook, event *Message Sent*): a trigger word in the channel
  POSTs to the relay. Delivery is **always JSON**. Verification is the
  `token` field against the Token you set in the webhook form — a plain
  constant compare, **no HMAC** (that's all Rocket.Chat offers).
- **Bot-loop guard is doubled**: unlike Mattermost, Rocket.Chat has no
  structural protection — the server sets a truthy `bot` field on
  bot-authored messages, and incoming-webhook posts can re-trigger outgoing
  webhooks on some server configs. The relay drops both the `bot` flag and
  anything by/quoting the agent's alias.
- **The immediate reply is the courtesy ack** — Rocket.Chat posts the
  relay's synchronous `{"text": ...}` response straight back to the channel.
  A CI run can't answer that fast, so the relay says "on it" and CI posts
  the real answer through the notify webhook. Point both at the same channel.
- **Self-hosted** — Rocket.Chat (like Mattermost) pairs naturally with the
  future Docker-server runtime for fully on-prem installs.

## Install

```bash
./setup.sh rocketchat/notify-agent
```

Asks for: target repo, which workflows to monitor for incidents, handlers,
the trigger word, and conventions. Secrets: `ROCKETCHAT_WEBHOOK_URL` + Claude
auth; relay (ask only): `GITHUB_PAT`, `ROCKETCHAT_OUTGOING_TOKEN`.

Text-only brains (Aider, raw API) work here via driver-mediated delivery — pick them at the brain question.

## Guardrails

One message per event; size cap enforced; no invented features, no
speculative root causes; `ask` never writes code; `DRY_RUN=1` local testing;
transcript artifacts per run.

## Beta → stable checklist (live-fire against a real server)

- [ ] ship round-trip on a test release
- [ ] incident round-trip on a forced CI failure
- [ ] ask round-trip: token verify → courtesy reply → channel answer
- [ ] wrong/missing token rejected (401)
- [ ] bot-echo guard on a server config where incoming-webhook posts
      re-trigger outgoing webhooks (no reply loop)
- [ ] alias override behavior with the override permission on and off
