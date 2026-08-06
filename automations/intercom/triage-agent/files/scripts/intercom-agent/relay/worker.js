/**
 * Intercom → GitHub Actions relay (Cloudflare Worker).
 *
 * Intercom signs every delivery: X-Hub-Signature = "sha1=" + hex HMAC-SHA1 of
 * the raw body, keyed with the app's client secret. Intercom also probes the
 * endpoint with a HEAD request when the webhook URL is saved — answered 200
 * before any verification.
 *
 * Notification body: {topic: "conversation.user.created" |
 *   "conversation.user.replied" | "conversation.admin.replied" | …,
 *   data: {item: {id, …}}}
 *
 * Vars (wrangler.toml):  GITHUB_REPO, ENABLED_HANDLERS
 * Secrets:  GITHUB_PAT, INTERCOM_CLIENT_SECRET
 */

async function validSignature(secret, rawBody, header) {
  if (!header || !header.startsWith('sha1=')) return false;
  const hex = header.slice(5);
  if (!/^[0-9a-f]{40}$/i.test(hex)) return false;
  const sig = new Uint8Array(hex.match(/../g).map((h) => parseInt(h, 16)));
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-1' }, false, ['verify'],
  );
  // crypto.subtle.verify compares in constant time.
  return crypto.subtle.verify('HMAC', key, sig, new TextEncoder().encode(rawBody));
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
      'User-Agent': 'ai-automations-intercom-relay',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ event_type: eventType, client_payload: clientPayload }),
  });
}

export default {
  async fetch(request, env) {
    // Intercom's Developer Hub probes the endpoint URL with a HEAD request.
    if (request.method === 'HEAD') {
      return new Response(null, { status: 200 });
    }
    if (request.method !== 'POST') {
      return new Response('method not allowed', { status: 405 });
    }

    const rawBody = await request.text();
    const ok = await validSignature(
      env.INTERCOM_CLIENT_SECRET,
      rawBody,
      request.headers.get('x-hub-signature'),
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

    const topic = event.topic || '';
    if (!topic.startsWith('conversation.')) {
      return new Response('ignored: no handler for ' + (topic || 'unknown'), { status: 200 });
    }
    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!enabled.includes('conversations')) {
      return new Response('ignored: conversations handler disabled', { status: 200 });
    }

    /**
     * The agent's own internal notes echo back as conversation.admin.noted —
     * and human notes never need the agent either, so the topic is dropped
     * wholesale. Admin REPLIES are forwarded: a human answering the customer
     * is exactly the signal the respond playbook goes silent on.
     */
    if (topic === 'conversation.admin.noted') {
      return new Response('ignored: admin note echo', { status: 200 });
    }

    const itemId = (event.data && event.data.item && event.data.item.id) || '';
    if (!itemId) {
      return new Response('ignored: no conversation id', { status: 200 });
    }

    const resp = await dispatch(env, 'intercom_event', {
      kind: topic,
      item_id: String(itemId),
      item_type: 'Conversation',
      recording_type: 'conversations',
    });

    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
