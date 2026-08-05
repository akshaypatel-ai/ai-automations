# AI brain adapters

A *brain* is what thinks inside an automation. Each adapter is one bash file
implementing the same contract, so recipes stay provider-neutral: playbooks are
plain markdown prompts, and the installer copies the chosen adapter into the
target repo as `<agent-dir>/ai/brain.sh`.

## Contract

```bash
AI_NAME="claude-code"        # identifier for logs
CAN_EDIT_REPO=1              # may modify files / push branches (agentic CLI) — 0 for text-only API brains
HAS_TRANSCRIPT=1             # ai_run writes a machine-readable transcript

ai_check                     # → 0 when deps + credentials look usable (called by installers/doctor)
ai_run <prompt_file> <transcript_out>    # run headless in $PWD; non-zero exit = playbook failed
ai_result <transcript_out>   # print the run's final summary text (for CI logs)
```

Recipes declare what they need: a playbook that writes code (`implement`)
requires `CAN_EDIT_REPO=1`; analyze/respond-style playbooks don't. The
installer only offers compatible brains.

## Available

| Adapter | Kind | Status |
|---|---|---|
| `claude-code.sh` | Agentic CLI (Claude Code, subscription token or API key) | ✅ |
| `codex.sh` | Agentic CLI (OpenAI Codex) | 🔜 Phase 2 |
| `gemini-cli.sh` | Agentic CLI (Gemini, free tier) | 🔜 Phase 2 |
| `aider.sh` | Agentic CLI, model-agnostic incl. Ollama/local | 🔜 Phase 2 |
| `api-anthropic.sh` / `api-openai.sh` / `api-gemini.sh` | Raw API (text-only, curl+jq) | 🔜 Phase 2 |
