# Security Policy

## Reporting a vulnerability

Please use **GitHub's private vulnerability reporting** (Security tab →
"Report a vulnerability") rather than a public issue. You'll get a response
within a few days. Please don't disclose publicly until a fix ships.

## What counts as a vulnerability here

This repo ships *installers* and *templates* — the running system lives in
**your** repository and Cloudflare account. Reports we care most about:

- A relay template that can be made to forward unverified events (signature /
  token / URL-secret bypass).
- An installer that could write a credential into a file (the design rule is:
  secrets go only to GitHub/Cloudflare secret stores — any violation is a bug).
- A playbook/driver path that lets tool-side content escalate what the agent
  does beyond its documented write scope (comments/notes/issues/PRs only).
- Injection through rendered templates (`{{TOKENS}}`) or installer answers.

## Design properties you can rely on (and should verify)

- **Write-scope humility**: agents comment and open PRs; they never move
  cards, change statuses, merge, close, assign, or delete. If a recipe can be
  made to exceed that, it's a security bug — report it.
- **Verified ingress**: every relay authenticates deliveries by the strongest
  mechanism its tool offers (HMAC/Ed25519/JWS where available; unguessable
  URL secrets where the tool signs nothing — each recipe README states which,
  honestly).
- **No secrets in git**: installers prompt for IDs, never tokens; tokens go to
  secret stores. CI on this repo runs secret scanning to keep it that way.
- **Disposable execution**: `--dangerously-skip-permissions` (and equivalents)
  run only inside throwaway CI runners, never on your machine — local runs are
  `DRY_RUN` and stop before any AI call.

## Supported versions

`main` only — recipes are templates; re-run the installer to pick up fixes
(answers are remembered in `automation.config.json`).
