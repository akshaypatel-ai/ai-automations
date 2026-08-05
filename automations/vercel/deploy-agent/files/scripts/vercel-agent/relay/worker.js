/**
 * Vercel → GitHub Actions relay (Cloudflare Worker).
 *
 * Fed by a Vercel webhook (Team/Account Settings → Webhooks) subscribed to
 * the deployment.error event and scoped to your project(s). Creating the
 * webhook shows its secret exactly once — store it immediately.
 *
 * Every delivery is signed: x-vercel-signature = hex HMAC-SHA1 of the raw
 * body, keyed with that secret.
 *
 * Vars (wrangler.toml):  GITHUB_REPO, ENABLED_HANDLERS, WATCHED_PROJECT
 * Secrets:  GITHUB_PAT, VERCEL_WEBHOOK_SECRET
 */

async function validSignature(secret, rawBody, signature) {
  if (!secret || !signature) return false;
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-1' }, false, ['sign'],
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
    const ok = await validSignature(env.VERCEL_WEBHOOK_SECRET, rawBody, request.headers.get('x-vercel-signature'));
    if (!ok) {
      return new Response('bad signature', { status: 401 });
    }

    let event;
    try {
      event = JSON.parse(rawBody);
    } catch {
      return new Response('bad json', { status: 400 });
    }

    /**
     * Only failed deployments wake the agent. deployment.created / succeeded /
     * canceled are noise for this recipe — acknowledged and dropped. (A future
     * ship handler could forward deployment.succeeded to a notify recipe.)
     */
    if (event.type !== 'deployment.error') {
      return new Response(`ignored: no route for ${event.type || 'unknown'}`, { status: 200 });
    }

    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!enabled.includes('deployments')) {
      return new Response('ignored: deployments handler disabled', { status: 200 });
    }

    const deploymentId = event.payload?.deployment?.id || '';
    if (!deploymentId) {
      return new Response('ignored: no deployment id in payload', { status: 200 });
    }

    // Optional project scoping — fail open when the payload omits the project.
    const projectId = event.payload?.project?.id || '';
    if (env.WATCHED_PROJECT && projectId && projectId !== env.WATCHED_PROJECT) {
      return new Response('ignored: deployment outside the watched project', { status: 200 });
    }

    const resp = await fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/dispatches`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.GITHUB_PAT}`,
        Accept: 'application/vnd.github+json',
        'User-Agent': 'ai-automations-vercel-relay',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        event_type: 'vercel_event',
        client_payload: {
          kind: event.type,
          item_id: String(deploymentId),
          item_type: 'Deployment',
          recording_type: 'deployments',
        },
      }),
    });

    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
