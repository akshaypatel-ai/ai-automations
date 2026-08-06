/**
 * Netlify → GitHub Actions relay (Cloudflare Worker).
 *
 * Fed by a Netlify deploy notification (Site configuration → Notifications →
 * Deploy notifications → Outgoing webhook) subscribed to the "Deploy failed"
 * event. The JWS secret is one YOU choose when creating the notification —
 * set the same value here as NETLIFY_JWS_SECRET.
 *
 * Every delivery is signed: X-Webhook-Signature = a JWT (HS256, keyed with
 * that secret) whose claims include {iss: "netlify", sha256: "<hex sha256 of
 * the raw request body>"}. Both are verified: the JWT signature AND that the
 * body actually hashes to the sha256 claim (a valid signature over a swapped
 * body must not pass).
 *
 * Vars (wrangler.toml):  GITHUB_REPO, ENABLED_HANDLERS, WATCHED_SITE
 * Secrets:  GITHUB_PAT, NETLIFY_JWS_SECRET
 */

function b64urlDecode(segment) {
  const b64 = segment.replace(/-/g, '+').replace(/_/g, '/')
    .padEnd(Math.ceil(segment.length / 4) * 4, '=');
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i += 1) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

async function validSignature(secret, rawBody, token) {
  if (!secret || !token) return false;
  const parts = token.split('.');
  if (parts.length !== 3) return false;
  const [header, payload, signature] = parts;

  // 1. The JWT signature: HMAC-SHA256 over `header.payload`, keyed with the secret.
  let sigBytes;
  let claims;
  try {
    sigBytes = b64urlDecode(signature);
    claims = JSON.parse(new TextDecoder().decode(b64urlDecode(payload)));
  } catch {
    return false;
  }
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['verify'],
  );
  const ok = await crypto.subtle.verify(
    'HMAC', key, sigBytes, new TextEncoder().encode(`${header}.${payload}`),
  );
  if (!ok) return false;

  // 2. The claims: issued by Netlify, and the sha256 claim must match the raw
  // body — otherwise a captured signature could be replayed over a forged body.
  if (claims.iss !== 'netlify') return false;
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(rawBody));
  const hex = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
  return hex === claims.sha256;
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
    const headers = { 'Content-Type': 'application/json', 'User-Agent': 'ai-automations-netlify-relay' };
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
      'User-Agent': 'ai-automations-netlify-relay',
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
    const ok = await validSignature(env.NETLIFY_JWS_SECRET, rawBody, request.headers.get('x-webhook-signature'));
    if (!ok) {
      return new Response('bad signature', { status: 401 });
    }

    let deploy;
    try {
      deploy = JSON.parse(rawBody);
    } catch {
      return new Response('bad json', { status: 400 });
    }

    /**
     * The body is the deploy object itself. Only the "Deploy failed"
     * notification should ever be subscribed, but belt and braces: anything
     * not in state "error" is noise for this recipe — acknowledged and dropped.
     */
    if (deploy.state !== 'error') {
      return new Response(`ignored: no route for state ${deploy.state || 'unknown'}`, { status: 200 });
    }

    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!enabled.includes('deploys')) {
      return new Response('ignored: deploys handler disabled', { status: 200 });
    }

    const deployId = deploy.id || '';
    if (!deployId) {
      return new Response('ignored: no deploy id in payload', { status: 200 });
    }

    // Optional site scoping — fail open when the payload omits the site.
    const siteId = deploy.site_id || '';
    if (env.WATCHED_SITE && siteId && siteId !== env.WATCHED_SITE) {
      return new Response('ignored: deploy outside the watched site', { status: 200 });
    }

    const resp = await dispatch(env, 'netlify_event', {
      kind: 'deploy-failed',
      item_id: String(deployId),
      item_type: 'Deploy',
      recording_type: 'deploys',
    });

    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
