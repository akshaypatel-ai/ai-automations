/**
 * Help Scout → GitHub Actions relay (Cloudflare Worker).
 *
 * Help Scout signs every delivery: X-HelpScout-Signature = base64 HMAC-SHA1
 * of the raw body, keyed with the Secret Key YOU typed into the webhook form
 * (Manage → Apps → Webhooks). The event name rides in X-HelpScout-Event and
 * the payload body is the conversation object itself (its .id is the
 * conversation id).
 *
 * Vars (wrangler.toml):  GITHUB_REPO, ENABLED_HANDLERS
 * Secrets:  GITHUB_PAT, HELPSCOUT_SECRET_KEY
 */

async function validSignature(secret, rawBody, header) {
  if (!secret || !header) return false;
  let sig;
  try {
    sig = Uint8Array.from(atob(header), (c) => c.charCodeAt(0));
  } catch {
    return false;
  }
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-1' }, false, ['verify'],
  );
  // crypto.subtle.verify compares in constant time.
  return crypto.subtle.verify('HMAC', key, sig, new TextEncoder().encode(rawBody));
}

const FORWARDED = ['convo.created', 'convo.customer.reply.created', 'convo.agent.reply.created'];

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
    const headers = { 'Content-Type': 'application/json', 'User-Agent': 'ai-automations-helpscout-relay' };
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
      'User-Agent': 'ai-automations-helpscout-relay',
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
    const ok = await validSignature(
      env.HELPSCOUT_SECRET_KEY,
      rawBody,
      request.headers.get('x-helpscout-signature'),
    );
    if (!ok) {
      return new Response('bad signature', { status: 401 });
    }

    let body;
    try {
      body = JSON.parse(rawBody);
    } catch {
      return new Response('bad json', { status: 400 });
    }

    const event = request.headers.get('x-helpscout-event') || '';
    /**
     * The agent's own internal notes echo back as convo.note.created if that
     * event is ever subscribed — dropped wholesale, loop protection (human
     * notes never need the agent either). Agent REPLIES are forwarded: a
     * human answering the customer is exactly the signal the respond
     * playbook goes silent on.
     */
    if (event === 'convo.note.created') {
      return new Response('ignored: note echo', { status: 200 });
    }
    if (!FORWARDED.includes(event)) {
      return new Response('ignored: no handler for ' + (event || 'unknown'), { status: 200 });
    }
    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!enabled.includes('conversations')) {
      return new Response('ignored: conversations handler disabled', { status: 200 });
    }

    const conversationId = body.id || '';
    if (!conversationId) {
      return new Response('ignored: no conversation id', { status: 200 });
    }

    const resp = await dispatch(env, 'helpscout_event', {
      kind: event,
      item_id: String(conversationId),
      item_type: 'Conversation',
      recording_type: 'conversations',
    });

    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
