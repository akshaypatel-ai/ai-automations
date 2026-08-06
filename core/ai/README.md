# AI brain adapters

A *brain* is what thinks inside an automation. Each adapter is one bash file
implementing the same contract, so recipes stay provider-neutral: playbooks are
plain markdown prompts, and the installer copies the chosen adapter into the
target repo as `<agent-dir>/ai/brain.sh`.

## Contract (v2)

```bash
AI_NAME="claude-code"        # identifier for logs
CAN_EDIT_REPO=1              # may modify files / push branches — 0 for text-only API brains
CAN_RUN_TOOLS=1              # may execute shell commands (helper scripts, gh) — see the two classes below
HAS_TRANSCRIPT=1             # ai_run writes a transcript file
AI_AUTH_VARS="..."           # space-separated secret names CI must provide (any ONE may suffice — ai_check decides)
AI_DEFAULT_MODEL="..."       # seed for the installer's model question (runs read $AI_MODEL)

ai_install                   # install the CLI inside the CI runner (no-op for raw-API brains)
ai_check                     # → 0 when deps + credentials look usable (called by installers/doctor/CI)
ai_run <prompt_file> <transcript_out>    # run headless in $PWD; non-zero exit = playbook failed
ai_result <transcript_out>   # print the run's final summary text (for CI logs)
```

## The two brain classes — an honest distinction

Every shipped playbook makes the brain *act through tools*: post a comment via
`./comment.sh`, open a PR via `gh`, fetch context via `./api.sh`. That requires
`CAN_RUN_TOOLS=1` — an agentic CLI with shell execution.

Text-only brains (`CAN_RUN_TOOLS=0`: Aider, raw API adapters) can't drive those
playbooks themselves — so on the **notify, summon, and triage** shapes the
driver does it for them (**driver-mediated write-back**, Phase 2b): the driver
assembles all context into the prompt (for triage it fetches the ticket itself,
since the brain can't), the brain replies with plain text, and the driver
delivers that text through the recipe's own helper and writes the result file.
The trade-off is honest and real: no GitHub escalation, no `implement`, and the
project shapes plus recipes whose write path is `gh` itself (Sentry, Vercel,
Netlify, Buildkite, Slack) still need a tool-running brain. The chooser
(`core/lib/brains.sh`) offers text-only brains only where a recipe opts in
with `mediated` mode.

## Available

| Adapter | Kind | Tools | Status |
|---|---|---|---|
| `claude-code.sh` | Agentic CLI (Claude Code; subscription token or API key) | ✅ | ✅ default |
| `codex.sh` | Agentic CLI (OpenAI Codex; `OPENAI_API_KEY` or `codex login`) | ✅ | ✅ |
| `gemini-cli.sh` | Agentic CLI (Gemini; generous free tier) | ✅ | ✅ |
| `aider.sh` | Edit-capable pair programmer, model-agnostic incl. Ollama/local | ❌ | ✅ via driver-mediated mode (notify, summon, and triage shapes; no GitHub escalation, no implement) |
| `api-anthropic.sh` | Raw Messages API (curl+jq, no CLI) | ❌ | ✅ via driver-mediated mode (same shapes and limits) |
| `api-openai.sh` / `api-gemini.sh` | Raw APIs | ❌ | 🔜 |

## Caveats worth knowing before switching brains

- The playbooks were battle-tested with Claude Code. Codex/Gemini run the same
  prompts, but per-brain output quality varies — the playbooks state *outcomes*
  (one comment, marker prefix, result file) precisely so weaker models fail
  loudly rather than subtly.
- `ai_check` runs in CI before any playbook; a missing secret fails the run
  with a clear message instead of a half-executed playbook.
- Transcripts differ by brain: Claude Code and Codex emit event streams; the
  Gemini CLI transcript is its timestamped stdout. All land in the same
  `.agent-out/` artifact.
