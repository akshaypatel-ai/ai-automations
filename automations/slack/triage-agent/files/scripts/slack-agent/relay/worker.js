/**
 * Slack Events API → GitHub Actions relay (Cloudflare Worker).
 *
 * Slack-specific requirements handled here:
 *  - URL verification handshake (echoes the challenge on subscription).
 *  - Signature verification: v0=HMAC-SHA256("v0:{ts}:{body}", signing secret),
 *    with ±5 min timestamp freshness.
 *  - 3-second ack: Slack retries unless answered fast — we ack immediately
 *    and dispatch to GitHub asynchronously via ctx.waitUntil.
 *  - Bot-loop protection is structural: bot messages are dropped by bot_id.
 *
 * Vars (wrangler.toml):  GITHUB_REPO, ENABLED_HANDLERS, WATCHED_CHANNELS, TRIGGER_EMOJI
 * Secrets:  GITHUB_PAT, SLACK_SIGNING_SECRET
 */

async function validSignature(secret, ts, rawBody, signature) {
  if (!signature || !ts) return false;
  if (Math.abs(Date.now() / 1000 - Number(ts)) > 300) return false;
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`v0:${ts}:${rawBody}`));
  const hex = 'v0=' + [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, '0')).join('');
  return hex === signature;
}

function route(ev, env) {
  const watched = (env.WATCHED_CHANNELS || '').split(',').map((s) => s.trim()).filter(Boolean);
  const emoji = (env.TRIGGER_EMOJI || '').split(',').map((s) => s.trim()).filter(Boolean);

  if (ev.bot_id || ev.subtype === 'bot_message') return null;

  if (ev.type === 'app_mention') {
    return { kind: 'mention', channel: ev.channel, root: ev.thread_ts || ev.ts };
  }
  if (ev.type === 'reaction_added' && emoji.includes(ev.reaction)) {
    return { kind: 'reaction', channel: ev.item?.channel, root: ev.item?.ts };
  }
  if (ev.type === 'message' && !ev.subtype) {
    if (ev.channel_type === 'im') {
      return { kind: 'dm', channel: ev.channel, root: ev.thread_ts || ev.ts };
    }
    if (watched.includes(ev.channel)) {
      return { kind: 'channel', channel: ev.channel, root: ev.thread_ts || ev.ts };
    }
  }
  return null;
}

const HANDLER_FOR = { mention: 'mentions', channel: 'channel', reaction: 'reactions', dm: 'dm' };

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
    const headers = { 'Content-Type': 'application/json', 'User-Agent': 'ai-automations-slack-relay' };
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
      'User-Agent': 'ai-automations-slack-relay',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ event_type: eventType, client_payload: clientPayload }),
  });
}

export default {
  async fetch(request, env, ctx) {
    if (request.method !== 'POST') {
      return new Response('method not allowed', { status: 405 });
    }

    const rawBody = await request.text();
    const ok = await validSignature(
      env.SLACK_SIGNING_SECRET,
      request.headers.get('x-slack-request-timestamp'),
      rawBody,
      request.headers.get('x-slack-signature'),
    );
    if (!ok) return new Response('bad signature', { status: 401 });

    let body;
    try {
      body = JSON.parse(rawBody);
    } catch {
      return new Response('bad json', { status: 400 });
    }

    /** Subscription handshake. */
    if (body.type === 'url_verification') {
      return new Response(body.challenge, { status: 200 });
    }
    if (body.type !== 'event_callback') {
      return new Response('ignored', { status: 200 });
    }

    /** Timeout-retries duplicate events we already dispatched — drop them. */
    if (request.headers.get('x-slack-retry-reason') === 'http_timeout') {
      return new Response('ignored: timeout retry', { status: 200 });
    }

    const target = route(body.event || {}, env);
    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!target || !target.channel || !target.root || !enabled.includes(HANDLER_FOR[target.kind])) {
      return new Response('ignored', { status: 200 });
    }

    /** Ack within 3s; deliver to GitHub after the response is sent. */
    ctx.waitUntil(dispatch(env, 'slack_event', {
      kind: target.kind,
      item_id: `${target.channel}:${target.root}`,
      item_type: 'Thread',
      recording_type: (body.event || {}).type || '',
    }));
    return new Response('ok', { status: 200 });
  },
};
