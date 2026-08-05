/**
 * monday.com → GitHub Actions relay (Cloudflare Worker).
 *
 * Board webhooks created via the API don't carry a portable HMAC, so
 * authentication is the secret embedded in the URL path (same model as the
 * Basecamp/Jira recipes). Webhook creation sends a challenge — the relay
 * echoes it back. Deliveries are filtered to events an enabled handler can
 * act on, then forwarded as a trimmed payload.
 *
 * Vars (wrangler.toml):  GITHUB_REPO, ENABLED_HANDLERS, WATCHED_BOARD,
 *                        STATUS_COLUMN_ID, AGENT_MARKER
 * Secrets (wrangler secret put):  GITHUB_PAT, WEBHOOK_SECRET
 */

/** payload event type → handler family. */
function handlerFor(type) {
  if (type.includes('subitem')) return 'subitems';
  if (type === 'create_pulse' || type === 'update_column_value'
    || type === 'update_name' || type === 'create_update'
    || type === 'edit_update') return 'items';
  return null;
}

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

    // Webhook-creation challenge: echo it back verbatim.
    if (body.challenge) {
      return new Response(JSON.stringify({ challenge: body.challenge }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const event = body.event || {};
    const type = event.type || '';
    const handler = handlerFor(type);
    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!handler || !enabled.includes(handler)) {
      return new Response('ignored: no enabled handler for ' + (type || 'unknown'), { status: 200 });
    }

    if (env.WATCHED_BOARD && event.boardId && String(event.boardId) !== env.WATCHED_BOARD) {
      return new Response('ignored: other board', { status: 200 });
    }

    /** Column edits fire for every column — only the status column matters. */
    if (type === 'update_column_value' && env.STATUS_COLUMN_ID
      && event.columnId && event.columnId !== env.STATUS_COLUMN_ID) {
      return new Response('ignored: other column', { status: 200 });
    }

    /** The agent's own updates echo back — the marker identifies them. */
    if ((type === 'create_update' || type === 'edit_update') && env.AGENT_MARKER) {
      const text = (event.textBody || '').slice(0, 200);
      if (text.includes(env.AGENT_MARKER)) {
        return new Response('ignored: agent update echo', { status: 200 });
      }
    }

    const itemId = event.pulseId || event.itemId || '';
    if (handler === 'items' && !itemId) {
      return new Response('ignored: no item id', { status: 200 });
    }

    const resp = await fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/dispatches`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.GITHUB_PAT}`,
        Accept: 'application/vnd.github+json',
        'User-Agent': 'ai-automations-monday-relay',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        event_type: 'monday_event',
        client_payload: {
          kind: type,
          item_id: String(itemId),
          item_type: handler === 'items' ? 'Item' : 'Subitem',
          recording_type: type,
        },
      }),
    });

    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
