# Architecture

Every automation decomposes into six pluggable layers (full analysis and
options matrices: [PLAN.md](PLAN.md)):

```
TOOL → RELAY → RUNTIME → BRAIN → STATE → AUDIT
```

| Layer | What it is | Phase 1 implementation |
|---|---|---|
| **Tool** | The event source + API of record (Basecamp, Jira, Linear, …) | `automations/basecamp/board-agent/` |
| **Relay** | Webhook ingress: verify → filter → forward to the runtime trigger | Cloudflare Worker (in the recipe); contract in `core/relays/` |
| **Runtime** | Where runs execute | GitHub Actions; contract in `core/runtimes/github-actions/` |
| **Brain** | The AI: agentic CLI or raw API | `core/ai/claude-code.sh`; contract in `core/ai/README.md` |
| **State** | Per-item memory between runs | `core/state/git-branch.sh` (orphan branch, JSON per item) |
| **Audit** | Prompt + transcript + result of every run | CI artifacts (`.agent-out/`) |

## Invariants (every recipe, every layer combination)

1. **Doorbell pattern** — webhook payloads only wake the automation; each run re-fetches truth from the tool's API and diffs against saved state. Duplicates and missed events are harmless; a manual reconcile entry point always exists.
2. **Write-scope humility** — the AI writes comments and opens PRs; it never moves, merges, closes, assigns, or deletes in the user's tool.

## How an install composes the layers

A recipe's `setup.sh` collects answers (with the previous install's
`automation.config.json` as defaults), renders `files/**/*.tmpl` through
`core/lib/render.sh` ({{TOKEN}} substitution), copies the chosen core adapters
into the target repo (`state.sh`, `ai/brain.sh`), and prints the remaining
manual wiring (secrets, relay deploy, webhook registration) with real values
substituted. The result in the target repo is self-contained — it does not
depend on this repository at runtime.
