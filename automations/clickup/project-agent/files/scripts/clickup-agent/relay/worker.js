/**
 * ClickUp → GitHub Actions relay (Cloudflare Worker).
 *
 * Verifies ClickUp's HMAC-SHA256 webhook signature (X-Signature header, hex,
 * keyed with the secret returned at webhook creation), filters to events an
 * enabled handler can act on, and forwards a trimmed payload.
 *
 * Vars (wrangler.toml):  GITHUB_REPO, ENABLED_HANDLERS, WATCHED_LIST, AGENT_MARKER
 * Secrets:  GITHUB_PAT, CLICKUP_WEBHOOK_SECRET
 */

/** event → handler family. */
function handlerFor(event) {
  if (event.startsWith('taskTime')) return 'time';
  if (event.startsWith('task')) return 'tasks';
  if (event.startsWith('list')) return 'lists';
  if (event.startsWith('folder') || event.startsWith('space')) return 'folders';
  if (event.startsWith('goal') || event.startsWith('keyResult')) return 'goals';
  return null;
}

/** Events that never produce work for the tasks handler (field-edit noise). */
const NOISY_TASK_EVENTS = new Set([
  'taskUpdated', 'taskAssigneeUpdated', 'taskPriorityUpdated',
  'taskDueDateUpdated', 'taskTagUpdated', 'taskDeleted',
]);

async function validSignature(secret, rawBody, signature) {
  if (!signature) return false;
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(rawBody));
  const hex = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, '0')).join('');
  return hex === signature;
}

export default {
  async fetch(request, env) {
    if (request.method !== 'POST') {
      return new Response('method not allowed', { status: 405 });
    }

    const rawBody = await request.text();
    const ok = await validSignature(env.CLICKUP_WEBHOOK_SECRET, rawBody, request.headers.get('x-signature'));
    if (!ok) {
      return new Response('bad signature', { status: 401 });
    }

    let event;
    try {
      event = JSON.parse(rawBody);
    } catch {
      return new Response('bad json', { status: 400 });
    }

    const name = event.event || '';
    const handler = handlerFor(name);
    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!handler || !enabled.includes(handler)) {
      return new Response('ignored: no enabled handler for ' + (name || 'unknown'), { status: 200 });
    }

    if (handler === 'tasks' && NOISY_TASK_EVENTS.has(name)) {
      return new Response('ignored: noisy task event', { status: 200 });
    }

    /** The agent's own comments echo back — the marker identifies them. */
    if (name === 'taskCommentPosted' && env.AGENT_MARKER) {
      const text = (event.history_items || [])
        .map((h) => h.comment?.text_content || '').join(' ').slice(0, 200);
      if (text.includes(env.AGENT_MARKER)) {
        return new Response('ignored: agent comment echo', { status: 200 });
      }
    }

    const itemId = event.task_id || '';
    if (handler === 'tasks' && !itemId) {
      return new Response('ignored: no task id', { status: 200 });
    }

    const resp = await fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/dispatches`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.GITHUB_PAT}`,
        Accept: 'application/vnd.github+json',
        'User-Agent': 'ai-automations-clickup-relay',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        event_type: 'clickup_event',
        client_payload: {
          kind: name,
          item_id: itemId,
          item_type: 'Task',
          recording_type: name,
        },
      }),
    });

    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
