/**
 * Asana → GitHub Actions relay (Cloudflare Worker).
 *
 * Two jobs Asana makes the relay do:
 *  1. Handshake — webhook creation sends X-Hook-Secret; echo it back AND log
 *     it (grab from `wrangler tail`, then `wrangler secret put ASANA_HOOK_SECRET`).
 *  2. Verify — every delivery carries X-Hook-Signature = hex HMAC-SHA256 of
 *     the body, keyed with that hook secret.
 *
 * Asana events are COMPACT (gid + action only, no content) and arrive in
 * batches — the relay dedupes and forwards one dispatch per unique item.
 *
 * Vars (wrangler.toml):  GITHUB_REPO, ENABLED_HANDLERS, WATCHED_PROJECT
 * Secrets:  GITHUB_PAT, ASANA_HOOK_SECRET
 */

/** event → handler family + the gid worth waking the agent for. */
function routeEvent(ev) {
  const type = ev.resource?.resource_type;
  if (type === 'task') return { family: 'tasks', gid: ev.resource.gid, itemType: 'Task' };
  if (type === 'story') return { family: 'tasks', gid: ev.parent?.gid, itemType: 'Task' };
  if (type === 'attachment') return { family: 'tasks', gid: ev.parent?.gid, itemType: 'Task' };
  if (type === 'section') return { family: 'sections', gid: ev.resource.gid, itemType: 'Section' };
  if (type === 'project') return { family: 'projects', gid: ev.resource.gid, itemType: 'Project' };
  return null;
}

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

export default {
  async fetch(request, env) {
    if (request.method !== 'POST') {
      return new Response('method not allowed', { status: 405 });
    }

    // Webhook-creation handshake: echo the secret back, and log it so the
    // operator can store it (`wrangler tail` shows this line).
    const handshake = request.headers.get('x-hook-secret');
    if (handshake) {
      console.log('ASANA HOOK SECRET (store it now: wrangler secret put ASANA_HOOK_SECRET):', handshake);
      return new Response('', { status: 200, headers: { 'X-Hook-Secret': handshake } });
    }

    if (!env.ASANA_HOOK_SECRET) {
      return new Response('hook secret not configured yet', { status: 401 });
    }
    const rawBody = await request.text();
    const ok = await validSignature(env.ASANA_HOOK_SECRET, rawBody, request.headers.get('x-hook-signature'));
    if (!ok) {
      return new Response('bad signature', { status: 401 });
    }

    let body;
    try {
      body = JSON.parse(rawBody);
    } catch {
      return new Response('bad json', { status: 400 });
    }

    const events = body.events || [];
    if (!events.length) {
      return new Response('heartbeat', { status: 200 });
    }

    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    const seen = new Set();
    const dispatches = [];
    for (const ev of events) {
      if (ev.action === 'deleted' || ev.action === 'removed') continue;
      const route = routeEvent(ev);
      if (!route || !route.gid) continue;
      if (!enabled.includes(route.family)) continue;
      const key = `${route.family}:${route.gid}`;
      if (seen.has(key)) continue;
      seen.add(key);
      dispatches.push({ ...route, action: ev.action });
    }

    if (!dispatches.length) {
      return new Response('ignored: no enabled handler events', { status: 200 });
    }

    // Cap per delivery — a reconcile run picks up anything beyond the cap.
    for (const d of dispatches.slice(0, 10)) {
      const resp = await fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/dispatches`, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${env.GITHUB_PAT}`,
          Accept: 'application/vnd.github+json',
          'User-Agent': 'ai-automations-asana-relay',
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          event_type: 'asana_event',
          client_payload: {
            kind: `${d.family}-${d.action}`,
            item_id: d.gid,
            item_type: d.itemType,
            recording_type: d.family,
          },
        }),
      });
      if (!resp.ok) {
        return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
      }
    }
    return new Response(`dispatched ${Math.min(dispatches.length, 10)}`, { status: 200 });
  },
};
