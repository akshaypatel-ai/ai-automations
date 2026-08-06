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

/**
 * Forward a doorbell to the runtime. Default: GitHub repository_dispatch.
 * Set DISPATCH_KIND to retarget without touching the rest of the worker:
 *   github (default) — needs GITHUB_REPO var + GITHUB_PAT secret
 *   gitlab           — needs GITLAB_TRIGGER_URL var (https://gitlab.com/api/v4/projects/<id>/trigger/pipeline)
 *                      + GITLAB_TRIGGER_TOKEN secret + GITLAB_REF var (default main)
 *   bitbucket        — needs BITBUCKET_WORKSPACE/BITBUCKET_REPO vars + BITBUCKET_TOKEN secret (Bearer)
 * Returns a fetch Response; callers keep their existing resp.ok handling.
 */
async function dispatch(env, eventType, clientPayload) {
  const mode = env.DISPATCH_KIND || 'github';
  if (mode === 'gitlab' || mode === 'bitbucket') {
    const map = {
      ITEM_ID: clientPayload.item_id, ITEM_TYPE: clientPayload.item_type,
      EVENT_KIND: clientPayload.kind, ASK_TEXT: clientPayload.text,
      ASK_CHAT_ID: clientPayload.chat_id, ASK_APP_ID: clientPayload.app_id,
      ASK_TOKEN: clientPayload.interaction_token, FILE_KEY: clientPayload.file_key,
      ROOT_ID: clientPayload.root_id,
    };
    const vars = Object.entries(map).filter(([, v]) => v !== undefined && v !== null);
    if (mode === 'gitlab') {
      const form = new URLSearchParams({ token: env.GITLAB_TRIGGER_TOKEN, ref: env.GITLAB_REF || 'main' });
      for (const [k, v] of vars) form.set(`variables[${k}]`, String(v));
      return fetch(env.GITLAB_TRIGGER_URL, { method: 'POST', body: form });
    }
    return fetch(`https://api.bitbucket.org/2.0/repositories/${env.BITBUCKET_WORKSPACE}/${env.BITBUCKET_REPO}/pipelines`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${env.BITBUCKET_TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        target: {
          type: 'pipeline_ref_target', ref_type: 'branch',
          ref_name: env.BITBUCKET_REF || 'main',
          selector: { type: 'custom', pattern: 'agent' },
        },
        variables: vars.map(([key, v]) => ({ key, value: String(v) })),
      }),
    });
  }
  return fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/dispatches`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${env.GITHUB_PAT}`,
      Accept: 'application/vnd.github+json',
      'User-Agent': 'ai-automations-clickup-relay',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ event_type: eventType, client_payload: clientPayload }),
  });
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

    const resp = await dispatch(env, 'clickup_event', {
      kind: name,
      item_id: itemId,
      item_type: 'Task',
      recording_type: name,
    });

    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
