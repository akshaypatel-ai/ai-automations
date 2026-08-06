# Telegram Notify Agent

An outbound-first shape: **AI-written notifications pushed to Telegram**, plus
optional inbound Q&A. Ship and incident notifications use GitHub-native
triggers — **no relay, no webhook, nothing to host**; the optional `ask`
handler adds a small secret-token-verified webhook relay.

Status: **beta** — needs live-fire testing against a real bot and group.

| Handler | Trigger | Output |
|---|---|---|
| `ship` | `release: published` | Plain-language announcement of what's new for users (grounded in the actual release/commits — never invented) |
| `incident` | monitored `workflow_run` fails | Calm what/impact/likely-cause note with the run link |
| `ask` | chat message (secret-token webhook → relay) | Grounded answer from the repo; silence for chatter |

## Design notes

- **The simplest inbound recipe in the collection**: Telegram has no reply
  deadline at all — answers go out as plain `sendMessage` pushes, so there's
  no expiring token (Discord: 15 minutes) and no synchronous window (Teams:
  ~5 seconds). The relay just verifies, dispatches, and acks 200.
- **Shared-secret header auth**: `setWebhook` registers a `secret_token`;
  Telegram echoes it in `X-Telegram-Bot-Api-Secret-Token` on every delivery —
  the same trust model as the Basecamp/Jira secret webhook URLs, verified in
  full at the edge (mismatch → 401).
- **Loop-proof and chat-scoped**: updates from bots (including the agent's
  own pushes) are dropped at the relay, and `WATCHED_CHAT` limits the bot to
  its home chat — it never answers strangers.
- **Plain text on purpose**: `parse_mode` is omitted so arbitrary AI output
  can never fail Telegram's Markdown parser; 4096-char cap enforced
  defensively.
- **Group privacy mode**: by default the bot only receives group messages
  that mention it or reply to it — mention the bot to ask, or disable
  privacy mode via @BotFather (`/setprivacy`).

## Install

```bash
./setup.sh telegram/notify-agent
```

Asks for: target repo, Telegram chat id (add @RawDataBot or @userinfobot to
the group to see it; groups are negative numbers), which workflows to monitor
for incidents, handlers, and conventions. Secrets: `TELEGRAM_BOT_TOKEN` (from
@BotFather) + Claude auth; relay (ask only): `GITHUB_PAT`,
`TELEGRAM_WEBHOOK_SECRET`. The installer prints the `setWebhook` registration
`curl`.

Text-only brains (Aider, raw API) work here via driver-mediated delivery — pick them at the brain question.

## Guardrails

Pushes only to the configured chat (relay drops every other chat); one
message per event; 4096-char cap enforced; no invented features, no
speculative root causes; `ask` never writes code; `DRY_RUN=1` local testing;
transcript artifacts per run.

## Beta → stable checklist (live-fire against a real bot)

- [ ] ship round-trip on a test release
- [ ] incident round-trip on a forced CI failure
- [ ] ask round-trip through the relay (secret_token verify, chat scoping, bot-message loop protection)
- [ ] Group privacy mode both ways: mention-only (default) and /setprivacy Disabled
- [ ] 4096-char truncation on an oversized announcement
