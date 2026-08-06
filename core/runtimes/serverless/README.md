# Serverless runtime

Run agents with **no box and no CI minutes** — pennies per run, scale to
zero between events. Two deployment shapes share this directory:

1. **`DISPATCH_KIND=url` → a Lambda-style HTTPS handler** (this directory's
   `lambda-handler.mjs` + `Dockerfile.lambda`): the relay keeps doing the
   webhook verification/filtering on Cloudflare, and its doorbell POST goes
   to your function instead of GitHub.
2. **Tool → Cloud Run / Fly.io running the docker-server receiver
   directly** (the unchanged image from
   [`core/runtimes/docker-server/`](../docker-server/)): no relay at all —
   the receiver executes each recipe's worker verbatim, so verification
   happens in the service itself.

They are not interchangeable — see the honest note under Cloud Run before
wiring anything.

## The `DISPATCH_KIND=url` payload contract

Set two things on any relay worker (all 33 carry the same `dispatch()`):

```toml
# relay/wrangler.toml
DISPATCH_KIND = "url"
DISPATCH_URL  = "https://<your-function-url>/"
```

```bash
wrangler secret put DISPATCH_TOKEN   # optional shared secret
```

The relay then POSTs `DISPATCH_URL` with:

- `Content-Type: application/json`
- `Authorization: Bearer <DISPATCH_TOKEN>` — only when the secret is set
- `User-Agent` — the worker's existing UA (e.g. `ai-automations-clickup-relay`)
- Body — **the exact shape GitHub `repository_dispatch` receives**:

```json
{
  "event_type": "clickup_event",
  "client_payload": { "kind": "taskCommentPosted", "item_id": "abc123", "item_type": "Task" }
}
```

So any HTTPS job runner — Lambda Function URL, a Cloud Run service you
write, a custom receiver on a box — consumes the same contract, and
retargeting is still just vars on the relay, zero worker-code changes.
GitHub behavior stays byte-identical when `DISPATCH_KIND` is unset.

## AWS Lambda

`lambda-handler.mjs` maps `client_payload` to the same env vars the
docker-server receiver sets and runs `scripts/<AGENT_NAME>/agent-run.sh`
**synchronously**. Synchronous is fine: the relay already answered the
tool's webhook, so nothing upstream is waiting on this function.

**The honest cap**: Lambda kills invocations at **15 minutes**, hard.
Analyze / respond / triage runs (2–8 min) fit comfortably. `implement`
playbook runs (15–20 min) **do not** — put those agents on docker-server or
Cloud Run. There is no partial credit: a run killed at 15:00 writes no
state and pushes nothing.

```bash
# 1. Build + push the image (from this directory)
aws ecr create-repository --repository-name agent-lambda
docker build -f Dockerfile.lambda -t agent-lambda .
docker tag agent-lambda <acct>.dkr.ecr.<region>.amazonaws.com/agent-lambda:latest
aws ecr get-login-password | docker login --username AWS --password-stdin <acct>.dkr.ecr.<region>.amazonaws.com
docker push <acct>.dkr.ecr.<region>.amazonaws.com/agent-lambda:latest

# 2. Create the function — one function per agent
aws lambda create-function --function-name clickup-agent \
  --package-type Image \
  --code ImageUri=<acct>.dkr.ecr.<region>.amazonaws.com/agent-lambda:latest \
  --role <lambda-exec-role-arn> \
  --memory-size 2048 --timeout 900 \
  --environment "Variables={AGENT_NAME=clickup-agent,GITHUB_REPO=you/agent-repo,GITHUB_PAT=...,DISPATCH_TOKEN=...,ANTHROPIC_API_KEY=...,CLICKUP_TOKEN=...}"

# 3. Function URL — public endpoint, auth is the DISPATCH_TOKEN check
aws lambda create-function-url-config --function-name clickup-agent --auth-type NONE
aws lambda add-permission --function-name clickup-agent \
  --action lambda:InvokeFunctionUrl --principal '*' \
  --function-url-auth-type NONE --statement-id public-url
```

Then on the relay: `DISPATCH_KIND = "url"`, `DISPATCH_URL = <the function
URL>`, and `wrangler secret put DISPATCH_TOKEN` with the same value you set
on the function. With `AuthType=NONE` the bearer check in the handler is
your only gate — **always set `DISPATCH_TOKEN`** on internet-facing
functions.

Notes:

- The repo clones into `/tmp/repo` on cold start (`GITHUB_REPO` +
  `GITHUB_PAT`) and re-pulls every invoke; warm containers reuse the clone.
  `/tmp` defaults to 512 MB — raise `--ephemeral-storage` for big repos.
- 2048 MB memory also buys you a full vCPU; the driver is mostly waiting on
  the model API, so don't overspend here.
- Concurrent events for the same agent can run in parallel containers.
  The drivers treat every run as "everything new since saved state", so
  duplicate work is wasted money, not corruption — but if an agent is busy,
  set the function's reserved concurrency to 1 to serialize.

## Google Cloud Run

Deploy the **existing docker-server image unchanged** — the receiver
auto-discovers agents and serves their webhook paths:

```bash
# from core/runtimes/docker-server/ (its Dockerfile, not Dockerfile.lambda)
gcloud run deploy agents --source . \
  --min-instances 0 --no-cpu-throttling --timeout 3600 \
  --memory 2Gi --allow-unauthenticated \
  --set-env-vars "GITHUB_REPO=you/agent-repo,GITHUB_PAT=...,ANTHROPIC_API_KEY=...,CLICKUP_WEBHOOK_SECRET=..."
```

Then point **the tool's webhook directly at the service** — no relay, no
Cloudflare Worker at all:

```
https://agents-<hash>-<region>.run.app/<agent-name>/hook[...]
```

The receiver runs the recipe's worker verbatim, so signature verification
and noise filtering happen right there; it answers the webhook fast and
runs the job from a background queue. That is why the flags matter:
`--no-cpu-throttling` (CPU always allocated) keeps the queued run executing
after the 200 goes back, and `--timeout 3600` gives long runs an hour.

> **Do not wire `DISPATCH_KIND=url` at the docker-server receiver.**
> `receiver.mjs` serves **webhook paths** (`/<agent>/hook...`) and expects
> each tool's native webhook body — it does **not** accept the
> `{event_type, client_payload}` url-dispatch shape, and a relay pointed at
> it will get 404s (or worse, a worker rejecting an unsigned body). The two
> patterns are: **tool → Cloud Run receiver directly** (recommended here),
> or **relay → `DISPATCH_KIND=url` → the Lambda-style handler** above.

Honest scale-to-zero notes: a cold start runs the image's entrypoint —
git clone plus brain-CLI install — so the first webhook after an idle spell
waits 30–90 s before the worker even sees it (most tools retry failed
webhook deliveries; check yours). And with `--min-instances 0`, Cloud Run may reclaim
an instance it considers idle — CPU-always-allocated keeps background work
running while the instance lives, but a queued run on an instance that gets
scaled in is gone. In practice instances linger well past the last request;
for a busy or long-running agent, `--min-instances 1` (~$15/mo at 1 vCPU
always-on) removes the gamble — at which point compare with a $5 VPS.

## Fly.io

Same receiver image as a Fly app:

```toml
# fly.toml (app dir = core/runtimes/docker-server/)
[http_service]
  internal_port = 8787
  auto_stop_machines  = "off"   # required — see below
  auto_start_machines = true
  min_machines_running = 1
```

```bash
fly launch --no-deploy && fly secrets set GITHUB_PAT=... ANTHROPIC_API_KEY=... && fly deploy
```

`auto_stop_machines = "off"` because the receiver answers 200 and then runs
the job in the background — Fly's autostop sees an idle HTTP service and
would kill the machine mid-run. So this is **not scale-to-zero**: it's a
cheap always-on micro (a shared-cpu-1x with 2 GB is ~$10/mo, less with
reserved pricing). If you want true scale-to-zero, that's the Lambda path.

## What does a run cost?

Rough numbers, 1 vCPU / 2 GB class, model-API cost excluded (that's the
same everywhere):

| | 3-min run (analyze/triage) | 20-min run (implement) | Free tier |
|---|---|---|---|
| **Lambda** (2048 MB) | ~$0.006–0.01 | ✗ impossible (15-min cap) | 400k GB-s/mo ≈ 1,100 such runs free |
| **Cloud Run** (always-allocated CPU) | ~$0.005 | ~$0.03 | modest monthly free tier |
| **Fargate** (if you need >15 min on AWS) | ~$0.005 | ~$0.02 — but no scale-to-zero HTTP trigger without extra plumbing | none |
| **$5 VPS** (docker-server) | flat | flat | — |

Crossover: at ~**150 long runs a month** (150 × $0.03 ≈ $4.50) serverless
stops being cheaper than the $5 VPS — below that, pay pennies and keep zero
infrastructure; above it (or for any `implement`-heavy agent), the
[docker-server runtime](../docker-server/) wins on both cost and the 15-min
cap.
