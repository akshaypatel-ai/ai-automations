# Azure DevOps Project Agent

The board-agent flow on Azure DevOps Boards: a work item enters your
**analyze** state (e.g. New) → the agent posts an analysis (options,
trade-offs, recommendation) or clarifying questions; discuss in the work
item's comments; move it to your **implement** state (e.g. Active) → it builds
the agreed change and opens a ready-for-review GitHub PR titled
`[AB-<id>] <title>` with the work item URL in the body. It never changes work
item states and never merges — humans own the board.

Status: **beta** — a faithful port of the production-proven Basecamp/Linear
flow to Azure DevOps' REST API; needs live-fire testing against a real
organization.

## Event coverage (relay routes the work-item service-hook surface)

| Handler | Azure DevOps service-hook events | Status |
|---|---|---|
| `workitems` | `workitem.created`, `workitem.updated` (State field filter), `workitem.commented` | ✅ implemented (analyze / respond / implement playbooks) |

## Azure DevOps-specific mechanics

- **Auth**: a Personal Access Token via basic auth with an empty username (`-u ":$AZDO_PAT"`; scope Work Items Read & Write).
- **api-version pinning**: every REST call needs one — `api.sh` appends `api-version=7.1` unless the caller pins their own; the comments endpoints are still a preview API and pin `7.1-preview.4` explicitly. `api.sh` is project-scoped; a `//`-prefixed path escapes to the org-level `/_apis` (used by the CI auth check).
- **Service hooks are unsigned** → authentication is the secret-in-URL pattern (Jira precedent); the subscription form's optional Basic-auth fields are extra hardening on top if you want them.
- **Edge noise filtering**: "Work item updated" fires on every field edit — the subscription's server-side State field filter drops non-state edits, and the relay keeps the same check (fail-open when the changed-fields map is absent). Per-event id quirk: created/commented carry `resource.id`, updated carries `resource.workItemId`.
- **Comments are HTML both ways**: the comment helper takes plain text and converts (escape `& < >`, `<p>` per line); the resolver strips tags before the agent-marker check.
- **Comment recency**: numeric increasing comment ids — tracked like Basecamp's.
- **Reconcile**: WIQL (`POST /wit/wiql`) per watched state — single quotes in state names are doubled (WIQL escaping; states with apostrophes are rare but handled) — plus every tracked state file.
- **Done detection**: `Removed` is skipped explicitly; anything not in a watched state simply produces no decision.

## Install

```bash
./setup.sh azuredevops/project-agent
```

Asks for: target repo, organization, project name, the two state names, and
the standard conventions. Secrets: `AZDO_PAT`, Claude auth (+ optional
`AGENT_GH_PAT`); relay secrets: `GITHUB_PAT`, `WEBHOOK_SECRET`. The installer
prints the three service-hook subscriptions to create (Project settings →
Service hooks → Web Hooks). Re-running reads
`scripts/azdo-agent/automation.config.json` as defaults.

## Guardrails

Comments only (never state/field/assignment changes), PRs only against your
chosen base from `<prefix>/ab-<id>-<slug>` branches, never merges,
`--dangerously-skip-permissions` only in the disposable CI runner, `DRY_RUN=1`
local testing, full transcript artifacts per run.

## Beta → stable checklist (live-fire against a real organization)

- [ ] URL-secret round-trip through the relay (create a work item in the watched state)
- [ ] analyze → respond → implement round-trip on a real project
- [ ] WIQL reconcile against a custom process template's state names
- [ ] Comments preview API (`7.1-preview.4`) stability / GA migration
- [ ] "Work item updated" State field filter behavior (server-side vs the relay's edge check)
