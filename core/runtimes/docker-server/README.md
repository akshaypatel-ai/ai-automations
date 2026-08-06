# Docker-server runtime

Run your installed agents on your own box — a $5 VPS, a home server, an
always-free cloud ARM instance. **Flat cost, no CI minutes, no cold starts**,
and the only runtime that pairs with fully-local models (Aider + Ollama via
driver-mediated mode).

## Why there is nothing to port

Every recipe already ships a Cloudflare Worker that does the hard part —
signature verification, challenge echoes, noise filtering. This runtime's
receiver (`receiver.mjs`, Node ≥20) runs those workers **verbatim** and
intercepts exactly one thing: the `repository_dispatch` call to GitHub
becomes a local queued run of `agent-run.sh`. Same verification, same
filtering, same drivers, same state-in-git — different engine underneath.

- Agents are auto-discovered from `scripts/*-agent/relay/worker.js` in the
  cloned repo and mounted at `POST /<agent-name>/…` (path suffix forwarded, so
  URL-secret hooks keep their shape: `/jira-agent/hook/<secret>`).
- Worker env = the rendered `wrangler.toml` `[vars]` + your `.env` (secrets).
- Runs are serialized per agent — safe by design, since every run processes
  "everything new since saved state".

## Setup (once)

```bash
# on your server, with Docker installed
cp -r core/runtimes/docker-server ~/agents && cd ~/agents
cp env.example .env && $EDITOR .env       # repo, PAT, brain auth, tool tokens, relay secrets
docker compose up -d --build
```

Put TLS in front (the compose file ships a commented Caddy service; a
Cloudflare Tunnel also works and needs no open ports). Then point each tool's
webhook at `https://<your-host>/<agent-name>/hook[...]` instead of the
Cloudflare Worker URL — everything else in each recipe's setup stays the same,
and you can run both runtimes side by side while migrating.

## What runs here — and what doesn't

- ✅ Every **relay-driven** recipe (project, triage, deploy/build, summon
  shapes — 26 of the 35) works unchanged.
- ❌ The **notify** recipes and `github/issues-agent` trigger from
  GitHub-native events (release published, workflow_run, issue labels) — they
  are GitHub Actions by nature and stay there. Run them on Actions alongside
  this server; the two runtimes share nothing but the repo.

## Operating

- **Logs**: `docker compose logs -f` (worker decisions + run output).
- **Update the repo/agents**: runs `git pull` before every job automatically;
  restart the container to pick up brain/receiver changes.
- **Manual reconcile**: `docker compose exec agents bash -lc 'cd /repo && bash scripts/<agent>/agent-run.sh'`.
- **Doctor**: run `./setup.sh doctor` against a local clone anytime.

## Honest notes

- The container holds real credentials in `.env` — treat the box like the
  secret store it is (disk encryption, SSH keys only, no shared hosts).
- `--dangerously-skip-permissions` now runs on YOUR machine, not a disposable
  runner. The container is the blast radius: keep the repo volume dedicated,
  don't mount anything else into it.
- Transcripts land in `.agent-out/` inside the repo volume (not uploaded
  anywhere) — rotate/clean as you see fit.
