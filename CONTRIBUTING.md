# Contributing

New recipes are the most valuable contribution. The bar: someone who has never seen your automation should get it running by answering your installer's questions — nothing more.

## The recipe contract

A recipe lives at `automations/<tool>/<recipe-id>/` and must contain:

```
recipe.json     # metadata (schema below)
README.md       # what it does, architecture, what setup asks, manual steps, guardrails
setup.sh        # interactive installer
files/          # everything that gets copied into the user's repository
```

### recipe.json

```json
{
  "name": "Basecamp Board Agent",
  "description": "One sentence a stranger understands.",
  "tool": "basecamp",
  "status": "stable",
  "requires": ["git", "jq", "gh", "basecamp CLI", "wrangler", "Claude Code"]
}
```

`status` is `stable`, `beta`, or `experimental`. The root `./setup.sh` discovers recipes by scanning for `recipe.json`, so a valid manifest is all it takes to appear in the picker.

### setup.sh rules

- **Interactive with defaults.** Every question has a sensible default where one exists; pressing Enter through the wizard should produce a working config for the common case.
- **Explain where answers come from.** If a question needs an ID or token, print how to find it (URL patterns, CLI commands) right above the prompt.
- **Summary + confirm before writing.** Show everything collected, ask once, then act.
- **Idempotent.** Running the installer again over the same target must be safe (it may overwrite the files it owns, never anything else).
- **Render, don't fork.** Keep files in `files/` generic; use `{{TOKENS}}` in `*.tmpl` files and substitute the user's answers at install time. Never commit anyone's real project IDs, account IDs, or names into `files/`.
- **No secrets on disk.** Tokens go to `gh secret set` / `wrangler secret put`, never into rendered files.
- **Finish with next steps.** Print the remaining manual steps with the user's real values substituted into copy-pasteable commands.

### Design principles every recipe must follow

These are the promises the README makes for the whole repo — recipes that break them won't be merged:

1. Event-driven (webhooks + relay + CI), no polling loops or always-on servers.
2. Webhook payloads are doorbells only — re-fetch truth from the API and diff against saved state, so duplicates/missed events are harmless; provide a manual reconcile path.
3. Write-scope humility: comments/PRs only. The agent never moves, closes, merges, assigns, or deletes in the user's tool.
4. State in git (orphan branch) or equally inspectable storage — no hidden databases.
5. Every run leaves an audit trail (prompt + transcript + result artifacts).
6. Output written for the tool's human audience; technical depth belongs in PRs.

## Non-recipe contributions

Hardening, portability fixes (bash 3.2 on macOS is the floor), clearer docs, and translations of existing recipes to new tools (the project-agent pattern maps cleanly onto Jira/Linear/Trello/ClickUp) are all welcome. Keep shell scripts `set -euo pipefail`, dependency-light (`bash`, `git`, `jq`), and readable.
