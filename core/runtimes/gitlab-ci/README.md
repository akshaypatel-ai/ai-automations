# GitLab CI runtime — relay-less reconcile mode (v1)

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

## Honest limits of v1

- **Reconcile-only granularity**: every doorbell scans the watched
  columns/statuses + tracked items (a few extra API reads per event vs. the
  relay's per-item dispatch). Fine at team scale; the relay+dispatch mode for
  GitLab is Phase 3b.
- **Playbooks that write to GitHub** need `gh` + a GitHub-hosted repo — on a
  GitLab-hosted repo, `analyze`/`respond`/triage-note flows work today, but
  `implement` (merge requests via `glab`) and GitHub-issue escalation need the
  host-CLI abstraction — also Phase 3b. Until then: project recipes run
  analyze/discuss loops on GitLab; keep implement-enabled installs on
  GitHub-hosted repos.
- **The trigger token is the auth** — treat it like a secret (it can only
  start pipelines, nothing else).
- State-in-git works unchanged (orphan branch on the GitLab remote).
