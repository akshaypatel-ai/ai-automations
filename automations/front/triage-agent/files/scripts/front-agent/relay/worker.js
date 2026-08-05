/**
 * Front → GitHub Actions relay (Cloudflare Worker).
 *
 * Front rule webhooks (the "Send to a webhook" rule action) don't sign their
 * deliveries — Front's signed application webhooks exist, but they require
 * building a developer app — so authentication is the secret embedded in the
 * URL path, same model as the Freshdesk/Jira/monday/Confluence recipes.
 * The rule POSTs a conversation preview object; the id is extracted
 * defensively (body.conversation.id or body.id, always "cnv_…").
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
    if (!enabled.includes('conversations')) {
      return new Response('ignored: conversations handler disabled', { status: 200 });
    }

    const conversationId = String(body.conversation?.id || body.id || '');
    if (!conversationId.startsWith('cnv_')) {
      return new Response('ignored: no conversation id (expected a "cnv_…" id — point a Front rule\'s "Send to a webhook" action at this URL)', { status: 200 });
    }

    const resp = await fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/dispatches`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.GITHUB_PAT}`,
        Accept: 'application/vnd.github+json',
        'User-Agent': 'ai-automations-front-relay',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        event_type: 'front_event',
        client_payload: {
          kind: 'conversation-event',
          item_id: conversationId,
          item_type: 'Conversation',
          recording_type: 'conversations',
        },
      }),
    });

    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
