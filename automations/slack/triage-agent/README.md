# Slack Triage Agent — design (not yet built)

A different interaction shape from the board agents: conversational triage in
channels. Status: **designed** — this document is the implementation spec.

## Event coverage (Events API → handler families)

| Handler | Slack events | Interaction pattern |
|---|---|---|
| `mentions` | `app_mention` | Someone @mentions the agent → grounded answer from the repo, threaded reply |
| `channel` | `message.channels` (scoped to configured channels) | Support/eng channel triage: classify new messages — answerable FAQ → threaded answer; real bug → open a GitHub issue (with repro summary) and thread the link; else silent |
| `reactions` | `reaction_added` (configurable trigger emoji, e.g. 🤖/🎫) | Emoji on a message = explicit human trigger: "answer this" / "make this an issue" |
| `dm` | `message.im` | Direct Q&A with the agent |

## Mechanics — why Slack needs a smarter relay

- **3-second ack**: Slack retries unless the event endpoint answers 200 within 3s. The Worker must ack immediately and dispatch to GitHub asynchronously (`ctx.waitUntil`) — unlike the board relays which can await.
- **URL verification**: on subscription, Slack POSTs `{"type":"url_verification","challenge":...}` — the Worker must echo the challenge.
- **Signing**: verify `X-Slack-Signature` (`v0=` HMAC-SHA256 of `v0:{timestamp}:{body}` with the signing secret) + timestamp freshness (±5 min).
- **Dedup**: Slack retries (`X-Slack-Retry-Num`) — the doorbell pattern absorbs duplicates, but the Worker should also drop retries with `X-Slack-Retry-Reason: http_timeout`.
- **Bot loop protection**: ignore events with `bot_id` / the app's own `user_id` (marker prefixes are unnecessary — identity is structural).
- **Writes**: `chat.postMessage` with `thread_ts` (always reply in thread). Bot token `xoxb-…` with scopes: `app_mentions:read`, `channels:history`, `chat:write`, `reactions:read`, `im:history`.
- **State**: keyed by `channel:thread_ts`; recency by message `ts` (monotonic per channel).
- **Setup flow**: create a Slack app (manifest YAML shipped in the recipe), install to workspace, paste bot token + signing secret. The installer prints the exact manifest.

## Guardrail differences from board agents

Channels are conversation, not work queues: default to silence except
mentions, configured channels, and trigger emoji; never open issues without an
explicit trigger (mention/emoji) unless the channel is explicitly designated
as a triage queue; PRs are out of scope for v1 (issues only).
