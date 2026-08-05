/**
 * Zendesk → GitHub Actions relay (Cloudflare Worker).
 *
 * Zendesk webhooks sign every delivery: X-Zendesk-Webhook-Signature =
 * base64 HMAC-SHA256 of (timestamp + body), keyed with the webhook's signing
 * secret; the timestamp rides in X-Zendesk-Webhook-Signature-Timestamp.
 *
 * The webhook is fed by Zendesk TRIGGERS whose JSON body you define at setup:
 *   {"ticket_id": "{{ticket.id}}", "event": "created" | "commented"}
 *
 * Vars (wrangler.toml):  GITHUB_REPO, ENABLED_HANDLERS
 * Secrets:  GITHUB_PAT, ZENDESK_WEBHOOK_SECRET
 */

async function validSignature(secret, timestamp, rawBody, header) {
  if (!header || !timestamp) return false;
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(timestamp + rawBody));
  const b64 = btoa(String.fromCharCode(...new Uint8Array(mac)));
  return b64 === header;
}

export default {
  async fetch(request, env) {
    if (request.method !== 'POST') {
      return new Response('method not allowed', { status: 405 });
    }

    const rawBody = await request.text();
    const ok = await validSignature(
      env.ZENDESK_WEBHOOK_SECRET,
      request.headers.get('x-zendesk-webhook-signature-timestamp'),
      rawBody,
      request.headers.get('x-zendesk-webhook-signature'),
    );
    if (!ok) {
      return new Response('bad signature', { status: 401 });
    }

    let event;
    try {
      event = JSON.parse(rawBody);
    } catch {
      return new Response('bad json', { status: 400 });
    }

    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!enabled.includes('tickets')) {
      return new Response('ignored: tickets handler disabled', { status: 200 });
    }

    const ticketId = event.ticket_id || '';
    if (!ticketId) {
      return new Response('ignored: no ticket id (check the trigger JSON body)', { status: 200 });
    }

    const resp = await fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/dispatches`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.GITHUB_PAT}`,
        Accept: 'application/vnd.github+json',
        'User-Agent': 'ai-automations-zendesk-relay',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        event_type: 'zendesk_event',
        client_payload: {
          kind: `ticket-${event.event || 'event'}`,
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
