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
        event_type: 'line_event',
        client_payload: {
          kind: 'ask',
          text: String(ev.message.text || '').slice(0, 2000),
          target,
        },
      });
    }

    ctx.waitUntil(Promise.all(dispatches.map((d) =>
      fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/dispatches`, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${env.GITHUB_PAT}`,
          Accept: 'application/vnd.github+json',
          'User-Agent': 'ai-automations-line-relay',
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(d),
      }))));
    return new Response('ok', { status: 200 });
  },
};
