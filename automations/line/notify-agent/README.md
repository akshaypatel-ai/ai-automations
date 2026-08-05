# LINE Notify Agent — design (not yet built)

An outbound-first shape: AI-written notifications into LINE, plus simple
inbound Q&A. Status: **designed** — this document is the implementation spec.

## Event coverage

| Handler | Trigger | Interaction pattern |
|---|---|---|
| `ship` | GitHub events (release published, deploy workflow success/failure, PR merged to main) — native `workflow_run`/`release` triggers, **no relay needed** | AI summarizes the change in plain language for the audience and pushes a LINE message to the configured group/room |
| `incident` | Workflow failure on the default branch / a monitored check | Short incident note: what broke, user impact, who's on it |
| `ask` | LINE Messaging API webhook: `message` events in the group | Grounded Q&A about the product; reply via reply token (fast path through the relay) |

## Mechanics

- **Outbound**: Messaging API `POST /v2/bot/message/push` with channel access token — sent directly from the GitHub Actions job (no relay involved for `ship`/`incident`).
- **Inbound** (`ask` handler): LINE webhook → Worker verifies `x-line-signature` (base64 HMAC-SHA256 with channel secret) → dispatch. Note: reply tokens expire quickly — the CI-latency path uses push messages instead of replies.
- **Setup**: LINE Developers console → Messaging API channel; secrets: `LINE_CHANNEL_ACCESS_TOKEN`, `LINE_CHANNEL_SECRET`, target group id.
- **This recipe demonstrates the "no relay" degenerate case**: two of three handlers are pure GitHub-native triggers — the runtime adapter contract's trigger wiring is just `on: workflow_run/release`.

## Guardrails

Push messages only to explicitly configured group/room ids; no broadcast; the
`ask` handler answers only in groups it's configured for; message quotas
(LINE free tier) surfaced in the doctor command.
