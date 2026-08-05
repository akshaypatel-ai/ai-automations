# Confluence Docs Agent

Review-on-request for docs: put the review label (default `ai-review`) on a
Confluence page → the agent reads the page, compares the spec against what
the code in this repository actually does, and posts ONE **footer comment** —
what's aligned, what's missing, what contradicts the code, plus numbered
questions. New human comments on a tracked page get ONE grounded reply — or
silence when they aren't addressed to the agent. Comments only: it never
edits pages and never changes labels.

Status: **beta** — promotes the Basecamp recipe's docs handler to its own
recipe on Confluence's Automation-rule doorbell; needs live-fire testing
against a real Confluence site.

## Event coverage (relay routes whatever your Automation rules send)

| Handler | Fed by | Status |
|---|---|---|
| `pages` | Automation rules "Label added" + "Comment added" (JSON bodies below) | ✅ implemented (review / respond playbooks) |
| anything else | any other rule/event pointed at the relay | Routed, skips cleanly (no `page_id` → ignored at the edge) |

## Confluence-specific mechanics

- **No admin-configurable webhooks on Cloud** — webhooks are a Connect/Forge app feature. The doorbell here is **Confluence Automation** (Premium+ plans): rules "Label added [`ai-review`]" and "Comment added" → action "Send web request" → the relay URL, with the literal body `{"page_id": "{{page.id}}", "event": "label-added" | "comment-added"}`. On Standard plans without Automation, nothing is lost — label pages, then press Actions → *Run workflow* (or curl the dispatch): the doorbell pattern doesn't care how it's rung.
- **URL-secret relay**: Automation web requests carry no portable HMAC, so authentication is the secret embedded in the URL path (`/hook/<WEBHOOK_SECRET>`) — same model as the monday recipe.
- **v2 reads + one v1 CQL search**: pages, labels, and footer comments are read via REST v2; the reconcile scan finds labeled pages through the documented v1 endpoint `GET /rest/api/content/search?cql=label="ai-review" and type=page` (v2 can't filter pages by label *name* without resolving the label id first).
- **Storage-format XHTML**: page and comment bodies are storage-format XHTML. Playbooks write PLAIN TEXT — `comment.sh` escapes `& < >` and wraps each line in `<p>…</p>` before POSTing.
- **Comment recency**: a footer comment's `version.createdAt` (ISO-8601, so plain string comparison orders correctly); the agent's own comments are marker-prefixed and tag-stripped before the check.

## Install

```bash
./setup.sh confluence/docs-agent
```

Asks for: target repo, Confluence site, review label, and the standard
conventions. Secrets: `CONFLUENCE_EMAIL`, `CONFLUENCE_API_TOKEN` (an
id.atlassian.com API token — the same type Jira uses), Claude auth; relay:
`GITHUB_PAT`, `WEBHOOK_SECRET`. The installer prints the exact Automation
rules whose JSON bodies define the payload — and the Standard-plan manual
path for sites without Automation.

## Guardrails

Footer comments only — the agent never edits pages and never adds or removes
labels, at most one comment per run, silence when a thread isn't addressed to
it, no PRs and no issues (workflow permissions: `contents: write` for the
state branch, nothing else), `--dangerously-skip-permissions` only in the
disposable CI runner, `DRY_RUN=1` local testing, full transcript artifacts
per run.

## Beta → stable checklist (live-fire against a real Confluence site)

- [ ] Automation rule round-trip: label added → web request → relay → workflow run
- [ ] review → respond round-trip on a test page
- [ ] Standard-plan manual path: label a page, run the workflow with empty `item_id`, get the review
- [ ] XHTML escaping fidelity: a comment containing `& < >` and code-ish text renders correctly
- [ ] CQL reconcile with a spaced label (URL-encoding through `jq @uri` holds up)
