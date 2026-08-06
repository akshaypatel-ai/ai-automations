/**
 * Linear → GitHub Actions relay (Cloudflare Worker).
 *
 * Verifies Linear's HMAC-SHA256 webhook signature, filters to events an
 * enabled handler can act on, and forwards a trimmed payload as a
 * repository_dispatch event.
 *
 * Vars (wrangler.toml):  GITHUB_REPO, ENABLED_HANDLERS, TEAM_KEY,
 *                        WATCHED_STATES, AGENT_MARKER
 * Secrets (wrangler secret put):  GITHUB_PAT, LINEAR_WEBHOOK_SECRET
 */

/** Linear webhook resource type → handler family. */
const HANDLER_FOR = {
  'Issue': 'issues',
  'Comment': 'issues',        // comments route to their parent issue
  'Project': 'projects',
  'ProjectUpdate': 'projects',
  'Cycle': 'cycles',
  'Document': 'docs',
};

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
 *   url              — any HTTPS job runner; needs DISPATCH_URL var + optional DISPATCH_TOKEN secret
 * Returns a fetch Response; callers keep their existing resp.ok handling.
 */
async function dispatch(env, eventType, clientPayload) {
  const mode = env.DISPATCH_KIND || 'github';
  if (mode === 'url') {
    const headers = { 'Content-Type': 'application/json', 'User-Agent': 'ai-automations-linear-relay' };
    if (env.DISPATCH_TOKEN) headers.Authorization = `Bearer ${env.DISPATCH_TOKEN}`;
    return fetch(env.DISPATCH_URL, {
      method: 'POST',
      headers,
      body: JSON.stringify({ event_type: eventType, client_payload: clientPayload }),
    });
  }
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
      'User-Agent': 'ai-automations-linear-relay',
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
    const ok = await validSignature(env.LINEAR_WEBHOOK_SECRET, rawBody, request.headers.get('linear-signature'));
    if (!ok) {
      return new Response('bad signature', { status: 401 });
    }

    let event;
    try {
      event = JSON.parse(rawBody);
    } catch {
      return new Response('bad json', { status: 400 });
    }

    const type = event.type || '';
    const data = event.data || {};
    const handler = HANDLER_FOR[type];
    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!handler || !enabled.includes(handler)) {
      return new Response('ignored: no enabled handler for ' + (type || 'unknown'), { status: 200 });
    }

    /** Scope to one team when configured (issues carry team on the payload). */
    if (env.TEAM_KEY && type === 'Issue' && data.team?.key && data.team.key !== env.TEAM_KEY) {
      return new Response('ignored: other team', { status: 200 });
    }

    /**
     * Issue updates fire for every field edit. Only state changes into a
     * watched state (or creation in one) can produce work — everything else
     * arrives as its own Comment event. Fail open when state info is missing.
     */
    const watched = (env.WATCHED_STATES || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (type === 'Issue' && watched.length) {
      const stateName = data.state?.name || '';
      const stateChanged = event.action === 'create' || (event.updatedFrom && 'stateId' in event.updatedFrom);
      if (stateName && !watched.includes(stateName)) {
        return new Response('ignored: unwatched state', { status: 200 });
      }
      if (event.action === 'update' && !stateChanged) {
        return new Response('ignored: non-state issue edit', { status: 200 });
      }
    }

    /** The agent's own comments echo back — the marker identifies them. */
    if (type === 'Comment' && env.AGENT_MARKER) {
      if (String(data.body || '').slice(0, 120).includes(env.AGENT_MARKER)) {
        return new Response('ignored: agent comment echo', { status: 200 });
      }
    }

    const itemId = type === 'Comment' ? (data.issueId || data.issue?.id || '')
      : type === 'ProjectUpdate' ? (data.projectId || data.project?.id || data.id)
      : data.id;
    const itemType = type === 'Comment' ? 'Issue' : type === 'ProjectUpdate' ? 'Project' : type;
    if (!itemId) {
      return new Response('ignored: no item id', { status: 200 });
    }

    const resp = await dispatch(env, 'linear_event', {
      kind: `${type.toLowerCase()}_${event.action || 'event'}`,
      item_id: itemId,
      item_type: itemType,
      recording_type: type,
    });

    /** Non-2xx makes Linear retry the webhook — desired on GitHub hiccups. */
    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
