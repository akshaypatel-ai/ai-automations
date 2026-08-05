# Shared installer libraries

Sourced by every recipe's `setup.sh`. Both are bash 3.2-safe (macOS default shell floor).

- **`wizard.sh`** — interactive prompts: `say`/`note` (output), `ask` (required, with optional default), `ask_opt` (empty allowed), `confirm` (explicit yes), `need` (dependency check).
- **`render.sh`** — `{{TOKEN}}` template renderer: set `RENDER_VARS` to a space-separated list of variable names, then `render <src> <dest>`. Pure bash substitution, so values may safely contain `/`, `&`, emoji, and quotes. `render_check <path>...` warns about unrendered tokens after install.
