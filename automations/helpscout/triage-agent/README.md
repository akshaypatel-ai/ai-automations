# Help Scout Triage Agent

Support triage with a human between the agent and the customer: a conversation
arrives → the agent reads it, grounds itself in your product's repository, and
posts ONE **internal note** — a category plus a draft reply the human agent
can send nearly verbatim; real product bugs get escalated as GitHub issues.
Customer follow-ups refresh the note; when an agent has already replied, the
agent stays silent. It never messages customers and never changes conversation
status, assignee, or tags — humans own the queue.

Status: **beta** — ports the production-proven Zendesk triage flow to Help
Scout's Mailbox API 2.0; needs live-fire testing against a real Help Scout
account.

## Event coverage (relay routes the webhook events)

| Handler | Help Scout events | Status |
|---|---|---|
| `conversations` | `convo.created`, `convo.customer.reply.created`, `convo.agent.reply.created` — `convo.note.created` dropped at the edge (the agent's own note echo) | ✅ implemented (triage / respond playbooks) |
| anything else | any other subscribed event | Routed, skips cleanly (unknown event → ignored at the edge) |

## Help Scout-specific mechanics

- **OAuth2 client-credentials — the only recipe whose `api.sh` manages the auth lifecycle**: there is no static API key; `api.sh` POSTs the app id + secret to `/v2/oauth2/token`, caches the bearer token (~48h life) in `$OUT_DIR/.hs-token`, and refreshes it once the cache file is older than 100 minutes. Playbooks and helpers never see the token dance. The dotfile name keeps it out of the uploaded artifacts, which skip hidden files.
- **Signed webhooks**: every delivery carries `X-HelpScout-Signature` = base64 HMAC-SHA1 of the raw body, keyed with the Secret Key YOU choose in the webhook form; the event name rides in `X-HelpScout-Event`. Verified at the edge with a constant-time compare.
- **Thread types are the routing signal**: `customer` = customer message, `message` = agent public reply, `note` = internal note, `lineitem` = system event. The resolver counts only `customer`/`message` threads; an agent reply is the human-handled signal the respond playbook goes silent on.
- **Thread recency**: thread ids are numeric and monotonic — compared numerically, no timestamp parsing.
- **Note create returns 201 with no body**: `POST /v2/conversations/{id}/notes` answers with only a `Resource-ID` header — `note.sh`'s success check is curl's exit status, and there is no JSON to verify. It also converts the playbook's plain text into the simple HTML Help Scout expects.
- **Bodies are HTML**: the resolver strips tags before marker checks, and attachments arrive as links inside the thread bodies.

## Install

```bash
./setup.sh helpscout/triage-agent
```

Asks for: target repo, optional mailbox id, escalation label, and the standard
conventions. Secrets: `HELPSCOUT_APP_ID` + `HELPSCOUT_APP_SECRET`, Claude auth
(+ optional `AGENT_GH_PAT`); relay: `GITHUB_PAT`, `HELPSCOUT_SECRET_KEY`. The
installer prints the exact steps — My Apps → Create App for the id/secret
pair, and Manage → Apps → Webhooks for the callback URL, Secret Key, and the
three events to select.

## Guardrails

Internal notes only (`note.sh` posts to the `/notes` endpoint — structurally
cannot message customers), never changes status/assignee/tags, at most one
note per run, never escalates twice (issue URL tracked in state), no customer
personal data in GitHub issues, `--dangerously-skip-permissions` only in the
disposable CI runner, `DRY_RUN=1` local testing, full transcript artifacts
per run.

## Beta → stable checklist (live-fire against a real Help Scout account)

- [ ] Token refresh across the 100-minute cache boundary (long run or `touch -t` the cache file back)
- [ ] Signature verification round-trip through the relay (webhook test delivery; wrong Secret Key → 401)
- [ ] triage → respond round-trip on a test conversation
- [ ] Human-reply silence: the agent posts nothing when an agent already replied (`message` thread)
- [ ] Escalation dedupe: a bug follow-up comments on the existing issue instead of opening a second one
