/**
 * Confluence → GitHub Actions relay (Cloudflare Worker).
 *
 * Confluence Cloud has no admin-configurable webhooks (that's a Connect/Forge
 * app feature), so the doorbell is a Confluence Automation rule (Premium+)
 * whose "Send web request" action POSTs here. Those requests carry no
 * portable HMAC, so authentication is the secret embedded in the URL path —
 * same model as the monday recipe. The rule's JSON body you define at setup:
 *   {"page_id": "{{page.id}}", "event": "label-added" | "comment-added"}
 *
 * Vars (wrangler.toml):  GITHUB_REPO, ENABLED_HANDLERS
 * Secrets (wrangler secret put):  GITHUB_PAT, WEBHOOK_SECRET
 */

export default {
  async fetch(request, env) {
    if (request.method !== 'POST') {
      return new Response('method not allowed', { status: 405 });
    }

    const url = new URL(request.url);
    if (url.pathname !== `/hook/${env.WEBHOOK_SECRET}`) {
      return new Response('not found', { status: 404 });
    }

    let body;
    try {
      body = await request.json();
    } catch {
      return new Response('bad json', { status: 400 });
    }

    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!enabled.includes('pages')) {
      return new Response('ignored: pages handler disabled', { status: 200 });
    }

    const pageId = body.page_id || '';
    if (!pageId) {
      return new Response('ignored: no page id (the Automation web-request body must include page_id)', { status: 200 });
    }

    const resp = await fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/dispatches`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.GITHUB_PAT}`,
        Accept: 'application/vnd.github+json',
        'User-Agent': 'ai-automations-confluence-relay',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        event_type: 'confluence_event',
        client_payload: {
          kind: body.event || 'page-event',
          item_id: String(pageId),
          item_type: 'Page',
          recording_type: 'pages',
        },
      }),
    });

    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
