# Basecamp Board Agent

An event-driven AI teammate for a Basecamp card table. Move a card into your
"figuring out" column and it posts an analysis (options, trade-offs, a
recommendation) or clarifying questions. Discuss with it in the card's
comments. Move the card to "in progress" and it implements the agreed change
and opens a ready-for-review pull request. It never moves cards and never
merges — your team stays in charge of the board.

Generalized from an agent running a real production board; the design has
survived real webhook storms, agent-echo loops, and CI-minute bills.

```
Basecamp webhook (Kanban::Card + Comment)
  → Cloudflare Worker relay             files/scripts/basecamp-agent/relay/worker.js
  → repository_dispatch                 files/.github/workflows/basecamp-agent.yml
  → agent-run.sh                        restore state → resolve → playbook → save state
       → resolve-card.sh                diff Basecamp vs saved state → analyze|respond|implement|skip
       → run-playbook.sh                headless AI runs playbooks/<name>.md via ai/brain.sh
```

| Trigger | Playbook | Output (one Basecamp comment) |
|---|---|---|
| Card enters the **analyze** column | `analyze` | Options + trade-offs + recommendation, or numbered questions |
| Human comment on an analyze-column card | `respond` | Answer / updated proposal / remaining questions |
| Card enters the **implement** column (or comment there) | `implement` | PR link — or questions if unclear |

## Install

```bash
./setup.sh basecamp/board-agent
```

The wizard asks for (Enter accepts the defaults):

- **Target repo** — the repository the agent works in; files land in `scripts/basecamp-agent/` + one workflow.
- **Basecamp IDs** — account, project, card table, and the two watched column IDs (the wizard shows you exactly where in the Basecamp URL each one lives).
- **Conventions** — agent display name, product name, board audience, branch prefix, PR base branch, an optional quick-QA command, and the Claude model.

Re-running the wizard later reads your previous answers from
`scripts/basecamp-agent/automation.config.json` as defaults — safe for upgrades
and edits.

After the files are installed, the wizard offers to set your GitHub secrets via
`gh` and prints the remaining steps (deploy the relay with `wrangler`, register
the webhook) as copy-pasteable commands with your real values filled in.

## How it stays sane (design notes)

- **Webhooks are doorbells.** Every run re-fetches the card + comments from Basecamp and diffs against saved state to decide what to do — duplicate, stale, or missed events are harmless. A manual *Run workflow* button reconciles everything.
- **State is git.** Per-card JSON (`column, phase, last_comment_id, branch, pr_url`) on the orphan branch `basecamp-agent-state`. No database.
- **Loop protection.** Agent comments start with a marker (`🤖 <name>`); the relay drops the echo at the edge and the resolver skips marker comments before any AI call.
- **Cost control.** The relay only dispatches events that can produce work: moves into the two watched columns and non-agent comments. Known blind spot: silently moving a card back into a watched column isn't dispatched — re-trigger with a comment or the manual button.
- **Audit trail.** Every run uploads its prompt, full timestamped AI transcript, and result JSON as a workflow artifact.

## Guardrails

- Basecamp writes are **comments only** — never moves, completes, assigns, archives, or deletes.
- PRs always target your chosen base branch, from `<prefix>/<slug>` branches; the agent never merges and never pushes to the base branch directly.
- `--dangerously-skip-permissions` runs only inside the disposable CI runner. Local runs are `DRY_RUN=1` and stop before any AI call:

```bash
DRY_RUN=1 bash scripts/basecamp-agent/agent-run.sh                # reconcile scan
DRY_RUN=1 CARD_ID=<id> bash scripts/basecamp-agent/agent-run.sh  # one card
```

Operating docs (recovery, pausing, transcripts) are installed into your repo at
`scripts/basecamp-agent/README.md`.
