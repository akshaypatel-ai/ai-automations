/**
 * PagerDuty → GitHub Actions relay (Cloudflare Worker).
 *
 * Fed by a PagerDuty V3 WEBHOOK SUBSCRIPTION (Integrations → Generic Webhooks
 * (v3)) pointed at this worker, subscribed to incident.triggered,
 * incident.reopened, and incident.escalated. The signing secret is shown ONCE
 * when the subscription is created.
 *
 * Every delivery is signed: X-PagerDuty-Signature is a comma-separated list
 * ("v1=<hex>,v1=<hex>" — one entry per active secret, so rotation overlaps);
 * the delivery is authentic when ANY entry equals the hex HMAC-SHA256 of the
 * raw body.
 *
 * Vars (wrangler.toml):  GITHUB_REPO, ENABLED_HANDLERS
 * Secrets:  GITHUB_PAT, PAGERDUTY_WEBHOOK_SECRET
 */

/**
 * Incident events that reach the subscription but must never wake the agent.
 * incident.annotated is loop protection — the agent's own notes echo back as
 * annotated events. The rest are responder actions: the agent has nothing to
 * add when humans acknowledge, assign, or resolve.
 */
const NOISY = new Set([
  'incident.annotated',
  'incident.acknowledged',
  'incident.unacknowledged',
  'incident.assigned',
  'incident.delegated',
  'incident.resolved',
  'incident.status_update_published',
  'incident.priority_updated',
]);

async function validSignature(secret, rawBody, header) {
  if (!header) return false;
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(rawBody));
  const hex = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, '0')).join('');
  return header.split(',')
    .map((s) => s.trim())
    .filter((s) => s.startsWith('v1='))
    .some((s) => s.slice(3) === hex);
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
      'User-Agent': 'ai-automations-pagerduty-relay',
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
    const ok = await validSignature(env.PAGERDUTY_WEBHOOK_SECRET, rawBody, request.headers.get('x-pagerduty-signature'));
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
     * Routes that wake the agent: incident.triggered / incident.reopened /
     * incident.escalated (plus any future incident.* the subscription sends —
     * the resolver re-reads truth and dedupes, so extra doorbells are safe).
     */
    const eventType = event.event?.event_type || '';
    if (!eventType.startsWith('incident.')) {
      return new Response(`ignored: no route for ${eventType || 'unknown'}`, { status: 200 });
    }
    if (NOISY.has(eventType)) {
      return new Response(`ignored: noisy event ${eventType}`, { status: 200 });
    }

    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!enabled.includes('incidents')) {
      return new Response('ignored: incidents handler disabled', { status: 200 });
    }

    const incidentId = event.event?.data?.id || '';
    if (!incidentId) {
      return new Response('ignored: no incident id in payload', { status: 200 });
    }

    const resp = await dispatch(env, 'pagerduty_event', {
      kind: eventType,
      item_id: String(incidentId),
      item_type: 'Incident',
      recording_type: 'incidents',
    });

    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
