# Execution runtimes

Layer 3 of the architecture: **where the agent actually runs**. The drivers,
playbooks, brains, and state layer are runtime-neutral — a runtime only has to
answer four questions:

| Question | GitHub Actions (default) | Docker-server | GitLab CI | Bitbucket Pipelines (v1) |
|---|---|---|---|---|
| How does an event start a run? | relay → `repository_dispatch` | receiver runs the SAME relay worker in-process, queues a local run | relay with `DISPATCH_KIND=gitlab` → per-item pipeline; or tool webhooks the **trigger-token URL directly** (no relay) → reconcile run | relay with `DISPATCH_KIND=bitbucket` → `custom: agent` pipeline |
| Where do secrets live? | repo Actions secrets | `.env` on your box | masked CI/CD variables | secured repository variables |
| What does a run cost? | free tier, then per-minute | flat (the box) | free tier, then per-minute | free tier, then per-minute |
| Where's the audit trail? | CI artifacts | `.agent-out/` on the repo volume | CI artifacts | pipeline artifacts |

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

Retargeting a relay is one var: every relay worker carries the same
`dispatch()` function, and `DISPATCH_KIND` (`github` default / `gitlab` /
`bitbucket`) picks the runtime without touching worker code.

## Picking one

- **Just want it working**: GitHub Actions — it's what every installer sets up.
- **Frequent long runs** (implement playbooks, 15–20 min): a $5 VPS with
  docker-server beats metered minutes within a handful of runs a day — and
  it's the only path to fully-local models.
- **GitLab-hosted team**: gitlab-ci — per-item via the relay, or relay-less
  reconcile for zero deploys; MR write-back via the shim (experimental).
- **Bitbucket-hosted team**: bitbucket v1 for analyze/respond/triage flows.

Mixing is normal: notify recipes stay on Actions (their triggers are
GitHub-native), while your busiest board agent moves to the server.
