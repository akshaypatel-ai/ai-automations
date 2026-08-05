# Tool universe — where these agents can live next

The candidate map beyond the built recipes. Criteria: does the tool have
**webhooks** (event-driven, our architecture's requirement), a **write API**
for comments/replies, and a real team audience? ✅ marks tools that now have
a recipe in `automations/`; ✦ marks the strongest remaining candidates.

## Project & task management (the project-agent pattern ports directly)

| Tool | Webhooks | Notes |
|---|---|---|
| ✅ Asana | Yes (X-Hook-Secret handshake, HMAC) | **Built**: [`asana/project-agent`](../automations/asana/project-agent) |
| ✅ Monday.com | Yes | **Built**: [`monday/project-agent`](../automations/monday/project-agent) |
| ✅ Notion | Yes (webhooks, 2024+) | **Built**: [`notion/project-agent`](../automations/notion/project-agent) |
| ✅ GitHub Issues | Native Actions triggers — **no relay needed** | **Built**: [`github/issues-agent`](../automations/github/issues-agent) |
| ✅ GitLab Issues | Yes (project webhooks, X-Gitlab-Token) | **Built**: [`gitlab/issues-agent`](../automations/gitlab/issues-agent) |
| ✅ Shortcut | Yes (Payload-Signature HMAC) | **Built**: [`shortcut/project-agent`](../automations/shortcut/project-agent) |
| Height | Yes | API-first, Linear-like |
| Todoist | Yes | Personal/small-team tasks |
| Wrike, Teamwork, Zoho Projects | Yes | Enterprise long tail |
| ✅ Airtable | Yes (thin-ping webhooks, MAC) | **Built**: [`airtable/project-agent`](../automations/airtable/project-agent) |
| Azure DevOps (Boards) | Yes (service hooks) | Enterprise; pairs with Pipelines runtime |

## Chat & messaging (triage/notify patterns)

| Tool | Webhooks | Notes |
|---|---|---|
| ✅ Discord | Yes (interactions + outbound webhooks) | **Built**: [`discord/notify-agent`](../automations/discord/notify-agent) |
| ✅ Microsoft Teams | Yes (outgoing + incoming webhooks) | **Built**: [`teams/notify-agent`](../automations/teams/notify-agent) |
| ✅ Telegram | Yes (bot API, dead simple) | **Built**: [`telegram/notify-agent`](../automations/telegram/notify-agent) |
| WhatsApp Business | Yes (Cloud API) | Notify to founders/clients |
| ✅ Google Chat | Space webhooks (outbound) | **Built**: [`googlechat/notify-agent`](../automations/googlechat/notify-agent) — inbound Q&A would need a Chat app |
| Mattermost / Rocket.Chat | Yes | Self-hosted Slack twins — pairs with Docker-server runtime |

## Support & CRM (triage pattern: answer, escalate, summarize)

| Tool | Webhooks | Notes |
|---|---|---|
| ✅ Zendesk | Yes (signed webhooks + triggers) | **Built**: [`zendesk/triage-agent`](../automations/zendesk/triage-agent) |
| ✅ Intercom | Yes (X-Hub-Signature) | **Built**: [`intercom/triage-agent`](../automations/intercom/triage-agent) |
| Freshdesk / Help Scout / Front | Yes | Same shape |
| HubSpot | Yes | CRM events → AI summaries/notify |
| Linear Asks / Plain | Yes | Support-in-tracker hybrids |

## Docs & knowledge (review-on-request pattern)

| Tool | Webhooks | Notes |
|---|---|---|
| ✅ Confluence | Automation rules → web request (no Cloud admin webhooks) | **Built**: [`confluence/docs-agent`](../automations/confluence/docs-agent) |
| Google Drive/Docs | Yes (Drive API push) | Watch a specs folder |
| ✅ Figma | Yes (v2 webhooks, passcode) | **Built**: [`figma/design-agent`](../automations/figma/design-agent) |
| Miro | Yes | Board comments |

## Dev infrastructure (notify/report patterns, mostly relay-free)

| Tool | Trigger | Notes |
|---|---|---|
| ✅ Sentry | Yes (internal-integration webhooks) | **Built**: [`sentry/triage-agent`](../automations/sentry/triage-agent) |
| ✅ PagerDuty | Yes (v3 webhooks, signed) | **Built**: [`pagerduty/triage-agent`](../automations/pagerduty/triage-agent) |
| Opsgenie | Yes | Incident summaries to chat |
| CircleCI / Buildkite / Jenkins | Yes | Failure triage: AI reads the log, comments the likely cause |
| Vercel / Netlify / Railway | Yes (deploy hooks) | Deploy notes to chat |

## How to add one

Every candidate follows the same six-layer decomposition — write the
event-matrix design doc first (copy the shape of `automations/jira/project-agent/README.md`),
then port the closest reference implementation (Basecamp for column/board
tools, Linear for state/GraphQL tools, the Slack design for chat tools).
The recipe contract is in [CONTRIBUTING.md](../CONTRIBUTING.md).
