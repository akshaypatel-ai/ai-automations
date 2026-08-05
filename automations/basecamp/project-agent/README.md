# Basecamp Project Agent

An event-driven AI teammate for a **whole Basecamp project** — not just the
card board. It attaches to every webhook-able Basecamp event stream through
toggleable handlers; you enable exactly the ones you want at install time:

| Handler | Basecamp events | What the agent does |
|---|---|---|
| `cards` | `Kanban::Card` + comments | The full board flow: card enters your analyze column → options/trade-offs/recommendation (or questions); discuss in comments; card enters your implement column → builds it and opens a ready-for-review PR |
| `todos` | `Todo`, `Todolist` + comments | Answers/discusses to-dos that concern the product; builds explicitly requested changes as PRs. Optional: scope to one to-do list |
| `messages` | `Message` + comments | Answers message-board questions addressed to the agent, grounded in the real code — silent otherwise |
| `docs` | `Document`, `Upload`, `Vault` + comments | Reviews specs/uploads against actual app behavior when asked — silent otherwise |
| `checkins` | `Question`, `Question::Answer` + comments | Replies when a check-in answer directly asks the agent something — silent otherwise |
| `schedule` | `Schedule::Entry` + comments | Meeting-prep notes / answers when an event asks for them — silent otherwise |

The webhook subscribes only to the event types your enabled handlers need, and
the relay drops everything that can't produce work — so CI minutes are spent
only when there's something to do. Default handlers: `cards,todos,messages`
(the chattier streams `docs`, `checkins`, `schedule` are opt-in).

Generalized from an agent running a real production board; the design has
survived real webhook storms, agent-echo loops, and CI-minute bills.

```
Basecamp webhook (all types your handlers need)
  → Cloudflare Worker relay             files/scripts/basecamp-agent/relay/worker.js
  → repository_dispatch                 files/.github/workflows/basecamp-agent.yml
  → agent-run.sh                        restore state → resolve → playbook → save state
       → resolve-item.sh                route by type + diff Basecamp vs saved state
       → run-playbook.sh                headless AI runs playbooks/<name>.md via ai/brain.sh
```

Playbooks per decision: `analyze` / `respond` / `implement` (cards), `todo`,
`message`, `doc`, `checkin`, `schedule`. Every non-board playbook carries the
same first rule: **if the new activity isn't addressed to the agent, post
nothing** — the agent stays silent in human-to-human conversation.

## Install

```bash
./setup.sh basecamp/project-agent
```

The wizard asks for (Enter accepts the defaults):

- **Target repo** — files land in `scripts/basecamp-agent/` + one workflow.
- **Handlers** — which event streams to enable.
- **Basecamp IDs** — account + project, then only what your handlers need (card table/columns for `cards`, optional to-do list for `todos`); the wizard shows where each ID lives in the Basecamp URL.
- **Conventions** — agent name, product name, audience, branch prefix, PR base branch, optional quick-QA command, Claude model.

Re-running the wizard reads `scripts/basecamp-agent/automation.config.json` as
defaults — use it to change handlers or settings anytime. The final output is a
copy-pasteable checklist (secrets, relay deploy, webhook registration) with your
real values — including the exact `--types` list — filled in.

## How it stays sane (design notes)

- **Webhooks are doorbells.** Every run re-fetches the item + comments and diffs against saved state — duplicate, stale, or missed events are harmless. Manual *Run workflow* reconciles watched columns/to-do lists and every tracked item (or one item by ID).
- **State is git.** Per-item JSON (`item_type, phase, last_comment_id, branch, pr_url`) on the orphan branch `basecamp-agent-state`. No database.
- **Loop protection.** Agent comments start with a marker (`🤖 <name>`); the relay drops the echo at the edge and the resolver skips marker comments before any AI call.
- **Silence by default off the board.** The board's columns are explicit human signals; everywhere else the playbooks reply only when addressed and never write code unless a human explicitly asked for a build (and message/doc/check-in/schedule threads redirect build requests to a card or to-do).
- **Audit trail.** Every run uploads its prompt, full timestamped AI transcript, and result JSON as a workflow artifact.

## Guardrails

- Basecamp writes are **comments only** — never moves cards, never completes to-dos, never edits/archives/deletes anything.
- PRs always target your chosen base branch from `<prefix>/<slug>` branches; the agent never merges and never pushes to the base branch directly.
- `--dangerously-skip-permissions` runs only inside the disposable CI runner. Local runs are `DRY_RUN=1` and stop before any AI call:

```bash
DRY_RUN=1 bash scripts/basecamp-agent/agent-run.sh                             # reconcile scan
DRY_RUN=1 ITEM_ID=<id> bash scripts/basecamp-agent/agent-run.sh               # one item
DRY_RUN=1 ITEM_ID=<id> ITEM_TYPE=Todo bash scripts/basecamp-agent/agent-run.sh
```

Operating docs (recovery, pausing, transcripts) are installed into your repo at
`scripts/basecamp-agent/README.md`.
