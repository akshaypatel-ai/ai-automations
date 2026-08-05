# Netlify Deploy Agent

Failed Netlify deploys become AI triage issues grounded in the repo: a deploy
errors → the agent fetches the deploy from Netlify, reads THIS repository at
the implicated build config (the deploy is of this repo — the commit sha is
in the deploy metadata), and files ONE GitHub issue — what failed, what the
error means, the likely cause verified against the code, where to look, and
deploy + commit links. When another deploy of the SAME commit fails, it adds
ONE comment on that issue — never a duplicate. Netlify itself is never
written to; the agent never retries, locks, or publishes deploys.

Status: **beta** — the triage-family driver (Sentry-shaped) pointed at
Netlify's deploys API; needs live-fire testing against a real site.

## Event coverage (relay routes the notification surface)

| Handler | Netlify events | Status |
|---|---|---|
| `deploys` | "Deploy failed" outgoing webhook | ✅ implemented (analyze playbook) |
| — | "Deploy succeeded" / "Deploy started" / everything else | Not subscribed; anything not in state `error` that arrives anyway is acknowledged at the edge (200), never dispatched — a future ship handler could forward "Deploy succeeded" to a notify recipe |

| Trigger | Playbook | Output (GitHub only — Netlify is never written) |
|---|---|---|
| A deploy ends in error | `analyze` | ONE GitHub issue (what failed, the error, likely cause, where to look, links) — or ONE dedupe comment when the commit sha already has an open issue |

## Netlify-specific mechanics

- **JWS signature, verified twice**: every delivery carries `X-Webhook-Signature` = a JWT signed HS256 with a secret YOU choose in the notification form. The relay verifies (1) the JWT signature (WebCrypto HMAC-SHA256 over `header.payload`) AND (2) the claims: `iss` must be `netlify` and `sha256` must equal the hex SHA-256 of the raw request body — so a captured signature can't be replayed over a forged body.
- **No public build-log API — stated plainly**: Netlify's build-log endpoints are not public/stable, so the prompt context is the deploy object's `error_message` (often the failing step + last lines of output), the commit metadata, and THE REPO ITSELF. The playbook compensates by reading the build config the error implicates (`netlify.toml`, package scripts) and links the dashboard deploy log for the full output.
- **Only failed deploys are forwarded**: the notification subscribes to "Deploy failed" only, and belt-and-braces the relay drops anything whose body isn't in state `error` — failed builds are this recipe's entire business.
- **Dedupe is sha-search based, not state-keyed**: a deploy errors exactly once, so state only prevents reprocessing the same deploy (duplicate deliveries, retriggers). A NEW deploy of an already-failed commit is caught by the playbook searching open labeled issues for the commit sha first — it comments instead of filing.
- **Site scoping at the edge**: the notification is already per-site, and the relay additionally drops deliveries whose `site_id` doesn't match the configured site (fail open when the payload omits it). The same site id scopes reconcile scans and the workflow's auth check.
- **Read-only toward Netlify**: the token is only ever used for GETs; the write target is GitHub issues.

## Install

```bash
./setup.sh netlify/deploy-agent
```

Asks for: target repo, the site id (Site configuration → Site details → API
ID), issue label, and the standard conventions. Secrets: `NETLIFY_TOKEN`,
Claude auth (+ optional `AGENT_GH_PAT`); relay: `GITHUB_PAT`,
`NETLIFY_JWS_SECRET` (you choose it — e.g. `openssl rand -hex 24` — and enter
the SAME value in the notification form). The installer prints the exact
clicks that create the notification (Site configuration → Notifications →
Deploy notifications → Outgoing webhook, event "Deploy failed").

## Guardrails

ONE GitHub issue per failing commit sha (recurrences are comments; closed
issues stay closed), read-only toward Netlify — never retries/locks/
publishes deploys, no secrets from error output into issues (env values and
tokens are scrubbed), never writes code,
`--dangerously-skip-permissions` only in the disposable CI runner, `DRY_RUN=1`
local testing, full transcript artifacts per run.

## Beta → stable checklist (live-fire against a real site)

- [ ] JWS verification through the relay on a real delivery — including the tampered-body case (valid signature, swapped body → 401)
- [ ] Deploy failed → analyze → GitHub issue round-trip on a real failed build
- [ ] Same-sha dedupe: a second failed deploy of the commit becomes a comment, not a duplicate issue
- [ ] Empty-`error_message` path: the issue still files, says so plainly, and points at the dashboard deploy log
- [ ] Site scoping: a delivery for a different `site_id` is dropped at the edge; a payload without one fails open
