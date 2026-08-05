# Runtime adapter: GitHub Actions

The default runtime. Zero infrastructure: a relay forwards tool webhooks as
`repository_dispatch` events; `workflow_dispatch` is the manual
reconcile/recovery button.

## What a runtime adapter provides

1. **Trigger wiring** — how an external event starts a run.
2. **Secret store mapping** — where each credential lives (table below).
3. **Job definition** — installs the tool CLI + AI brain, then calls the recipe's entrypoint script.
4. **Artifacts** — uploads the run's prompt/transcript/result for auditing.
5. **Manual entry point** — reconcile-everything and process-one-item runs.

In Phase 1 each recipe ships its own workflow file conforming to this contract
(see `automations/basecamp/board-agent/files/.github/workflows/`); Phase 3
extracts the shared parts into templates here, alongside `gitlab-ci/`,
`bitbucket/`, and `docker-server/` adapters.

## Secrets mapping (repo → Settings → Secrets → Actions)

| Secret | Purpose |
|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` *or* `ANTHROPIC_API_KEY` | AI brain auth (subscription token from `claude setup-token`, or pay-per-token key; API key wins if both set) |
| `BASECAMP_CREDENTIALS_JSON` (per-tool) | Tool API credentials seeded into the runner each run |
| `AGENT_GH_PAT` (optional, classic PAT `repo` scope) | Agent PRs/pushes trigger CI and show a human identity; without it PRs open as `github-actions[bot]` and their CI runs need manual approval |

Also enable: Settings → Actions → General → **"Allow GitHub Actions to create
and approve pull requests"**.
