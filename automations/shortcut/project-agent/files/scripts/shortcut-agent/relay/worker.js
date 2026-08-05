/**
 * Shortcut → GitHub Actions relay (Cloudflare Worker).
 *
 * Verifies Shortcut's HMAC-SHA256 webhook signature (Payload-Signature header,
 * hex, keyed with the secret you set in the webhook form — the relay REQUIRES
 * it), routes the delivery's batched actions to enabled handler families,
 * dedupes ids across the batch, and forwards one repository_dispatch per
 * unique item (capped — a reconcile run picks up anything beyond the cap).
 *
 * Vars (wrangler.toml):  GITHUB_REPO, ENABLED_HANDLERS, AGENT_MARKER
 * Secrets:  GITHUB_PAT, SHORTCUT_WEBHOOK_SECRET
 */

/** entity type → handler family. */
function handlerFor(entityType) {
  if (entityType === 'story' || entityType === 'story-comment') return 'stories';
  if (entityType.startsWith('epic')) return 'epics';
  if (entityType.startsWith('iteration')) return 'iterations';
  return null; // tasks, labels, members, … — never wake the agent
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

    if (!env.SHORTCUT_WEBHOOK_SECRET) {
      return new Response('webhook secret not configured yet', { status: 401 });
    }
    const rawBody = await request.text();
    const ok = await validSignature(env.SHORTCUT_WEBHOOK_SECRET, rawBody, request.headers.get('payload-signature'));
    if (!ok) {
      return new Response('bad signature', { status: 401 });
    }

    let body;
    try {
      body = JSON.parse(rawBody);
    } catch {
      return new Response('bad json', { status: 400 });
    }

    const actions = body.actions || [];
    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    const seen = new Set();
    const dispatches = [];
    for (const action of actions) {
      const entityType = action.entity_type || '';
      const family = handlerFor(entityType);
      if (!family || !enabled.includes(family)) continue;

      let id = null;
      let itemType = 'Story';
      if (entityType === 'story') {
        if (action.action === 'create') {
          id = action.id;
        } else if (action.action === 'update') {
          // Only workflow-state moves matter; other field edits are noise.
          if (!action.changes || !('workflow_state_id' in action.changes)) continue;
          id = action.id;
        } else {
          continue; // deletes etc. never produce work
        }
      } else if (entityType === 'story-comment') {
        if (action.action !== 'create') continue;
        // The agent's own comments echo back — the marker identifies them.
        if (env.AGENT_MARKER && (action.text || '').slice(0, 200).includes(env.AGENT_MARKER)) continue;
        if (!action.story_id) continue; // no parent story to wake
        id = action.story_id;
      } else {
        // epics/iterations: routed for future handlers; inert until enabled.
        id = action.id;
        itemType = family === 'epics' ? 'Epic' : 'Iteration';
      }
      if (id == null) continue;

      const key = `${family}:${id}`;
      if (seen.has(key)) continue;
      seen.add(key);
      dispatches.push({ family, id: String(id), itemType, kind: `${entityType}-${action.action}` });
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
          'User-Agent': 'ai-automations-shortcut-relay',
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          event_type: 'shortcut_event',
          client_payload: {
            kind: d.kind,
            item_id: d.id,
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
