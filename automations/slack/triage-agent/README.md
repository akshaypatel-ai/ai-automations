# Slack Triage Agent

A conversational shape, not a board flow: the agent answers **@mentions** and
**DMs** grounded in your actual code, **triages designated channels** (answers
FAQs, escalates real bugs as GitHub issues with the thread permalink), and a
**trigger emoji** summons it onto any message. It never writes code from chat —
build requests get redirected to your board/tracker.

Status: **beta** — needs live-fire testing against a real workspace.

## Event coverage

| Handler | Slack events | Behavior |
|---|---|---|
| `mentions` | `app_mention` | Always answers, threaded, grounded in the repo |
| `channel` | `message.channels` (watched channels only) | Triage: answer / escalate to GitHub issue / silence for chatter |
| `reactions` | `reaction_added` (configured emoji) | Explicit summon → triage that message's thread |
| `dm` | `message.im` | Conversational Q&A |

## Slack-specific mechanics (all handled in the relay)

- **3-second ack** — the Worker responds immediately and dispatches to GitHub via `ctx.waitUntil`.
- **URL verification** — echoes Slack's subscription challenge (deploy the signing secret *before* setting the request URL).
- **Signature verification** — `v0=` HMAC-SHA256 over `v0:{timestamp}:{body}` + ±5 min freshness.
- **Retry dedup** — `http_timeout` retries are dropped; the doorbell pattern absorbs the rest.
- **Structural loop protection** — `bot_id` messages and the agent's own user id (from `auth.test`) are never input; no marker prefix needed.
- **Thread state** — keyed `<channel>:<root_ts>`, recency by message `ts`.

## Install

```bash
./setup.sh slack/triage-agent
```

Asks for: target repo, handlers, triage channel IDs, trigger emoji, and
conventions. The installer prints a ready-to-paste **Slack app manifest**
(scopes + event subscriptions) and the exact setup order. Secrets:
`SLACK_BOT_TOKEN` + Claude auth on the repo; `GITHUB_PAT` +
`SLACK_SIGNING_SECRET` on the relay.

## Guardrails

Threaded replies only (never new channel messages, DMs to others, or
@channel); GitHub issues only — no code, no PRs; silence for human-to-human
chatter; signature-verified ingress; `DRY_RUN=1` local testing; full
transcript artifacts per run.

## Beta → stable checklist (live-fire against a real workspace)

- [ ] URL verification handshake with the signing secret in place
- [ ] Mention → grounded answer round-trip
- [ ] Channel triage: FAQ answer, bug → issue + thread link, chatter → silence
- [ ] Trigger emoji summon
- [ ] Retry behavior under a slow first delivery (no duplicate replies)
