# Execution runtimes

Layer 3 of the architecture: **where the agent actually runs**. The drivers,
playbooks, brains, and state layer are runtime-neutral — a runtime only has to
answer four questions:

| Question | GitHub Actions (default) | Docker-server | GitLab CI (v1) |
|---|---|---|---|
| How does an event start a run? | relay → `repository_dispatch` | receiver runs the SAME relay worker in-process, queues a local run | tool webhooks the pipeline **trigger-token URL directly** (no relay) → reconcile run |
| Where do secrets live? | repo Actions secrets | `.env` on your box | masked CI/CD variables |
| What does a run cost? | free tier, then per-minute | flat (the box) | free tier, then per-minute |
| Where's the audit trail? | CI artifacts | `.agent-out/` on the repo volume | CI artifacts |

## Available

- [`github-actions/`](github-actions/) — ✅ default. Zero infra; every recipe
  ships its workflow pre-rendered.
- [`docker-server/`](docker-server/) — ✅ full parity for all relay-driven
  recipes with **zero per-recipe porting**: the receiver executes each
  recipe's Cloudflare Worker verbatim (same verification and filtering) and
  turns the dispatch into a local queued run. Flat cost, no cold starts,
  Ollama-ready via driver-mediated brains.
- [`gitlab-ci/`](gitlab-ci/) — ✅ v1: relay-less reconcile mode via pipeline
  trigger tokens. Honest limits (reconcile granularity; `implement`/escalation
  need the Phase 3b host-CLI abstraction) documented in its README.
- Bitbucket Pipelines — 🔜 Phase 3b (with the `gh`/`glab` host-CLI
  abstraction that also completes GitLab).

## Picking one

- **Just want it working**: GitHub Actions — it's what every installer sets up.
- **Frequent long runs** (implement playbooks, 15–20 min): a $5 VPS with
  docker-server beats metered minutes within a handful of runs a day — and
  it's the only path to fully-local models.
- **GitLab-hosted team**: gitlab-ci v1 for analyze/discuss/triage flows today.

Mixing is normal: notify recipes stay on Actions (their triggers are
GitHub-native), while your busiest board agent moves to the server.
