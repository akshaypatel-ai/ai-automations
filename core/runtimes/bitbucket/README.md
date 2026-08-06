# Bitbucket Pipelines runtime (v1)

Per-item dispatch on a Bitbucket-hosted repo. Bitbucket has no
`repository_dispatch` equivalent and its webhooks can't carry a secret in the
URL to a pipeline directly — so v1 keeps the recipe's Cloudflare relay and
simply retargets its dispatch: `DISPATCH_KIND = "bitbucket"` makes the
worker start the `agent` custom pipeline through the Bitbucket API instead of
calling GitHub. Verification, filtering, and per-item granularity are
identical to the GitHub path; no worker-code changes.

## Setup

1. Repo on Bitbucket with the agent installed (`scripts/<x>-agent/…` — run
   this repo's installer against your clone; skip the GitHub-secrets steps).
2. **Repository access token** (Repository settings → Access tokens) with the
   `pipeline:write` scope — this is the Bearer token the relay uses to start
   pipelines.
3. **Repository variables** (Repository settings → Pipelines → Repository
   variables, secured): the tool token(s) and brain auth, same names as the
   GitHub secrets (`CLICKUP_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN` /
   `ANTHROPIC_API_KEY`, …).
4. Copy [`bitbucket-pipelines.example.yml`](bitbucket-pipelines.example.yml)
   into your `bitbucket-pipelines.yml`, set `AGENT_DIR`, and enable Pipelines
   (Repository settings → Pipelines → Settings).
5. Deploy the recipe's relay as usual, with these `[vars]` in `wrangler.toml`:
   `DISPATCH_KIND = "bitbucket"`, `BITBUCKET_WORKSPACE = "<workspace>"`,
   `BITBUCKET_REPO = "<repo-slug>"`, optionally `BITBUCKET_REF` (default
   `main`) — and the secret: `wrangler secret put BITBUCKET_TOKEN` (the
   access token from step 2).
6. Point the tool's webhook at the Worker.

The relay then POSTs to
`https://api.bitbucket.org/2.0/repositories/<workspace>/<repo>/pipelines`
with a `custom: agent` selector and `ITEM_ID` / `ITEM_TYPE` / `EVENT_KIND`
variables (plus the ask/notify extras when present).

## Honest limits of v1

- **No `gh` equivalent here yet**: Bitbucket write-back (PRs, issue
  comments) has no shim, so run **analyze / respond / triage-note flows
  only** — playbooks whose write path is the *tool's* API (comments on the
  ClickUp task, the Zendesk ticket, …) work fully; `implement` (pull
  requests) and repo-issue escalation are future host-adapter work
  (Phase 3b, remaining).
- **The relay is required** — there's no relay-less trigger-token mode like
  GitLab's; treat the repository access token like any other secret (scope it
  to `pipeline:write` only).
- **State-in-git works unchanged**: the orphan state branch pushes over the
  repo's own remote; nothing GitHub-specific in the state layer.
- Runs bill against Pipelines minutes (free tier first, then per-minute).
