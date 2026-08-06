/**
 * Telegram bot webhook → GitHub Actions relay (Cloudflare Worker).
 * Only needed for the optional `ask` handler — ship/incident are
 * GitHub-native and never touch this worker.
 *
 * Telegram's webhook contract:
 *  - setWebhook is registered with a secret_token; every delivery carries it
 *    back in X-Telegram-Bot-Api-Secret-Token. A shared-secret header — same
 *    trust model as the Basecamp/Jira secret webhook URLs — compared in full
 *    here; mismatches get a 401.
 *  - no reply deadline at all: answers go out later as plain sendMessage
 *    pushes from CI (no token to expire), so the relay just acks 200 fast —
 *    simpler than Discord's 15-minute interaction tokens or Teams' 5-second
 *    synchronous reply.
 *
 * Vars (wrangler.toml):  GITHUB_REPO, WATCHED_CHAT
 * Secrets:  GITHUB_PAT, TELEGRAM_WEBHOOK_SECRET (the setWebhook secret_token)
 */

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
    const headers = { 'Content-Type': 'application/json', 'User-Agent': 'ai-automations-telegram-relay' };
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
      'User-Agent': 'ai-automations-telegram-relay',
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

    const secret = request.headers.get('x-telegram-bot-api-secret-token') || '';
    if (!env.TELEGRAM_WEBHOOK_SECRET || secret !== env.TELEGRAM_WEBHOOK_SECRET) {
      return new Response('bad secret', { status: 401 });
    }

    let update;
    try {
      update = await request.json();
    } catch {
      return new Response('bad json', { status: 400 });
    }

    // New messages only (group/DM `message`, channel `channel_post` — routed
    // the same). Edits and every other update kind never trigger the agent.
    const msg = update.message || update.channel_post;
    if (!msg) return new Response('ignored: not a message', { status: 200 });

    /** Loop protection: the agent's own pushes arrive from the bot itself. */
    if (msg.from?.is_bot) return new Response('ignored: bot message', { status: 200 });

    /** Scope to the configured chat when set — the bot answers only its home chat. */
    const chatId = String(msg.chat?.id ?? '');
    if (env.WATCHED_CHAT && chatId !== String(env.WATCHED_CHAT)) {
      return new Response('ignored: other chat', { status: 200 });
    }

    // With group privacy mode on (the default) the bot only sees messages
    // that mention it or reply to it — strip a leading @botname if present.
    const text = String(msg.text || '').replace(/^@\w+\s*/, '').trim();
    if (!text) return new Response('ignored: no text', { status: 200 });

    const dispatched = dispatch(env, 'telegram_event', {
      kind: 'ask',
      text: text.slice(0, 1500),
      chat_id: chatId,
    });
    // Ack fast — Telegram retries non-200 deliveries; the answer arrives
    // later in the chat as a sendMessage push from CI.
    ctx.waitUntil(dispatched);
    return new Response('ok', { status: 200 });
  },
};
