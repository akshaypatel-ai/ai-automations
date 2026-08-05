/**
 * Buildkite → GitHub Actions relay (Cloudflare Worker).
 *
 * Fed by a Buildkite webhook notification service (Organization Settings →
 * Notification Services → Webhook — a pipeline-level webhook works too)
 * subscribed to the build.failed event. The service shows a Token on its
 * settings page — store it as BUILDKITE_WEBHOOK_SECRET.
 *
 * Buildkite deliveries have historically carried two auth options, and which
 * headers arrive depends on how the service is configured:
 *   X-Buildkite-Signature  "timestamp=<t>,signature=<hex>" — hex HMAC-SHA256
 *                          of `<t>.<rawBody>`, keyed with the token. Proves
 *                          the body wasn't tampered with; preferred.
 *   X-Buildkite-Token      the token itself, sent in plain. Proves only that
 *                          the sender knows it.
 * The relay verifies the signature whenever that header is present and falls
 * back to comparing the token header otherwise; either passing accepts the
 * delivery. (The signed timestamp is part of the MAC, but its freshness is
 * not enforced here.)
 *
 * Vars (wrangler.toml):  GITHUB_REPO, ENABLED_HANDLERS, WATCHED_PIPELINE
 * Secrets:  GITHUB_PAT, BUILDKITE_WEBHOOK_SECRET
 */

async function validAuth(secret, request, rawBody) {
  if (!secret) return false;

  const signature = request.headers.get('x-buildkite-signature');
  if (signature) {
    // "timestamp=1619071700,signature=30e02f26…" — parse key=value pairs.
    const parts = {};
    for (const kv of signature.split(',')) {
      const idx = kv.indexOf('=');
      if (idx > 0) parts[kv.slice(0, idx).trim()] = kv.slice(idx + 1).trim();
    }
    if (!parts.timestamp || !parts.signature) return false;
    const key = await crypto.subtle.importKey(
      'raw', new TextEncoder().encode(secret),
      { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
    );
    const mac = await crypto.subtle.sign(
      'HMAC', key, new TextEncoder().encode(`${parts.timestamp}.${rawBody}`),
    );
    const hex = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, '0')).join('');
    return hex === parts.signature;
  }

  const token = request.headers.get('x-buildkite-token');
  return Boolean(token) && token === secret;
}

export default {
  async fetch(request, env) {
    if (request.method !== 'POST') {
      return new Response('method not allowed', { status: 405 });
    }

    const rawBody = await request.text();
    const ok = await validAuth(env.BUILDKITE_WEBHOOK_SECRET, request, rawBody);
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
     * Only failed builds wake the agent. build.scheduled / running / passed
     * are noise for this recipe — acknowledged and dropped. (A future ship
     * handler could forward build.passed to a notify recipe.)
     */
    if (event.event !== 'build.failed') {
      return new Response(`ignored: no route for ${event.event || 'unknown'}`, { status: 200 });
    }

    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!enabled.includes('builds')) {
      return new Response('ignored: builds handler disabled', { status: 200 });
    }

    const buildNumber = event.build?.number;
    if (buildNumber === undefined || buildNumber === null || buildNumber === '') {
      return new Response('ignored: no build number in payload', { status: 200 });
    }

    // Optional pipeline scoping — fail open when the payload omits the pipeline.
    const pipelineSlug = event.pipeline?.slug || '';
    if (env.WATCHED_PIPELINE && pipelineSlug && pipelineSlug !== env.WATCHED_PIPELINE) {
      return new Response('ignored: build outside the watched pipeline', { status: 200 });
    }

    const resp = await fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/dispatches`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.GITHUB_PAT}`,
        Accept: 'application/vnd.github+json',
        'User-Agent': 'ai-automations-buildkite-relay',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        event_type: 'buildkite_event',
        client_payload: {
          kind: 'build-failed',
          item_id: String(buildNumber),
          item_type: 'Build',
          recording_type: 'builds',
        },
      }),
    });

    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
