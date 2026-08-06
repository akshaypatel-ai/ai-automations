# Discord Notify Agent

An outbound-first shape: **AI-written notifications pushed to Discord**, plus
optional `/ask` Q&A. Ship and incident notifications use GitHub-native
triggers and a plain channel webhook — **no relay, no bot process, nothing to
host**; the optional `ask` handler adds a small interactions relay.

Status: **beta** — needs live-fire testing against a real server.

| Handler | Trigger | Output |
|---|---|---|
| `ship` | `release: published` | Plain-language announcement of what's new for users (grounded in the actual release/commits — never invented) |
| `incident` | monitored `workflow_run` fails | Calm what/impact/likely-cause note with the run link |
| `ask` | `/ask question:…` slash command | Grounded answer from the repo, replacing Discord's "thinking…" placeholder |

## Design notes

- **Outbound is trivially relay-free**: a Discord channel webhook URL is all
  ship/incident need — the URL itself is the credential (kept in GitHub secrets).
- **`/ask` uses the interactions endpoint**, not a gateway bot — so it stays
  serverless. Discord's 3-second interaction deadline is met the same way the
  Slack recipe meets its 3-second ack: the relay answers *deferred*
  immediately, and CI replaces the placeholder through the interaction's
  follow-up webhook (token valid 15 minutes — comfortable for a CI run).
- **Ed25519, not HMAC**: Discord signs interactions with the app's public
  key; the relay verifies via WebCrypto and 401s failures (Discord actively
  probes this during endpoint setup).
- **Structural no-ping**: every message sends `allowed_mentions: []` — the
  agent physically cannot ping @everyone/@here/roles.

## Install

```bash
./setup.sh discord/notify-agent
```

Asks for: target repo, which workflows to monitor for incidents, handlers,
and conventions. Secrets: `DISCORD_WEBHOOK_URL` + Claude auth; relay (ask
only): `GITHUB_PAT`, `DISCORD_PUBLIC_KEY`. The installer prints the slash
command registration `curl`.

Text-only brains (Aider, raw API) work here via driver-mediated delivery — pick them at the brain question.

## Guardrails

One message per event; 2000-char cap enforced; no invented features, no
speculative root causes; `ask` never writes code; structurally unable to
ping; `DRY_RUN=1` local testing; transcript artifacts per run.

## Beta → stable checklist (live-fire against a real server)

- [ ] ship round-trip on a test release
- [ ] incident round-trip on a forced CI failure
- [ ] /ask round-trip: Ed25519 verify → deferred → follow-up within 15 min
- [ ] Endpoint verification probe (Discord's PING + bad-signature test) passes
