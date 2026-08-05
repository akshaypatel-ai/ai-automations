# State backends

Per-item memory between runs (`phase`, `last_comment` marker, `branch`, `pr_url`, …).

- **`git-branch.sh`** (default) — JSON files on a dedicated orphan branch (name set by the recipe's `STATE_BRANCH`). No database, fully inspectable, versioned for free; concurrent runs are handled with a rebase-retry push loop. Installed into target repos as `<agent-dir>/state.sh` with a `restore | save [message]` interface.
- **Docker-server alternative** (Phase 3) — same JSON files on a mounted volume, optionally still git-pushed for inspectability.
