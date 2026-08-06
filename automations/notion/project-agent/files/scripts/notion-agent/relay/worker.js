/**
 * Notion → GitHub Actions relay (Cloudflare Worker).
 *
 * Subscription verification: Notion POSTs {"verification_token": ...} once
 * when the webhook URL is saved — the relay logs it (grab from
 * `wrangler tail`, paste into the integration UI to verify, AND store it:
 * `wrangler secret put NOTION_VERIFICATION_TOKEN`).
 *
 * Every delivery afterwards carries X-Notion-Signature =
 * "sha256=<hex HMAC-SHA256(body)>" keyed with that same token.
 *
 * Notion events are compact (entity id + type, no content) — doorbells only.
 *
 * Vars (wrangler.toml):  GITHUB_REPO, ENABLED_HANDLERS, WATCHED_DATABASE
 * Secrets:  GITHUB_PAT, NOTION_VERIFICATION_TOKEN
 */

/** Events that never produce work for the pages handler. */
const NOISY_EVENTS = new Set([
  'page.deleted', 'page.locked', 'page.unlocked', 'page.content_updated',
  'comment.deleted',
]);

/** event type → handler family + the page id worth waking the agent for. */
function routeEvent(body) {
  const type = body.type || '';
  if (type.startsWith('comment.')) {
    return { family: 'pages', id: body.data?.page_id || body.data?.parent?.id, itemType: 'Page' };
  }
  if (type.startsWith('page.')) {
    return { family: 'pages', id: body.entity?.id, itemType: 'Page' };
  }
  if (type.startsWith('database.') || type.startsWith('data_source.')) {
    return { family: 'databases', id: body.entity?.id, itemType: 'Database' };
  }
  return null;
}

const norm = (s) => (s || '').replace(/-/g, '').toLowerCase();

async function validSignature(secret, rawBody, header) {
  if (!header) return false;
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(rawBody));
  const hex = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, '0')).join('');
  return `sha256=${hex}` === header;
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
      'User-Agent': 'ai-automations-notion-relay',
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
    let body;
    try {
      body = JSON.parse(rawBody);
    } catch {
      return new Response('bad json', { status: 400 });
    }

    // One-time subscription verification.
    if (body.verification_token) {
      console.log('NOTION VERIFICATION TOKEN (paste into the integration UI AND store it: wrangler secret put NOTION_VERIFICATION_TOKEN):', body.verification_token);
      return new Response('ok', { status: 200 });
    }

    if (!env.NOTION_VERIFICATION_TOKEN) {
      return new Response('verification token not configured yet', { status: 401 });
    }
    const ok = await validSignature(env.NOTION_VERIFICATION_TOKEN, rawBody, request.headers.get('x-notion-signature'));
    if (!ok) {
      return new Response('bad signature', { status: 401 });
    }

    const type = body.type || '';
    if (NOISY_EVENTS.has(type)) {
      return new Response('ignored: noisy event', { status: 200 });
    }

    const route = routeEvent(body);
    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!route || !enabled.includes(route.family)) {
      return new Response('ignored: no enabled handler for ' + (type || 'unknown'), { status: 200 });
    }
    if (!route.id) {
      return new Response('ignored: no entity id', { status: 200 });
    }

    // Page events carry the parent database — filter to the watched one
    // (fail open when the parent is absent, e.g. comment events).
    const parentId = body.data?.parent?.id;
    if (route.family === 'pages' && env.WATCHED_DATABASE && parentId
      && body.data?.parent?.type?.includes('database')
      && norm(parentId) !== norm(env.WATCHED_DATABASE)) {
      return new Response('ignored: other database', { status: 200 });
    }

    const resp = await dispatch(env, 'notion_event', {
      kind: type,
      item_id: route.id,
      item_type: route.itemType,
      recording_type: route.family,
    });

    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
