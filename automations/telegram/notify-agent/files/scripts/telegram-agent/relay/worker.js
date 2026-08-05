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

    const dispatch = fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/dispatches`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.GITHUB_PAT}`,
        Accept: 'application/vnd.github+json',
        'User-Agent': 'ai-automations-telegram-relay',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        event_type: 'telegram_event',
        client_payload: {
          kind: 'ask',
          text: text.slice(0, 1500),
          chat_id: chatId,
        },
      }),
    });
    // Ack fast — Telegram retries non-200 deliveries; the answer arrives
    // later in the chat as a sendMessage push from CI.
    ctx.waitUntil(dispatch);
    return new Response('ok', { status: 200 });
  },
};
