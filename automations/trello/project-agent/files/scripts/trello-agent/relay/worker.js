/**
 * Trello → GitHub Actions relay (Cloudflare Worker).
 *
 * Quirks handled here:
 *  - Webhook creation: Trello sends a HEAD (or GET) probe and requires 200
 *    before the webhook is created — answered below.
 *  - Verification: Trello signs deliveries with base64(HMAC-SHA1(body +
 *    callbackURL, api_secret)) in `x-trello-webhook`. Verified when the
 *    TRELLO_API_SECRET worker secret is set; otherwise the URL secret is the
 *    only authentication (still fine — it's unguessable).
 *
 * Vars (wrangler.toml):  GITHUB_REPO, ENABLED_HANDLERS, WATCHED_LISTS, AGENT_MARKER
 * Secrets:  GITHUB_PAT, WEBHOOK_SECRET, TRELLO_API_SECRET (optional)
 */

/** action.type → handler family. */
function handlerFor(type) {
  if (['createCard', 'updateCard', 'commentCard', 'addAttachmentToCard', 'copyCard', 'moveCardToBoard'].includes(type)) return 'cards';
  if (['createList', 'updateList', 'moveListFromBoard', 'moveListToBoard'].includes(type)) return 'lists';
  if (['addMemberToCard', 'removeMemberFromCard'].includes(type)) return 'members';
  if (type.includes('Checklist') || type.includes('CheckItem')) return 'checklists';
  return null;
}

async function validSignature(secret, rawBody, callbackURL, signature) {
  if (!signature) return false;
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-1' }, false, ['sign'],
  );
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(rawBody + callbackURL));
  const b64 = btoa(String.fromCharCode(...new Uint8Array(mac)));
  return b64 === signature;
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
      'User-Agent': 'ai-automations-trello-relay',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ event_type: eventType, client_payload: clientPayload }),
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== `/hook/${env.WEBHOOK_SECRET}`) {
      return new Response('not found', { status: 404 });
    }

    /** Trello's creation-time probe — must return 200. */
    if (request.method === 'HEAD' || request.method === 'GET') {
      return new Response('ok', { status: 200 });
    }
    if (request.method !== 'POST') {
      return new Response('method not allowed', { status: 405 });
    }

    const rawBody = await request.text();
    if (env.TRELLO_API_SECRET) {
      const ok = await validSignature(env.TRELLO_API_SECRET, rawBody, url.toString(), request.headers.get('x-trello-webhook'));
      if (!ok) return new Response('bad signature', { status: 401 });
    }

    let event;
    try {
      event = JSON.parse(rawBody);
    } catch {
      return new Response('bad json', { status: 400 });
    }

    const action = event.action || {};
    const type = action.type || '';
    const data = action.data || {};

    const handler = handlerFor(type);
    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!handler || !enabled.includes(handler)) {
      return new Response('ignored: no enabled handler for ' + (type || 'unknown'), { status: 200 });
    }

    /**
     * Card moves to unwatched lists never produce work. updateCard fires on
     * every field edit — only list moves matter; comments arrive as their own
     * commentCard actions. Fail open when list info is missing.
     */
    const watched = (env.WATCHED_LISTS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (type === 'updateCard' && watched.length) {
      if (!data.listAfter) {
        return new Response('ignored: non-move card edit', { status: 200 });
      }
      if (!watched.includes(data.listAfter.id)) {
        return new Response('ignored: unwatched list', { status: 200 });
      }
    }
    if (type === 'createCard' && watched.length && data.list?.id && !watched.includes(data.list.id)) {
      return new Response('ignored: unwatched list', { status: 200 });
    }

    /** The agent's own comments echo back — the marker identifies them. */
    if (type === 'commentCard' && env.AGENT_MARKER) {
      if (String(data.text || '').slice(0, 120).includes(env.AGENT_MARKER)) {
        return new Response('ignored: agent comment echo', { status: 200 });
      }
    }

    const itemId = data.card?.id || '';
    if (handler === 'cards' && !itemId) {
      return new Response('ignored: no card id', { status: 200 });
    }

    const resp = await dispatch(env, 'trello_event', {
      kind: type,
      item_id: itemId,
      item_type: 'Card',
      recording_type: type,
    });

    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
