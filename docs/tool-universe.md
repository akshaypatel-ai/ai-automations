# Tool universe — where these agents can live next

The candidate map beyond the first seven tools. Criteria: does the tool have
**webhooks** (event-driven, our architecture's requirement), a **write API**
for comments/replies, and a real team audience? ✦ marks the strongest
near-term candidates.

## Project & task management (the project-agent pattern ports directly)

| Tool | Webhooks | Notes |
|---|---|---|
| ✦ Asana | Yes (X-Hook-Secret handshake, HMAC) | Huge install base; tasks/sections map to the board flow |
| ✦ Monday.com | Yes | GraphQL API; status-column flow |
| ✦ Notion | Yes (webhooks, 2024+) | Databases as boards; comments API |
| ✦ GitHub Issues/Projects | Native Actions triggers — **no relay needed** | The cheapest recipe to build; huge audience |
| GitLab Issues/Boards | Native CI triggers | Pairs with the GitLab runtime (Phase 3) |
| Shortcut (ex-Clubhouse) | Yes | Story workflow states |
| Height | Yes | API-first, Linear-like |
| Todoist | Yes | Personal/small-team tasks |
| Wrike, Teamwork, Zoho Projects | Yes | Enterprise long tail |
| Airtable | Yes | Bases as boards; strong automation audience |
| Azure DevOps (Boards) | Yes (service hooks) | Enterprise; pairs with Pipelines runtime |

## Chat & messaging (triage/notify patterns)

| Tool | Webhooks | Notes |
|---|---|---|
| ✦ Discord | Yes (interactions + gateway; outbound webhooks trivial) | Dev-community heavy; bot Q&A + ship notifications |
| ✦ Microsoft Teams | Yes (Graph subscriptions / outgoing webhooks) | Enterprise Slack twin |
| Telegram | Yes (bot API, dead simple) | Notify + Q&A bots |
| WhatsApp Business | Yes (Cloud API) | Notify to founders/clients |
| Google Chat | Yes | Workspace shops |
| Mattermost / Rocket.Chat | Yes | Self-hosted Slack twins — pairs with Docker-server runtime |

## Support & CRM (triage pattern: answer, escalate, summarize)

| Tool | Webhooks | Notes |
|---|---|---|
| ✦ Zendesk | Yes | Ticket triage: draft grounded replies, escalate bugs to the tracker |
| ✦ Intercom | Yes | Same shape, product-led companies |
| Freshdesk / Help Scout / Front | Yes | Same shape |
| HubSpot | Yes | CRM events → AI summaries/notify |
| Linear Asks / Plain | Yes | Support-in-tracker hybrids |

## Docs & knowledge (review-on-request pattern)

| Tool | Webhooks | Notes |
|---|---|---|
| Confluence | Yes | Spec-vs-code review, like the Basecamp `docs` handler |
| Google Drive/Docs | Yes (Drive API push) | Watch a specs folder |
| Figma | Yes (file/comment events) | Design-comment Q&A; dev-handoff checks |
| Miro | Yes | Board comments |

## Dev infrastructure (notify/report patterns, mostly relay-free)

| Tool | Trigger | Notes |
|---|---|---|
| ✦ Sentry | Yes (issue alerts) | Error → AI root-cause sketch → tracker issue with repro |
| PagerDuty / Opsgenie | Yes | Incident summaries to chat |
| CircleCI / Buildkite / Jenkins | Yes | Failure triage: AI reads the log, comments the likely cause |
| Vercel / Netlify / Railway | Yes (deploy hooks) | Deploy notes to chat |

## How to add one

Every candidate follows the same six-layer decomposition — write the
event-matrix design doc first (copy the shape of `automations/jira/project-agent/README.md`),
then port the closest reference implementation (Basecamp for column/board
tools, Linear for state/GraphQL tools, the Slack design for chat tools).
The recipe contract is in [CONTRIBUTING.md](../CONTRIBUTING.md).
