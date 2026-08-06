# GitLab CI runtime — reconcile mode (v1) + per-item dispatch

The cheapest possible ingress: **no relay, no Cloudflare account, nothing to
deploy**. GitLab pipeline trigger tokens ride in the URL, so any tool whose
webhook accepts a plain URL POSTs straight into GitLab:

```
https://gitlab.com/api/v4/projects/<PROJECT_ID>/ref/main/trigger/pipeline?token=<TRIGGER_TOKEN>
```

Each delivery triggers a **reconcile** run (empty `ITEM_ID`): the payload is
ignored and the driver re-fetches truth from the tool's API — the doorbell
pattern taken to its logical extreme. Duplicate, forged, or malformed
doorbells can only waste a pipeline run, never inject data.

## Setup

1. Repo on GitLab with the agent installed (`scripts/<x>-agent/…` — run this
   repo's installer against your clone; skip the relay + GitHub-secrets steps).
2. Settings → CI/CD → Pipeline trigger tokens → add one.
3. Settings → CI/CD → Variables (masked): the tool token(s) and brain auth
   (same names as the GitHub secrets — `CLICKUP_TOKEN`,
   `CLAUDE_CODE_OAUTH_TOKEN`/`ANTHROPIC_API_KEY`, …).
4. Copy [`gitlab-ci.example.yml`](gitlab-ci.example.yml) into your
   `.gitlab-ci.yml`, set `AGENT_DIR`.
5. Point the tool's webhook at the trigger URL.

## Per-item mode (relay + `DISPATCH_KIND=gitlab`)

If you want the relay's signature verification, noise filtering, and per-item
granularity back, keep the recipe's Cloudflare Worker and retarget its
dispatch — no worker-code changes:

1. In the deployed relay's `wrangler.toml` `[vars]`:
   `DISPATCH_KIND = "gitlab"`, `GITLAB_TRIGGER_URL =
   "https://gitlab.com/api/v4/projects/<PROJECT_ID>/trigger/pipeline"`, and
   optionally `GITLAB_REF` (default `main`).
2. Secret: `wrangler secret put GITLAB_TRIGGER_TOKEN` (the same trigger token).
3. Point the tool's webhook at the Worker as usual.

The relay then triggers the pipeline with `variables[ITEM_ID]`,
`variables[ITEM_TYPE]`, `variables[EVENT_KIND]` (plus the ask/notify extras
when present), and the `agent-item` job in the example runs exactly that item;
deliveries the relay filters out never start a pipeline at all.

## `gh` shim (experimental)

Playbooks that write back to the host speak `gh`. On a GitLab-hosted repo,
install the [`core/hosts/`](../../hosts/) gh→glab shim once:

```sh
mkdir -p scripts/gh-shim
cp <ai-automations>/core/hosts/gh-shim-gitlab.sh scripts/gh-shim/gh
chmod +x scripts/gh-shim/gh
```

and uncomment the PATH line in the example. With `glab` authenticated on the
runner (project access token in `GITLAB_TOKEN` — `CI_JOB_TOKEN` can't create
MRs/issues), `implement` opens merge requests and escalation files GitLab
issues. Treat as **experimental**: the shim covers exactly the surface the
shipped playbooks use and exits loudly (64) on anything else.

## Honest limits

- **Relay-less mode is reconcile-only granularity**: every doorbell scans the
  watched columns/statuses + tracked items (a few extra API reads per event
  vs. per-item dispatch). Fine at team scale — or use per-item mode above.
- **`implement`/escalation on GitLab go through the shim** and are
  experimental; the notify recipes stay GitHub-native (their triggers are
  GitHub releases/workflow runs). First-class host adapters are the remaining
  Phase 3b work.
- **The trigger token is the auth** — treat it like a secret (it can only
  start pipelines, nothing else).
- State-in-git works unchanged (orphan branch on the GitLab remote).
