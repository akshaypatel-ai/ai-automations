# LINE Notify Agent

An outbound-first shape: **AI-written notifications pushed to LINE**, plus
optional inbound Q&A. Ship and incident notifications use GitHub-native
triggers — **no relay, no webhook, nothing to host**; the optional `ask`
handler adds a small signed-webhook relay.

Status: **beta** — needs live-fire testing against a real LINE channel.

| Handler | Trigger | Output |
|---|---|---|
| `ship` | `release: published` | Plain-language announcement of what's new for users (grounded in the actual release/commits — never invented) |
| `incident` | monitored `workflow_run` fails | Calm what/impact/likely-cause note with the run link |
| `ask` | group message (signed LINE webhook → relay) | Grounded answer from the repo; silence for chatter |

## Design notes

- **The relay-free degenerate case** of the six-layer architecture: two of three handlers wire the tool directly into the runtime's native triggers — the relay layer simply disappears.
- **Stateless**: notifications are one-shot, so there's no state branch and no doorbell diffing — the simplest recipe in the collection.
- **Reply tokens aren't used** for `ask` — they expire before CI can spin up, so answers go out as push messages instead.
- **Signature-verified inbound** (`x-line-signature`, base64 HMAC-SHA256).

## Install

```bash
./setup.sh line/notify-agent
```

Asks for: target repo, LINE push target id, which workflows to monitor for
incidents, handlers, and conventions. Secrets: `LINE_CHANNEL_ACCESS_TOKEN` +
Claude auth; relay (ask only): `GITHUB_PAT`, `LINE_CHANNEL_SECRET`.

Text-only brains (Aider, raw API) work here via driver-mediated delivery — pick them at the brain question.

## Guardrails

Pushes only to the configured target (no broadcast); one message per event;
no invented features, no speculative root causes; `ask` never writes code;
`DRY_RUN=1` local testing; transcript artifacts per run.

## Beta → stable checklist (live-fire against a real channel)

- [ ] ship round-trip on a test release
- [ ] incident round-trip on a forced CI failure
- [ ] ask round-trip through the relay (signature + group scoping)
- [ ] Message quota behavior on the free plan
