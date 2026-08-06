/**
 * Airtable → GitHub Actions relay (Cloudflare Worker).
 *
 * Airtable webhook notifications are THIN PINGS — {base: {id}, webhook: {id},
 * timestamp} with NO change details. Fetching details would mean Airtable's
 * two-step payloads-cursor API; the doorbell architecture makes that machinery
 * unnecessary. This worker verifies the ping's MAC and dispatches a RECONCILE
 * run (empty item_id) — the agent's reconcile scan finds whatever changed.
 * The doorbell pattern collapses Airtable's two-step webhook protocol into a
 * ping.
 *
 * MAC: header X-Airtable-Content-MAC = "hmac-sha256=<hex>" — HMAC-SHA256 of
 * the raw body, keyed with the base64-DECODED macSecretBase64 returned at
 * webhook creation (store the base64 string as-is; this worker decodes it).
 *
 * Vars (wrangler.toml):  GITHUB_REPO, WATCHED_BASE, ENABLED_HANDLERS
 * Secrets:  GITHUB_PAT, AIRTABLE_MAC_SECRET
 */

function base64ToBytes(b64) {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i += 1) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

async function validMac(secretBase64, rawBody, header) {
  if (!header || !header.startsWith('hmac-sha256=')) return false;
  const key = await crypto.subtle.importKey(
    'raw', base64ToBytes(secretBase64),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(rawBody));
  const hex = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, '0')).join('');
  return `hmac-sha256=${hex}` === header;
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
      'User-Agent': 'ai-automations-airtable-relay',
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
    const ok = await validMac(env.AIRTABLE_MAC_SECRET, rawBody, request.headers.get('x-airtable-content-mac'));
    if (!ok) {
      return new Response('bad mac', { status: 401 });
    }

    let ping;
    try {
      ping = JSON.parse(rawBody);
    } catch {
      return new Response('bad json', { status: 400 });
    }

    if (env.WATCHED_BASE && ping.base?.id && ping.base.id !== env.WATCHED_BASE) {
      return new Response('ignored: other base', { status: 200 });
    }

    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!enabled.includes('records')) {
      return new Response("ignored: handler 'records' disabled", { status: 200 });
    }

    const resp = await dispatch(env, 'airtable_event', {
      kind: 'ping',
      item_id: '',
      item_type: 'Record',
      recording_type: 'records',
    });

    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
