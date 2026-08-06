/**
 * LINE Messaging API → GitHub Actions relay (Cloudflare Worker).
 * Only needed for the `ask` handler — ship/incident notifications use
 * GitHub-native triggers with no relay at all.
 *
 * Verifies x-line-signature (base64 HMAC-SHA256 of the body with the channel
 * secret), forwards group text messages as repository_dispatch events, and
 * acks fast (LINE expects a prompt 200; replies go out later as push
 * messages because reply tokens expire before CI can run).
 *
 * Vars (wrangler.toml):  GITHUB_REPO, WATCHED_TARGET
 * Secrets:  GITHUB_PAT, LINE_CHANNEL_SECRET
 */

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
    const headers = { 'Content-Type': 'application/json', 'User-Agent': 'ai-automations-line-relay' };
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
      'User-Agent': 'ai-automations-line-relay',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ event_type: eventType, client_payload: clientPayload }),
  });
}

export default {
  async fetch(request, env, ctx) {
    if (request.method !== 'POST') {
      return new Response('method not allowed', { status: 405 });
    }

    const rawBody = await request.text();
    const ok = await validSignature(env.LINE_CHANNEL_SECRET, rawBody, request.headers.get('x-line-signature'));
    if (!ok) return new Response('bad signature', { status: 401 });

    let body;
    try {
      body = JSON.parse(rawBody);
    } catch {
      return new Response('bad json', { status: 400 });
    }

    const dispatches = [];
    for (const ev of body.events || []) {
      if (ev.type !== 'message' || ev.message?.type !== 'text') continue;
      const src = ev.source || {};
      const target = src.groupId || src.roomId || src.userId || '';
      /** Scope to the configured group when set. */
      if (env.WATCHED_TARGET && target !== env.WATCHED_TARGET) continue;
      dispatches.push({
        kind: 'ask',
        text: String(ev.message.text || '').slice(0, 2000),
        target,
      });
    }

    ctx.waitUntil(Promise.all(dispatches.map((d) => dispatch(env, 'line_event', d))));
    return new Response('ok', { status: 200 });
  },
};
