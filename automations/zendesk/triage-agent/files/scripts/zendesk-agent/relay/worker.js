/**
 * Zendesk → GitHub Actions relay (Cloudflare Worker).
 *
 * Zendesk webhooks sign every delivery: X-Zendesk-Webhook-Signature =
 * base64 HMAC-SHA256 of (timestamp + body), keyed with the webhook's signing
 * secret; the timestamp rides in X-Zendesk-Webhook-Signature-Timestamp.
 *
 * The webhook is fed by Zendesk TRIGGERS whose JSON body you define at setup:
 *   {"ticket_id": "{{ticket.id}}", "event": "created" | "commented"}
 *
 * Vars (wrangler.toml):  GITHUB_REPO, ENABLED_HANDLERS
 * Secrets:  GITHUB_PAT, ZENDESK_WEBHOOK_SECRET
 */

async function validSignature(secret, timestamp, rawBody, header) {
  if (!header || !timestamp) return false;
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(timestamp + rawBody));
  const b64 = btoa(String.fromCharCode(...new Uint8Array(mac)));
  return b64 === header;
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
      'User-Agent': 'ai-automations-zendesk-relay',
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
      env.ZENDESK_WEBHOOK_SECRET,
      request.headers.get('x-zendesk-webhook-signature-timestamp'),
      rawBody,
      request.headers.get('x-zendesk-webhook-signature'),
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

    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!enabled.includes('tickets')) {
      return new Response('ignored: tickets handler disabled', { status: 200 });
    }

    const ticketId = event.ticket_id || '';
    if (!ticketId) {
      return new Response('ignored: no ticket id (check the trigger JSON body)', { status: 200 });
    }

    const resp = await dispatch(env, 'zendesk_event', {
      kind: `ticket-${event.event || 'event'}`,
      item_id: String(ticketId),
      item_type: 'Ticket',
      recording_type: 'tickets',
    });

    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
