# ai-automations

**Plug-and-play AI automations for the tools your team already uses.**

Clone the repo, run one command, answer a few questions — and you have a production-grade AI automation wired into your stack. No servers to run, no cron jobs to babysit, no databases to maintain.

```bash
git clone https://github.com/akshaypatel-ai/ai-automations.git
cd ai-automations
./setup.sh
```

The installer lists every available automation, asks the recipe-specific questions (IDs, tokens, conventions), copies the ready-to-run files into **your** repository, and prints the few remaining manual steps (deploying a relay, registering a webhook) with your real values already filled in.

## Available automations

Recipes attach to **every event stream their tool exposes** — not just one
board — via toggleable per-event handlers you pick at install time.

| Recipe | Tool | What it does |
|---|---|---|
| [`basecamp/project-agent`](automations/basecamp/project-agent) | Basecamp | Attaches to all Basecamp events via handlers: card board (analyze → discuss → PR), to-dos, messages, docs & files, check-ins, schedule. |
| [`jira/project-agent`](automations/jira/project-agent) | Jira | Board flow via status transitions; relay routes all Jira webhook events (issues, comments, sprints, versions, worklogs). |
| [`slack/triage-agent`](automations/slack/triage-agent) | Slack | Answers mentions/DMs from the repo, triages channels, escalates bugs as issues; signed Events API relay with 3s ack. |
| [`linear/project-agent`](automations/linear/project-agent) | Linear | Board flow via workflow states (analyze → discuss → PR), HMAC-verified webhooks, GraphQL; relay routes all resource types. |
| [`trello/project-agent`](automations/trello/project-agent) | Trello | Board flow via list moves; HEAD-handshake relay routes all board actions. |
| [`clickup/project-agent`](automations/clickup/project-agent) | ClickUp | Board flow via status changes; HMAC-verified relay routes all webhook events. |
| [`line/notify-agent`](automations/line/notify-agent) | LINE | AI-written ship/incident notifications (GitHub-native triggers, no relay) + group Q&A. |
| [`github/issues-agent`](automations/github/issues-agent) | GitHub Issues | Label-driven board flow (analyze → discuss → PR) — the relay-free recipe: native Actions triggers, no webhook, no extra token. |
| [`asana/project-agent`](automations/asana/project-agent) | Asana | Board flow via sections; relay handles the X-Hook-Secret handshake + HMAC and routes all webhook events. |
| [`monday/project-agent`](automations/monday/project-agent) | Monday.com | Board flow via a status column over GraphQL; challenge-echo relay routes all board events. |
| [`notion/project-agent`](automations/notion/project-agent) | Notion | Board flow on a database's status property; signature-verified relay routes all webhook events. |
| [`discord/notify-agent`](automations/discord/notify-agent) | Discord | AI-written ship/incident notifications (channel webhook, no relay) + `/ask` slash command via Ed25519-verified interactions. |
| [`teams/notify-agent`](automations/teams/notify-agent) | Microsoft Teams | AI-written ship/incident notifications (channel webhook, no relay) + @mention Q&A via signed outgoing webhook. |
| [`telegram/notify-agent`](automations/telegram/notify-agent) | Telegram | AI-written ship/incident notifications (Bot API, no relay) + chat Q&A via secret-token-verified webhook. |
| [`airtable/project-agent`](automations/airtable/project-agent) | Airtable | Board flow via a single-select status field; MAC-verified thin-ping webhooks collapse into doorbell reconciles. |
| [`gitlab/issues-agent`](automations/gitlab/issues-agent) | GitLab Issues | Label-driven board flow (labels are GitLab's native columns); X-Gitlab-Token relay routes issue + note events. |
| [`confluence/docs-agent`](automations/confluence/docs-agent) | Confluence | Label a page → spec-vs-code review comment grounded in the repo; Automation-rule doorbells (or the manual button). |
| [`figma/design-agent`](automations/figma/design-agent) | Figma | Comment `@ai …` on a design → repo-grounded answer in the thread (is it built? what does the code do?); passcode-verified webhooks. |
| [`pagerduty/triage-agent`](automations/pagerduty/triage-agent) | PagerDuty | Incident fires → repo-grounded triage note on the incident (what/impact/likely cause/where to look); v3 signed webhooks. |
| [`googlechat/notify-agent`](automations/googlechat/notify-agent) | Google Chat | AI-written ship/incident notifications to a space webhook — zero relay, nothing to deploy. |
| [`shortcut/project-agent`](automations/shortcut/project-agent) | Shortcut | Board flow via workflow states (analyze → discuss → PR); signed batched webhooks deduped at the edge. |
| [`todoist/project-agent`](automations/todoist/project-agent) | Todoist | Board flow via sections (analyze → discuss → PR); base64-HMAC app webhooks. |
| [`freshdesk/triage-agent`](automations/freshdesk/triage-agent) | Freshdesk | Ticket triage: grounded draft replies as private notes (humans send), bugs escalated as GitHub issues. |
| [`helpscout/triage-agent`](automations/helpscout/triage-agent) | Help Scout | Conversation triage: grounded draft replies as internal notes (humans send), bugs escalated as GitHub issues. |
| [`vercel/deploy-agent`](automations/vercel/deploy-agent) | Vercel | Failed deploys become repo-grounded triage issues (log excerpt + likely cause); same-sha recurrences comment instead of duplicating. |
| [`front/triage-agent`](automations/front/triage-agent) | Front | Conversation triage: grounded draft replies as internal comments (humans send), bugs escalated as GitHub issues. |
| [`miro/board-agent`](automations/miro/board-agent) | Miro | Sticky-note summon: write `@ai …` on the board → a repo-grounded answer sticky appears beside it. |
| [`mattermost/notify-agent`](automations/mattermost/notify-agent) | Mattermost | AI-written ship/incident notifications (incoming webhook, no relay) + trigger-word Q&A via outgoing webhook. |
| [`azuredevops/project-agent`](automations/azuredevops/project-agent) | Azure DevOps | Board flow via work-item states (analyze → discuss → PR); service-hook webhooks, WIQL reconcile. |
| [`netlify/deploy-agent`](automations/netlify/deploy-agent) | Netlify | Failed deploys become repo-grounded triage issues (JWS-verified notifications); same-sha recurrences comment instead of duplicating. |
| [`rocketchat/notify-agent`](automations/rocketchat/notify-agent) | Rocket.Chat | AI-written ship/incident notifications (incoming webhook, no relay) + trigger-word Q&A via outgoing webhook. |
| [`buildkite/build-agent`](automations/buildkite/build-agent) | Buildkite | Failed builds become repo-grounded triage issues (ANSI-stripped log tail + likely cause); same-sha recurrences comment instead of duplicating. |
| [`zendesk/triage-agent`](automations/zendesk/triage-agent) | Zendesk | Ticket triage: grounded draft replies as internal notes (humans send), bugs escalated as GitHub issues. |
| [`intercom/triage-agent`](automations/intercom/triage-agent) | Intercom | Conversation triage: grounded draft replies as internal notes, bugs escalated as GitHub issues. |
| [`sentry/triage-agent`](automations/sentry/triage-agent) | Sentry | Error alerts become root-cause sketches filed as GitHub issues; recurrences update the same issue. |

Each recipe README says how battle-tested it is and carries its own live-fire checklist. Beyond these thirty-five, [docs/tool-universe.md](docs/tool-universe.md) maps 20+ more candidate tools (Height, Wrike, …) with their webhook capabilities.

Want a recipe sooner — or a tool that isn't listed? [Open an issue](../../issues) or contribute it: the recipe contract in [CONTRIBUTING.md](CONTRIBUTING.md) makes new recipes straightforward.

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

1. **Event-driven, not polling.** Webhooks wake the automation; free-tier relays (Cloudflare Workers) bridge to GitHub Actions. Zero idle cost, no servers to maintain — or run everything on your own box with the [Docker-server runtime](core/runtimes/docker-server) (flat cost, Ollama-ready), or relay-less on [GitLab CI](core/runtimes/gitlab-ci).
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
