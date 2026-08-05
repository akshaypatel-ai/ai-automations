# Sentry Triage Agent

Sentry error alerts become AI root-cause sketches filed as GitHub issues: an
issue alert fires → the agent fetches the Sentry issue + its latest event's
stack trace, opens THIS repository at the crash locations, and files ONE
GitHub issue — what's breaking, who's affected (frequency, first seen), the
likely root cause verified against the code, and where to look. When an
already-filed error recurs, it adds ONE comment with the fresh numbers —
never a duplicate issue. Sentry itself is never written to; humans own
resolution and assignment there.

Status: **beta** — the triage-family driver (Zendesk-proven) pointed at
Sentry's issue/event API; needs live-fire testing against a real project.

## Event coverage (relay routes the integration's webhook surface)

| Handler | Sentry resources | Status |
|---|---|---|
| `issues` | `event_alert` (issue alert fired), `issue` action `created` | ✅ implemented (analyze / update playbooks) |
| — | `installation` pings, other resources/actions (resolved, assigned, comments, metric alerts) | Acknowledged at the edge (200), never dispatched |

## Sentry-specific mechanics

- **Signature**: every delivery carries `sentry-hook-signature` = hex HMAC-SHA256 of the raw body, keyed with the Internal Integration's Client Secret — verified at the edge.
- **Routing**: the `sentry-hook-resource` header names the payload family; `event_alert` carries the issue id at `data.event.issue_id`, `issue` at `data.issue.id`.
- **Recurrence is count-based**: Sentry already groups events into issues, so "it happened again" is a growing `count` on the same issue — the resolver diffs it against saved state and comments instead of re-filing.
- **Read-only toward Sentry**: the token needs only `project:read` + `event:read`; the write target is GitHub issues.
- **Self-hosted works**: the API base URL is an installer question (default `https://sentry.io/api/0`).

## Install

```bash
./setup.sh sentry/triage-agent
```

Asks for: target repo, API base URL, org + project slugs, issue label, and
the standard conventions. Secrets: `SENTRY_TOKEN`, Claude auth (+ optional
`AGENT_GH_PAT`); relay: `GITHUB_PAT`, `SENTRY_CLIENT_SECRET`. The installer
prints the exact clicks that create the Internal Integration and wire it into
an issue alert rule.

## Guardrails

ONE GitHub issue per Sentry issue ever (recurrences are comments; closed
issues are never reopened), read-only toward Sentry, no PII from event
payloads (impact stays numeric), never writes code,
`--dangerously-skip-permissions` only in the disposable CI runner, `DRY_RUN=1`
local testing, full transcript artifacts per run.

## Beta → stable checklist (live-fire against a real project)

- [ ] Internal Integration webhook + sentry-hook-signature verification through the relay
- [ ] Alert → analyze → GitHub issue round-trip on a real event
- [ ] Recurrence dedupe: a second alert becomes a comment on the filed issue, not a duplicate
- [ ] Self-hosted Sentry base URL (non-sentry.io) end to end
- [ ] Stack-frame mapping onto repo paths on a real event (monorepo / path-prefix cases)
