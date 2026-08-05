/**
 * Todoist → GitHub Actions relay (Cloudflare Worker).
 *
 * Verifies Todoist's webhook signature (X-Todoist-Hmac-SHA256 header, BASE64
 * HMAC-SHA256 of the raw body, keyed with the app's Client Secret from the
 * App Management console), filters to events an enabled handler can act on,
 * and forwards a doorbell dispatch.
 *
 * Reminder: Todoist webhooks only fire for accounts that authorized the app —
 * complete the app's OAuth flow once with your own account to activate them.
 *
 * Vars (wrangler.toml):  GITHUB_REPO, ENABLED_HANDLERS, WATCHED_PROJECT, AGENT_MARKER
 * Secrets:  GITHUB_PAT, TODOIST_CLIENT_SECRET
 */

/** event_name → handler family. item + note events both wake the tasks handler. */
function handlerFor(name) {
  if (name.startsWith('item:') || name.startsWith('note:')) return 'tasks';
  const prefix = name.split(':')[0];
  return prefix ? `${prefix}s` : null;
}

const ITEM_TYPES = { tasks: 'Task', projects: 'Project', sections: 'Section', labels: 'Label' };

/** Events that never produce work for the tasks handler (the resolver would skip them anyway). */
const NOISY_ITEM_EVENTS = new Set(['item:deleted', 'item:completed']);

async function validSignature(secret, rawBody, signature) {
  if (!signature) return false;
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(rawBody));
  const b64 = btoa(String.fromCharCode(...new Uint8Array(mac)));
  return b64 === signature;
}

export default {
  async fetch(request, env) {
    if (request.method !== 'POST') {
      return new Response('method not allowed', { status: 405 });
    }

    if (!env.TODOIST_CLIENT_SECRET) {
      return new Response('client secret not configured yet', { status: 401 });
    }
    const rawBody = await request.text();
    const ok = await validSignature(env.TODOIST_CLIENT_SECRET, rawBody, request.headers.get('x-todoist-hmac-sha256'));
    if (!ok) {
      return new Response('bad signature', { status: 401 });
    }

    let event;
    try {
      event = JSON.parse(rawBody);
    } catch {
      return new Response('bad json', { status: 400 });
    }

    const name = event.event_name || '';
    const handler = handlerFor(name);
    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!handler || !enabled.includes(handler)) {
      return new Response('ignored: no enabled handler for ' + (name || 'unknown'), { status: 200 });
    }

    if (NOISY_ITEM_EVENTS.has(name)) {
      return new Response('ignored: noisy item event', { status: 200 });
    }

    const data = event.event_data || {};

    /** The agent's own comments echo back as note events — the marker identifies them. */
    if ((name === 'note:added' || name === 'note:updated') && env.AGENT_MARKER) {
      const text = (data.content || '').slice(0, 200);
      if (text.includes(env.AGENT_MARKER)) {
        return new Response('ignored: agent comment echo', { status: 200 });
      }
    }

    // Optional scoping — fail open when the event doesn't name a project.
    if (env.WATCHED_PROJECT && data.project_id && String(data.project_id) !== env.WATCHED_PROJECT) {
      return new Response('ignored: outside watched project', { status: 200 });
    }

    // item:* events carry the task id in event_data.id; note:* events point at
    // their parent task via item_id (older payloads nest it as item.id).
    let id;
    if (name.startsWith('note:')) {
      id = data.item_id || (data.item && data.item.id) || '';
    } else {
      id = data.id || '';
    }
    if (!id) {
      return new Response('ignored: no item id', { status: 200 });
    }

    const resp = await fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/dispatches`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.GITHUB_PAT}`,
        Accept: 'application/vnd.github+json',
        'User-Agent': 'ai-automations-todoist-relay',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        event_type: 'todoist_event',
        client_payload: {
          kind: name,
          item_id: String(id),
          item_type: ITEM_TYPES[handler] || 'Task',
          recording_type: handler,
        },
      }),
    });

    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
