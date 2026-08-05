# ai-automations

**Plug-and-play AI automations for the tools your team already uses.**

Clone the repo, run one command, answer a few questions — and you have a production-grade AI automation wired into your stack. No servers to run, no cron jobs to babysit, no databases to maintain.

```bash
git clone https://github.com/makasanakshay/ai-automations.git
cd ai-automations
./setup.sh
```

The installer lists every available automation, asks the recipe-specific questions (IDs, tokens, conventions), copies the ready-to-run files into **your** repository, and prints the few remaining manual steps (deploying a relay, registering a webhook) with your real values already filled in.

## Available automations

Recipes attach to **every event stream their tool exposes** — not just one
board — via toggleable per-event handlers you pick at install time.

| Recipe | Tool | What it does | Status |
|---|---|---|---|
| [`basecamp/project-agent`](automations/basecamp/project-agent) | Basecamp | Attaches to all Basecamp events via handlers: card board (analyze → discuss → PR), to-dos, messages, docs & files, check-ins, schedule. | ✅ Ready |
| `slack/triage-agent` | Slack | Triages a support/eng channel: labels, answers FAQs from the repo, escalates real bugs as issues. | 🔜 Planned |
| `jira/project-agent` | Jira | All Jira webhook events: issues, comments, sprints, versions, worklogs. | 🔜 Planned |
| `linear/project-agent` | Linear | All Linear webhook events: issues, comments, projects, cycles, docs. | 🔜 Planned |
| `trello/project-agent` | Trello | All Trello board actions: cards, lists, comments, attachments, members. | 🔜 Planned |
| `clickup/project-agent` | ClickUp | All ClickUp webhook events: tasks, lists, comments, goals, time tracking. | 🔜 Planned |
| `line/notify-agent` | LINE | Ship/deploy/incident notifications with AI-written summaries. | 🔜 Planned |

Want one of the planned recipes sooner — or a tool that isn't listed? [Open an issue](../../issues) or contribute it: the recipe contract in [CONTRIBUTING.md](CONTRIBUTING.md) makes new recipes straightforward.

## How it works

Every recipe follows the same shape:

```
automations/<tool>/<recipe>/
├── recipe.json     # name, description, requirements
├── README.md       # full docs for this automation
├── setup.sh        # interactive installer (the "plug")
└── files/          # battle-tested files copied into YOUR repo (the "play")
```

`./setup.sh` at the repo root is just a picker — each recipe's own `setup.sh` does the real work: ask questions with sensible defaults, show a summary, confirm, render the files into your target repository, optionally set your GitHub secrets via `gh`, and print the remaining manual steps with your values substituted in.

## Design principles

Every recipe in this repo follows these rules:

1. **Event-driven, not polling.** Webhooks wake the automation; free-tier relays (Cloudflare Workers) bridge to GitHub Actions. Zero idle cost, no servers to maintain.
2. **Webhooks are doorbells, not data.** Payloads only trigger a run — every run re-fetches the truth from the tool's API and diffs against saved state. Duplicate, stale, or missed events are harmless, and there's always a manual "reconcile" button.
3. **Humans stay in charge.** Agents write comments and open pull requests. They never move cards, merge PRs, close tickets, or delete anything. The board/tracker belongs to your team.
4. **State lives in git.** Per-item state is JSON on an orphan branch — no database, fully inspectable, versioned for free.
5. **Everything is auditable.** Every run uploads its prompt, full transcript, and result as a CI artifact.
6. **Plain-language output.** Comments are written for the stakeholders reading the tool, not for developers. Technical detail goes in the PR, not the card.
7. **Secrets stay secrets.** Installers never write tokens into files — credentials go into GitHub/Cloudflare secret stores only.

## Requirements

- macOS or Linux, `bash` and `git`
- [`jq`](https://jqlang.github.io/jq/) (`brew install jq` / `apt install jq`)
- [`gh`](https://cli.github.com/) — GitHub CLI, authenticated (recipes use GitHub Actions as the runtime)
- Per-recipe extras are listed in each recipe's README (e.g. the Basecamp CLI, `wrangler` for Cloudflare)
- An AI brain: a Claude subscription token (`claude setup-token`, no API billing) **or** an Anthropic API key

## Contributing

New recipes, hardening, and docs fixes are all welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for the recipe contract.

## License

[MIT](LICENSE)
