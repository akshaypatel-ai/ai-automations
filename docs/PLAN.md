# ai-automations — Architecture & Build Plan

Goal: a public, plug-and-play repository of AI automations for team tools (Basecamp, Slack, Jira, Linear, Trello, ClickUp, LINE, …) where **every layer is a configurable choice**: where it runs (GitHub Actions, GitLab CI, Bitbucket, your own server), and which AI powers it (Claude Code, Anthropic API, OpenAI/Codex, Gemini, local models). Clone → `./setup.sh` → answer questions → done.

This plan is grounded in a production-proven reference implementation (a Basecamp board agent: webhook → Cloudflare Worker relay → GitHub Actions → headless Claude Code → PRs), generalized into pluggable layers.

---

## 1. Anatomy of an automation — the six layers

Every automation in this repo decomposes into the same six layers. "Plug-and-play" means each layer is an adapter you pick at install time.

```
┌─────────────┐   ┌─────────┐   ┌──────────────┐   ┌───────────┐   ┌─────────┐   ┌────────┐
│ 1. TOOL      │ → │ 2. RELAY │ → │ 3. RUNTIME    │ → │ 4. BRAIN   │ → │ 5. STATE │ → │ 6. AUDIT│
│ event source │   │ ingress  │   │ where it runs │   │ which AI   │   │ memory   │   │ trail  │
└─────────────┘   └─────────┘   └──────────────┘   └───────────┘   └─────────┘   └────────┘
 Basecamp, Slack,   CF Worker,     GitHub Actions,    Claude Code,    git orphan     transcripts
 Jira, Linear,      Lambda,        GitLab CI,         Codex CLI,      branch,        as CI
 Trello, ClickUp,   Vercel fn,     Bitbucket,         Gemini CLI,     server disk    artifacts /
 LINE               none (direct)  Docker server      raw API         (sqlite)       log files
```

Two invariants hold across every combination (these are the repo's core design bets, proven in production):

- **Doorbell pattern.** Webhook payloads only *wake* the automation. Every run re-fetches truth from the tool's API and diffs against saved state to decide what to do. Duplicates, out-of-order and missed events are harmless; a manual "reconcile" entry point always exists.
- **Write-scope humility.** The AI writes comments and opens PRs. It never moves cards, merges, closes, assigns, or deletes. Humans own the tool.

The tool-specific logic (layer 1) is the *recipe*; layers 2–6 are shared *adapters* the installer composes.

---

## 2. Layer 3 deep dive — execution runtime options

| Runtime | Trigger mechanism | Secrets store | Cost | Setup effort | Best for |
|---|---|---|---|---|---|
| **GitHub Actions** ✅ default | `repository_dispatch` (needs relay: webhooks can't send auth headers) + `workflow_dispatch` for manual reconcile | Repo secrets | Free tier generous; minutes billed at scale | Low | Teams already on GitHub; zero infra |
| **GitLab CI** | Pipeline **trigger tokens** accept the token in the URL query — many tools can webhook *straight into GitLab with no relay* (run reconcile mode); a thin relay adds per-item dispatch + event filtering | CI/CD variables | Free tier; minutes billed | Low-Med | GitLab-hosted repos; relay-less setups |
| **Bitbucket Pipelines** | Trigger via REST API (needs Bearer auth) → relay required; custom pipelines for manual runs | Repository variables | Minutes billed | Med | Atlassian shops (pairs naturally with Jira) |
| **Dedicated server / VPS (Docker)** | Built-in webhook receiver — the relay lives *in* the container; no third-party hop at all | `.env` / mounted secrets | Fixed ~$5-10/mo; no per-minute cost | Med | High volume, lowest latency, private repos, local AI models |
| **Self-hosted GitHub/GitLab runner** | Same as Actions/GitLab, jobs land on your hardware | Repo secrets | Free minutes, your hardware | Med | Big monorepos (warm caches), compliance |
| **Serverless containers** (Cloud Run jobs, Fly machines) | HTTP-triggered container start, scale-to-zero | Platform secrets | Pennies; pay-per-run | Med-High | High volume without a standing server |
| **Jenkins** | Generic webhook trigger plugin | Credentials store | Your hardware | High | On-prem enterprises (community-contributed) |

**Relay (layer 2) options**, needed wherever the tool's webhook can't authenticate to the runtime's trigger API:

- **Cloudflare Worker** ✅ default — free tier, ~50 lines, filters noise at the edge so CI minutes are only spent on events that produce work.
- **Vercel / Netlify function** — same idea for teams already there.
- **AWS Lambda + Function URL** — for AWS shops.
- **None** — GitLab trigger-token mode and the Docker-server runtime need no relay.
- **n8n / Pipedream / Zapier** — no-code bridge documented as an alternative for non-developers.

The relay's job is always identical (verify secret → filter to relevant events → forward `{item_id, kind}` to the runtime), so one relay codebase with per-runtime "forward" functions covers all of these.

---

## 3. Layer 4 deep dive — AI brain options

Two classes, one contract. An **agentic CLI** can explore the repo, edit code, and open PRs; a **raw API call** is cheaper/faster and right for playbooks that only read + write text (triage, summaries, replies).

| Brain | Headless invocation | Auth | Can edit repo? | Notes |
|---|---|---|---|---|
| **Claude Code** ✅ default | `claude -p --dangerously-skip-permissions --output-format stream-json` | `CLAUDE_CODE_OAUTH_TOKEN` (subscription, no API billing) or `ANTHROPIC_API_KEY` | ✅ | Reference implementation; best repo-aware agent; timestamped stream-JSON transcripts |
| **OpenAI Codex CLI** | `codex exec --full-auto "<prompt>"` | `OPENAI_API_KEY` or ChatGPT plan sign-in | ✅ | Near drop-in for the agentic role |
| **Gemini CLI** | `gemini -p "<prompt>" --yolo` | Google account (generous free tier) or `GEMINI_API_KEY` | ✅ | Cheapest way to trial the whole system |
| **Aider** | `aider --message "<prompt>" --yes` | Any: OpenAI, Anthropic, Gemini, **Ollama/local** | ✅ | Model-agnostic bridge; the path to fully-local code changes |
| **Raw Anthropic / OpenAI / Gemini API** | `core/ai/api-*.sh` harness (curl + jq, no CLI install) | API key | ❌ text-only | For analyze/respond/notify playbooks; fastest cold start, lowest cost |
| **Ollama (local models)** | via Aider or API harness against `localhost:11434` | none | via Aider | Docker-server runtime only; full data privacy |

**Adapter contract** (`core/ai/<brain>.sh`): each adapter implements `ai_check` (deps + auth present), `ai_run <prompt_file> <workdir> <transcript_out>`, and declares capabilities (`CAN_EDIT_REPO`, `HAS_TRANSCRIPT`). Recipes declare what they need (the `implement` playbook requires `CAN_EDIT_REPO`; `analyze`/`respond` don't), and the installer only offers compatible brains. Playbooks stay provider-neutral markdown — they're prompts, not code.

---

## 4. Layer 1 deep dive — tools cover ALL their events, not just boards

**Principle: a tool recipe attaches to every event stream the tool's webhooks
expose**, organized into *handler families* the user toggles at install time.
One relay + one dispatcher route each event to its family's playbook; disabled
families are filtered at the edge so they cost nothing.

Basecamp's full webhook surface (from the CLI: `basecamp webhooks create --help`)
→ six handler families:

| Handler | Event types | Interaction pattern |
|---|---|---|
| `cards` | `Kanban::Card` (+ comments) | Board flow: analyze column → discuss → implement column → PR |
| `todos` | `Todo`, `Todolist` (+ comments) | Discuss/answer; build explicitly requested changes as PRs |
| `messages` | `Message` (+ comments) | Answer when addressed; silent otherwise |
| `docs` | `Document`, `Upload`, `Vault` (+ comments) | Review specs/files against the real code when asked |
| `checkins` | `Question`, `Question::Answer` (+ comments) | Reply when directly asked |
| `schedule` | `Schedule::Entry` (+ comments) | Meeting prep on request |

The same full-coverage treatment maps onto the other tools:
**Jira** (`jira:issue_created/updated/deleted`, `comment_*`, `sprint_*`,
`version_*`, `worklog_*`), **ClickUp** (`task*`, `list*`, `folder*`, `space*`,
`goal*`, comments, time tracking), **Linear** (Issue, Comment, Project,
ProjectUpdate, Cycle, Document, Label), **Trello** (all board actions),
**Slack** (Events API: messages, reactions, channel events, mentions).

### Tool/event-source matrix

| Tool | Webhooks | Auth model | API for re-fetching truth | Recipe difficulty |
|---|---|---|---|---|
| **Basecamp** | Yes (`Kanban::Card`, `Comment`, …) | OAuth (official `basecamp` CLI) | ✅ CLI | ✅ Done (reference) |
| **Linear** | Yes, HMAC-signed | API key / OAuth | GraphQL, excellent | Easy — best API of the set |
| **Slack** | Events API (must ACK in 3s → relay mandatory) | Bot token + signing secret | Web API | Medium — different shape (channels, not boards) |
| **Jira** | Yes, JQL-filtered | API token / OAuth app | REST, verbose | Medium |
| **Trello** | Yes (creation requires HEAD-200 echo) | Key + token | REST, simple | Easy |
| **ClickUp** | Yes, HMAC-signed | API token | REST | Easy-Medium |
| **LINE** | Messaging API, HMAC-signed | Channel token | Messaging API | Easy (notify-style recipes, not board-style) |

The **project-agent pattern** (analyze column → discuss → implement column → PR) ports almost 1:1 to Linear, Jira, Trello, and ClickUp: same resolver logic, same playbooks, different API calls. Slack and LINE follow different interaction patterns (triage/notify) and get their own recipe shapes.

---

## 5. Layer 5/6 — state & audit options

- **State default: git orphan branch** (`<recipe>-state`, one JSON file per item: column/status, phase, last_comment_id, branch, pr_url). Works identically on every git-based runtime, inspectable, versioned, no database. Push with rebase-retry for concurrent runs.
- **Docker-server alternative:** same JSON files on a mounted volume (optionally still git-pushed for inspectability).
- **Audit:** every run persists prompt + full AI transcript + result JSON — as CI artifacts (Actions/GitLab/Bitbucket) or a rotating `runs/` directory (server).

---

## 6. Target repository layout

```
ai-automations/
├── setup.sh                        # picker: recipe → runtime → brain → questions
├── core/
│   ├── lib/wizard.sh               # ask/confirm/render helpers (bash 3.2-safe)
│   ├── lib/render.sh               # {{TOKEN}} template renderer
│   ├── ai/                         # brain adapters (one file each + contract doc)
│   │   ├── claude-code.sh  codex.sh  gemini-cli.sh  aider.sh
│   │   └── api-anthropic.sh  api-openai.sh  api-gemini.sh
│   ├── runtimes/                   # runtime adapters (templates + docs)
│   │   ├── github-actions/         # workflow.yml.tmpl, secrets mapping
│   │   ├── gitlab-ci/              # .gitlab-ci.yml.tmpl, trigger-token guide
│   │   ├── bitbucket/              # bitbucket-pipelines.yml.tmpl
│   │   └── docker-server/          # Dockerfile, compose.yml, webhook receiver
│   ├── relays/
│   │   ├── cloudflare-worker/      # one worker, per-runtime forwarders
│   │   ├── vercel/  lambda/
│   │   └── README.md               # incl. n8n/Pipedream no-code path
│   └── state/git-branch.sh         # restore/save (shared)
├── automations/
│   ├── basecamp/project-agent/       # recipe.json, README, setup.sh, playbooks/, scripts/
│   ├── linear/project-agent/         # (phase 4 — thin: API calls + column names differ)
│   ├── slack/triage-agent/  jira/  trello/  clickup/  line/
├── docs/
│   ├── PLAN.md                     # this file
│   ├── architecture.md             # the six layers, adapter contracts
│   └── choosing.md                 # runtime/brain decision guide (the §2–§3 tables)
├── README.md  CONTRIBUTING.md  LICENSE
```

**Config model:** the installer writes one non-secret `automation.config.json` into the target repo (tool IDs, runtime choice, brain choice, conventions: branch prefix, PR base, marker, audience). All credentials go only into the chosen runtime's secret store. Re-running the installer reads the existing config as defaults → safe upgrades/edits.

**Installer UX:**

```
./setup.sh
  1. Pick automation        → basecamp/project-agent
  2. Pick runtime           → GitHub Actions | GitLab | Bitbucket | Docker server
  3. Pick AI brain          → Claude Code | Codex | Gemini | Aider | raw API   (filtered by recipe needs)
  4. Tool questions         → account/project/board/column IDs (with "where to find this" help)
  5. Convention questions   → agent name, audience, branch prefix, PR base, QA command  (Enter-through defaults)
  6. Summary → confirm      → files rendered into your repo, secrets set via gh/glab/wrangler prompts
  7. Next steps printed     → relay deploy + webhook registration commands with YOUR values filled in
```

---

## 7. Phased roadmap

**Phase 1 — Working vertical slice (the proof)** · size M
Core wizard lib + `basecamp/project-agent` on **GitHub Actions + Claude Code** (port of the proven production design, fully parameterized — no hardcoded IDs). Root picker, recipe docs, dry-run mode, smoke-tested installer.
*Done when: a stranger clones the repo and gets a working Basecamp agent in ~15 minutes.*

**Phase 2 — Pluggable brains** · size M
`core/ai/` adapter contract + Codex CLI, Gemini CLI, Aider, and raw-API adapters. Capability gating (implement needs `CAN_EDIT_REPO`). Brain question added to the wizard; per-runtime auth-secret mapping.
*Done when: the same Basecamp recipe runs on all three CLIs by changing one answer.*

**Phase 3 — Pluggable runtimes** · size L
`core/runtimes/` + `core/relays/`: GitLab CI (incl. relay-less trigger-token mode), Docker-server (webhook receiver + compose, Ollama-ready), Bitbucket. State scripts already runtime-neutral.
*Done when: runtime is an installer question and each has a smoke-test doc.*

**Phase 4 — More tools** · size M per tool
Order: **Linear** (best API — validates that the project-agent core is truly reusable) → **Jira** → **Trello** → **ClickUp** → **Slack triage-agent** (new pattern) → **LINE notify**.
*Done when: each recipe passes the same 15-minute stranger test.*

Status: Linear is **built (beta — needs live-fire testing**; checklist in its
README). Jira, Trello, ClickUp, Slack, and LINE each have a full implementation
spec (event matrix, auth/verification mechanics, installer questions) in their
`automations/<tool>/<recipe>/README.md`. The candidate map for tools beyond
these seven lives in [tool-universe.md](tool-universe.md).

**Phase 5 — Public polish** · size S-M
`./setup.sh doctor` (validate an install: deps, secrets present, webhook reachable), CI for the repo itself (shellcheck + installer smoke tests in containers), issue templates, demo GIF/video, launch README.

Recommended default stack to advertise: **GitHub Actions + Cloudflare relay + Claude Code** (most-proven path), with GitLab/Gemini as the "completely free tier" alternative and Docker-server/Ollama as the "fully private" alternative.

---

## 8. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Agent CLIs drift (flags change, new majors) | Thin adapters, pinned install versions, CI smoke test per brain |
| Provider-neutral playbooks underperform on weaker models | Playbooks state *outcomes* not tool syntax; per-brain quality notes in docs; default = Claude Code |
| Guardrails enforced only by prompts | Hard limits live in scripts/config where possible: PR base branch, comment-only API scopes, no force-push; recommend branch protection on the target repo |
| Webhook security varies by tool | Per-tool ingress does proper verification (HMAC where offered, URL secret otherwise); documented per recipe |
| Secret sprawl across runtimes | One secrets-mapping table per runtime adapter; `doctor` checks presence, never values |
| Subscription-token ToS/rate limits for CI use | Both auth modes supported everywhere; docs state trade-offs (API key for scale, OAuth token for solo/small teams) |
| Scope creep (6 layers × 7 tools × 7 brains) | Strict phase gates; every layer combination must be reachable, not every combination pre-built/tested |
