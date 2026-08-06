# Google Chat Notify Agent

An outbound-only shape: **AI-written notifications pushed to a Google Chat
space**. Both handlers are GitHub-native triggers and the write path is a
plain space webhook — **the fully relay-free notify recipe: no relay, no
bot, no GCP project, nothing to deploy beyond two repo secrets**.

Status: **beta** — needs live-fire testing against a real space.

| Handler | Trigger | Output |
|---|---|---|
| `ship` | `release: published` | Plain-language announcement of what's new for users (grounded in the actual release/commits — never invented) |
| `incident` | monitored `workflow_run` fails | Calm what/impact/likely-cause note with the run link |

## Design notes

- **The URL is the credential**: a Google Chat space webhook URL embeds its
  own key and token — anyone holding it can post to the space. It lives in
  GitHub secrets (`GCHAT_WEBHOOK_URL`) and is never written to a file;
  rotating the webhook rotates the credential.
- **Zero relay**: with both handlers GitHub-native and the write path a bare
  webhook, the relay layer disappears entirely — the simplest recipe in the
  collection alongside GitHub Issues.
- **Plain text on purpose**: Google Chat renders *bold* and simple markup,
  but arbitrary AI output can break markup — playbooks write plain text with
  • bullets, and the ~4096-char cap is enforced defensively at 3900.
- **No inbound Q&A (yet)**: reading messages back out of a space needs a
  Google Chat app — a GCP project, the Chat API, and OAuth — a different
  weight class from a webhook URL. That would be a future `ask` handler;
  this recipe deliberately stops at outbound.

## Install

```bash
./setup.sh googlechat/notify-agent
```

Asks for: target repo, which workflows to monitor for incidents, handlers,
and conventions. Secrets: `GCHAT_WEBHOOK_URL` (space → ⚙ → Apps &
integrations → Webhooks → Add → copy URL) + Claude auth.

Text-only brains (Aider, raw API) work here via driver-mediated delivery — pick them at the brain question.

## Guardrails

One message per event; ~4096-char cap enforced (truncated at 3900); no
invented features, no speculative root causes; `DRY_RUN=1` local testing;
transcript artifacts per run.

## Beta → stable checklist (live-fire against a real space)

- [ ] ship round-trip on a test release
- [ ] incident round-trip on a forced CI failure
- [ ] Webhook-URL rotation: delete + re-add the webhook, update the secret, confirm the old URL is dead
- [ ] 4096-char truncation on an oversized announcement
