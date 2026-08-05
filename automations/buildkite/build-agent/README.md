# Buildkite Build Agent

Failed Buildkite builds become AI triage issues grounded in the repo: a build
fails → the agent fetches the build + the failing job's log from Buildkite,
reads THIS repository at the implicated code (the pipeline builds this repo —
the commit sha is on the build), and files ONE GitHub issue — what failed,
what the log excerpt means, the likely cause verified against the code, where
to look, and build + commit links. When another build of the SAME commit
fails, it adds ONE comment on that issue — never a duplicate. Buildkite
itself is never written to; the agent never retries or cancels builds.

Status: **beta** — the triage-family driver (Vercel-shaped) pointed at
Buildkite's builds + job-log API; needs live-fire testing against a real
pipeline.

## Event coverage (relay routes the webhook surface)

| Handler | Buildkite events | Status |
|---|---|---|
| `builds` | `build.failed` | ✅ implemented (analyze playbook) |
| — | `build.scheduled` / `running` / `passed`, everything else | Acknowledged at the edge (200), never dispatched — a future ship handler could forward `build.passed` to a notify recipe |

| Trigger | Playbook | Output (GitHub only — Buildkite is never written) |
|---|---|---|
| A build ends in state `failed` | `analyze` | ONE GitHub issue (what failed, log excerpt, likely cause, where to look, links) — or ONE dedupe comment when the commit sha already has an open issue |

## Buildkite-specific mechanics

- **Dual delivery auth, handled honestly**: Buildkite's webhook service shows a Token, and deliveries have historically carried two headers keyed by it — `X-Buildkite-Signature` (`timestamp=<t>,signature=<hex>`, hex HMAC-SHA256 of `<t>.<body>`) and `X-Buildkite-Token` (the plain token). The relay verifies the signature whenever that header is present and falls back to comparing the token header otherwise; the signature proves the body wasn't tampered with, the token only proves the sender knows it.
- **The failing job's log is prompt context**: the driver fetches the build, picks the first failed `script` job, pulls `/builds/<n>/jobs/<id>/log`, and inlines the tail (~8000 chars) into the playbook prompt — the agent triages the actual failure output, not a summary.
- **ANSI stripping**: Buildkite logs are raw terminal output; the driver strips color escape sequences with sed before the tail reaches the prompt, so excerpts lifted into issues read clean.
- **Dedupe is sha-search based, not state-keyed**: state only prevents reprocessing the same build number (duplicate deliveries, retriggers). A NEW failed build of an already-failed commit is caught by the playbook searching open labeled issues for the commit sha first — it comments instead of filing.
- **Org/pipeline scoping**: every API path is scoped to the configured org + pipeline slugs, and the relay drops deliveries whose `pipeline.slug` doesn't match `WATCHED_PIPELINE` (failing open when the payload omits it).
- **Read-only toward Buildkite**: the token is only ever used for GETs (scopes `read_builds` + `read_build_logs` suffice); the write target is GitHub issues.

## Install

```bash
./setup.sh buildkite/build-agent
```

Asks for: target repo, Buildkite org + pipeline slugs, issue label, and the
standard conventions. Secrets: `BUILDKITE_TOKEN`, Claude auth (+ optional
`AGENT_GH_PAT`); relay: `GITHUB_PAT`, `BUILDKITE_WEBHOOK_SECRET`. The
installer prints the exact clicks that create the webhook notification
service (Organization Settings → Notification Services → Webhook, event
`build.failed`) and where its Token lives.

## Guardrails

ONE GitHub issue per failing commit sha (recurrences are comments; closed
issues stay closed), read-only toward Buildkite — never retries/cancels/
rebuilds, no secrets from CI logs into issues (env values and tokens are
scrubbed), never writes code, `--dangerously-skip-permissions` only in the
disposable CI runner, `DRY_RUN=1` local testing, full transcript artifacts
per run.

## Beta → stable checklist (live-fire against a real pipeline)

- [ ] Webhook through the relay on a real delivery — BOTH auth paths: X-Buildkite-Signature verification and the X-Buildkite-Token fallback
- [ ] build.failed → analyze → GitHub issue round-trip on a real failed build
- [ ] Same-sha dedupe: a second failed build of the commit becomes a comment, not a duplicate issue
- [ ] ANSI stripping spot-check on a real job log (colored output, not just plain text)
- [ ] Pipeline scoping: a delivery for another pipeline is dropped at the edge
