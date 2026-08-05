# Vercel Deploy Agent

Failed Vercel deployments become AI triage issues grounded in the repo: a
deployment errors → the agent fetches the deployment + its build logs from
Vercel, reads THIS repository at the failing build step (the deploy is of this
repo — the commit sha is in the deployment metadata), and files ONE GitHub
issue — what failed, what the log excerpt means, the likely cause verified
against the code, where to look, and deployment + commit links. When another
deployment of the SAME commit fails, it adds ONE comment on that issue —
never a duplicate. Vercel itself is never written to; the agent never retries,
cancels, or promotes deployments.

Status: **beta** — the triage-family driver (Sentry-shaped) pointed at
Vercel's deployment/events API; needs live-fire testing against a real
project.

## Event coverage (relay routes the webhook surface)

| Handler | Vercel events | Status |
|---|---|---|
| `deployments` | `deployment.error` | ✅ implemented (analyze playbook) |
| — | `deployment.created` / `succeeded` / `canceled`, everything else | Acknowledged at the edge (200), never dispatched — a future ship handler could forward `deployment.succeeded` to a notify recipe |

| Trigger | Playbook | Output (GitHub only — Vercel is never written) |
|---|---|---|
| A deployment ends in ERROR | `analyze` | ONE GitHub issue (what failed, log excerpt, likely cause, where to look, links) — or ONE dedupe comment when the commit sha already has an open issue |

## Vercel-specific mechanics

- **Signature**: every delivery carries `x-vercel-signature` = hex HMAC-SHA1 of the raw body, keyed with the webhook's secret (shown exactly once at creation) — verified at the edge.
- **Only `deployment.error` is forwarded**: created/succeeded/canceled deliveries are acknowledged and dropped — failed builds are this recipe's entire business.
- **Build logs are prompt context**: the driver fetches `/v3/deployments/<id>/events?builds=1` and inlines the tail (~8000 chars) into the playbook prompt, so the agent triages the actual failure output, not a summary.
- **Dedupe is sha-search based, not state-keyed**: a deployment errors exactly once, so state only prevents reprocessing the same deployment (duplicate deliveries, retriggers). A NEW deployment of an already-failed commit is caught by the playbook searching open labeled issues for the commit sha first — it comments instead of filing.
- **Team scoping is a query param**: when a team id is configured, `api.sh` appends `teamId=` to every call (handles paths with and without existing query strings).
- **Read-only toward Vercel**: the token is only ever used for GETs; the write target is GitHub issues.

## Install

```bash
./setup.sh vercel/deploy-agent
```

Asks for: target repo, team id + project id (both optional — Enter to skip),
issue label, and the standard conventions. Secrets: `VERCEL_TOKEN`, Claude
auth (+ optional `AGENT_GH_PAT`); relay: `GITHUB_PAT`,
`VERCEL_WEBHOOK_SECRET`. The installer prints the exact clicks that create
the webhook (Team Settings → Webhooks, event `deployment.error`) and warns
that its secret is shown only once.

## Guardrails

ONE GitHub issue per failing commit sha (recurrences are comments; closed
issues stay closed), read-only toward Vercel — never retries/cancels/
redeploys/promotes, no secrets from build logs into issues (env values and
tokens are scrubbed), never writes code,
`--dangerously-skip-permissions` only in the disposable CI runner, `DRY_RUN=1`
local testing, full transcript artifacts per run.

## Beta → stable checklist (live-fire against a real project)

- [ ] Webhook + x-vercel-signature verification through the relay on a real delivery
- [ ] deployment.error → analyze → GitHub issue round-trip on a real failed build
- [ ] Same-sha dedupe: a second failed deployment of the commit becomes a comment, not a duplicate issue
- [ ] Team-scoped token path (`teamId=` appended) end to end
- [ ] Log-secret scrubbing spot-check: seed a fake env value into a failing build log and confirm it never reaches the issue
