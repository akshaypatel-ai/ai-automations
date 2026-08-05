# Relay adapters (webhook ingress)

Most tools' webhooks cannot send the auth header a CI trigger API needs, so a
tiny relay bridges them. A relay always does the same three things:

1. **Verify** the request (HMAC signature where the tool offers one, secret-in-URL otherwise).
2. **Filter** to events that can actually produce work (watched columns, non-agent comments) — so CI minutes are only spent when there's something to do.
3. **Forward** a trimmed `{item_id, kind}` payload to the runtime's trigger API.

## Options

| Relay | Cost | Notes |
|---|---|---|
| **Cloudflare Worker** (default) | Free tier | ~80 lines; ships inside each recipe under `files/.../relay/` |
| Vercel / Netlify function | Free tier | Same logic, different host — port on demand |
| AWS Lambda + Function URL | Pennies | For AWS shops |
| **None** | — | GitLab trigger-token mode and the Docker-server runtime accept webhooks directly (Phase 3) |
| n8n / Pipedream / Zapier | Varies | No-code alternative: HTTP trigger → filter → HTTP request to the runtime API |

In Phase 1 the Cloudflare Worker lives inside the Basecamp recipe (its
filtering is tool-specific); when the second tool lands, the shared
verify/forward scaffolding moves here.
