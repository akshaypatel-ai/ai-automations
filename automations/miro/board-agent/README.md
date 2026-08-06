# Miro Board Agent

The board-side assistant: **sticky-note summon, repo-grounded answer**.
Someone writes a sticky note starting with `@ai …` on a watched Miro board →
the agent reads the question, answers **from your repository** — is this
built? what does the code do here? how hard is this change? — and places ONE
reply sticky right beside the question. Visual, deletable, zero-ceremony.
Everything else: silence.

Status: **beta** — needs live-fire testing against a real board (and the
webhook API it rides on is experimental — see the checklist).

| Handler | Trigger | Output |
|---|---|---|
| `stickies` | Sticky note starting with the trigger prefix (default `@ai`, case-insensitive) | ONE repo-grounded reply sticky placed 260px to the right of the question; effort framed Small/Medium/Large for change questions |

## Design notes

- **The sticky summon IS the honest shape**: Miro's REST v2 has no usable
  board-comments API, so a Figma-style comment-thread reply is impossible.
  Rather than fake one, the recipe leans in: the question is a sticky, the
  answer is a sticky beside it — visual, deletable, and native to how boards
  are actually used.
- **A trigger prefix is the summon**: a configurable text prefix (`@ai`)
  marks a sticky as a question. The relay drops everything without it — a
  busy board full of workshop stickies never wakes CI. This IS the noise
  gate. Sticky content arrives HTML-ish (`<p>@ai …</p>`); the relay strips
  tags before gating.
- **Experimental webhooks, honestly**: board subscriptions live under
  `/v2-experimental/` and carry **no delivery signature** — the secret in
  the callback URL path is the whole credential (same model as the
  monday/Basecamp recipes). The installer says to generate it long and
  random (`openssl rand -hex 24`); the relay 404s wrong paths at the edge
  and echoes the creation challenge back as JSON.
- **Updates re-summon on purpose**: people create an empty sticky and type
  into it, so the trigger usually arrives on an *update* event — the relay
  forwards creates AND updates. No dedupe needed: the reply sticky starts
  with the agent marker and never carries the trigger, and a human editing
  their question again SHOULD get a fresh answer.
- **Board ids are opaque**: the id after `/app/board/` in the URL is
  URL-safe base64, usually with a trailing `=` — keep it; `=` is valid in a
  URL path segment, so every script passes it as-is.
- **Stateless like the notify recipes**: each summon is one Q&A round-trip —
  no state branch, no reconcile; the manual workflow run is the test button.

## Install

```bash
./setup.sh miro/board-agent
```

Asks for: target repo, the board id (after `/app/board/` in the URL — keep
the trailing `=`), trigger prefix, and conventions. Secrets: `MIRO_TOKEN`
(app access token with `boards:read` + `boards:write`, installed to the
board's team) + Claude auth; relay: `GITHUB_PAT`, `WEBHOOK_SECRET`. The
installer prints the board-subscription `curl` with your worker URL filled
in.

Text-only brains (Aider, raw API) work here via driver-mediated delivery — pick them at the brain question.

## Guardrails

ONE reply sticky per summon, placed beside the question; that sticky is the
agent's only write — it never edits, moves, or deletes anything else on the
board, never writes code; only verified repo claims ("I couldn't find that
in the repo" over guessing); trigger-gated at the relay; echo-proof via the
agent marker (the reply sticky flows back through the webhook and is dropped
there); 1800-char cap enforced (stickies are small — brevity is the
feature); `DRY_RUN=1` local testing; transcript artifacts per run.

## Beta → stable checklist (live-fire against a real board)

- [ ] Subscription-creation challenge round-trip (relay echoes the JSON, subscription goes enabled)
- [ ] Summon → reply-sticky round-trip, including placement right beside the question (x+260)
- [ ] Echo protection on the reply sticky (the agent's own sticky comes back through the webhook and is dropped)
- [ ] Update-event re-summon behavior (typing the trigger into an existing sticky summons; editing the question re-summons)
- [ ] Experimental-API stability watch (delivery shapes and the `/v2-experimental/` endpoint may change — re-verify the relay's defensive extraction against live payloads)
