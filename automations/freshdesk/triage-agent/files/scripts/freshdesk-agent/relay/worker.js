/**
 * Freshdesk → GitHub Actions relay (Cloudflare Worker).
 *
 * Freshdesk automation rules ("Trigger Webhook" action) don't sign their
 * deliveries — there's no portable HMAC — so authentication is the secret
 * embedded in the URL path, same model as the Jira/monday/Confluence recipes.
 * The rule's JSON body you define at setup:
 *   {"ticket_id": "{{ticket.id}}", "event": "created" | "updated"}
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
    if (!enabled.includes('tickets')) {
      return new Response('ignored: tickets handler disabled', { status: 200 });
    }

    const ticketId = body.ticket_id || '';
    if (!ticketId) {
      return new Response('ignored: no ticket id (the automation rule JSON body must include ticket_id)', { status: 200 });
    }

    const resp = await fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/dispatches`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.GITHUB_PAT}`,
        Accept: 'application/vnd.github+json',
        'User-Agent': 'ai-automations-freshdesk-relay',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        event_type: 'freshdesk_event',
        client_payload: {
          kind: `ticket-${body.event || 'event'}`,
          item_id: String(ticketId),
          item_type: 'Ticket',
          recording_type: 'tickets',
        },
      }),
    });

    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
