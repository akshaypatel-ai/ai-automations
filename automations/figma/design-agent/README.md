# Figma Design Agent

The dev-handoff assistant: **repo-grounded Q&A on Figma design comments**.
Someone comments `@ai …` on a watched design → the agent reads the comment
thread, answers **from your repository** — is this built? what does the
current version do here? how hard is this change? — and replies in the same
thread. Everything else: silence.

Status: **beta** — needs live-fire testing against a real team and file.

| Handler | Trigger | Output |
|---|---|---|
| `comments` | Comment starting with the trigger prefix (default `@ai`) | ONE repo-grounded reply in the same thread; effort framed Small/Medium/Large for change questions |

## Design notes

- **A trigger prefix is the summon**: Figma can't @mention a bot account, so
  a configurable text prefix (`@ai`) plays that role. The relay drops
  everything without it — a busy design file full of review chatter never
  wakes CI. This IS the noise gate.
- **Passcode, not HMAC — honestly**: Figma v2 webhooks are verified by the
  creation passcode echoed **in the delivery body** (`body.passcode`); there
  is no signature to check. That makes the passcode the whole credential —
  the installer says to generate it long and random (`openssl rand -hex 24`),
  and the relay 401s mismatches at the edge.
- **Replies target the thread ROOT**: Figma nests comments exactly one level
  (a root + replies carrying `parent_id` = root). The relay computes the root
  (`parent_id || comment_id`) so the answer always lands in the thread the
  question came from, and `reply.sh` only ever posts to a root id.
- **Comment text arrives as fragments**: `FILE_COMMENT` payloads carry the
  message as an array of text pieces — the relay joins them before gating,
  so `["@ai is", "this built?"]` reads as one question.
- **Paid-plan requirement**: v2 webhooks are team-scoped and need a team on a
  paid Figma plan (plus `webhooks:write` on the token). Creation fires a PING
  the relay must answer 200 — it does.
- **Stateless like the notify recipes**: each summon is one Q&A round-trip —
  no state branch, no reconcile; the manual workflow run is the test button.

## Install

```bash
./setup.sh figma/design-agent
```

Asks for: target repo, trigger prefix, an optional file key to scope to (the
`<key>` in `figma.com/design/<key>/…`; empty = every file the webhook's team
emits), and conventions. Secrets: `FIGMA_TOKEN` (scopes
`file_comments:write` + `files:read`) + Claude auth; relay: `GITHUB_PAT`,
`FIGMA_PASSCODE`. The installer prints the webhook-creation `curl` with your
worker URL filled in.

## Guardrails

ONE reply per summon, always to the thread root; comments only — never edits
designs, never resolves threads, never writes code; only verified repo claims
("I couldn't find that in the repo" over guessing); trigger-gated at the
relay; loop-proof via the agent marker (replies are posted by the token
owner's account and echo back through the webhook); 3900-char cap enforced;
`DRY_RUN=1` local testing; transcript artifacts per run.

## Beta → stable checklist (live-fire against a real team)

- [ ] Webhook creation PING round-trip (relay answers 200, webhook goes healthy)
- [ ] Wrong-passcode delivery rejected with 401
- [ ] Summon → answer round-trip in a comment thread (reply lands on the root)
- [ ] Trigger-prefix noise gate on a busy file (review chatter never triggers CI)
- [ ] Fragment-joining on a multi-part comment (mention-style comments split the text)
