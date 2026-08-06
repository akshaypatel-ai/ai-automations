# Execution runtimes

Layer 3 of the architecture: **where the agent actually runs**. The drivers,
playbooks, brains, and state layer are runtime-neutral — a runtime only has to
answer four questions:

| Question | GitHub Actions (default) | Docker-server | GitLab CI | Bitbucket Pipelines (v1) | Serverless |
|---|---|---|---|---|---|
| How does an event start a run? | relay → `repository_dispatch` | receiver runs the SAME relay worker in-process, queues a local run | relay with `DISPATCH_KIND=gitlab` → per-item pipeline; or tool webhooks the **trigger-token URL directly** (no relay) → reconcile run | relay with `DISPATCH_KIND=bitbucket` → `custom: agent` pipeline | relay with `DISPATCH_KIND=url` → Lambda handler; or tool webhooks the **Cloud Run receiver directly** (no relay) |
| Where do secrets live? | repo Actions secrets | `.env` on your box | masked CI/CD variables | secured repository variables | provider env (function/service config) |
| What does a run cost? | free tier, then per-minute | flat (the box) | free tier, then per-minute | free tier, then per-minute | pennies per run, scale to zero |
| Where's the audit trail? | CI artifacts | `.agent-out/` on the repo volume | CI artifacts | pipeline artifacts | provider logs (CloudWatch / Cloud Logging) |

## Available

- [`github-actions/`](github-actions/) — ✅ default. Zero infra; every recipe
  ships its workflow pre-rendered.
- [`docker-server/`](docker-server/) — ✅ full parity for all relay-driven
  recipes with **zero per-recipe porting**: the receiver executes each
  recipe's Cloudflare Worker verbatim (same verification and filtering) and
  turns the dispatch into a local queued run. Flat cost, no cold starts,
  Ollama-ready via driver-mediated brains.
- [`gitlab-ci/`](gitlab-ci/) — ✅ reconcile mode (relay-less trigger tokens)
  **plus per-item dispatch** via `DISPATCH_KIND=gitlab` on the relay.
  `implement`/escalation possible through the [`core/hosts/`](../hosts/)
  gh→glab shim (experimental); details in its README.
- [`bitbucket/`](bitbucket/) — ✅ v1: per-item dispatch via
  `DISPATCH_KIND=bitbucket` on the relay. Analyze/respond/triage-note flows
  (tool-API write-back); PR/issue write-back awaits host adapters.
- [`serverless/`](serverless/) — ✅ pennies per run, scale to zero. Either
  `DISPATCH_KIND=url` on the relay → the shipped AWS Lambda handler
  (15-min cap: analyze/respond/triage, not `implement`), or the
  docker-server receiver deployed unchanged on Cloud Run / Fly.io with the
  tool's webhook pointed at it directly (60-min timeout).

Retargeting a relay is one var: every relay worker carries the same
`dispatch()` function, and `DISPATCH_KIND` (`github` default / `gitlab` /
`bitbucket` / `url`) picks the runtime without touching worker code —
`url` POSTs the GitHub-dispatch payload shape to any HTTPS job runner.

## Picking one

Every relay-driven recipe's installer now **asks** ("Runtime", right after
the brain question) and saves the answer in `automation.config.json`:
gitlab-ci/bitbucket installs get the example CI file rendered into the agent
dir with `AGENT_DIR` pre-set, and the next-steps end with a per-runtime
overlay of just the differences. Only the notify recipes and GitHub Issues
skip the question (GitHub-native triggers).

- **Just want it working**: GitHub Actions — the default answer; zero infra.
- **Frequent long runs** (implement playbooks, 15–20 min): a $5 VPS with
  docker-server beats metered minutes within a handful of runs a day — and
  it's the only path to fully-local models.
- **GitLab-hosted team**: gitlab-ci — per-item via the relay, or relay-less
  reconcile for zero deploys; MR write-back via the shim (experimental).
- **Bitbucket-hosted team**: bitbucket v1 for analyze/respond/triage flows.
- **Low-volume, no infra, no CI**: serverless — Lambda for short runs
  behind `DISPATCH_KIND=url`, Cloud Run for long ones; below ~150 long
  runs/month it undercuts even the VPS.

Mixing is normal: notify recipes stay on Actions (their triggers are
GitHub-native), while your busiest board agent moves to the server.
