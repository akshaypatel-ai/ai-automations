/**
 * Rocket.Chat outgoing webhook → GitHub Actions relay (Cloudflare Worker).
 * Only needed for the optional `ask` handler — ship/incident are
 * GitHub-native and never touch this worker.
 *
 * Rocket.Chat's outgoing-webhook contract:
 *  - fires when a message in the configured channel matches a trigger word
 *    (Admin → Integrations → Outgoing WebHook, event "Message Sent").
 *  - delivery is ALWAYS JSON: {token, channel_id, channel_name, user_id,
 *    user_name, text, trigger_word, bot} — no form-encoded mode to handle.
 *  - verification is the `token` field vs the Token you set in the webhook
 *    form — a plain constant compare, no HMAC (that's all Rocket.Chat
 *    offers; keep the callback URL private too).
 *  - the immediate HTTP response {"text": ...} posts straight back to the
 *    channel. A CI run can't answer that fast, so the relay acks "on it"
 *    and CI posts the real answer via the incoming (notify) webhook.
 *  - unlike Mattermost there is NO structural bot-loop protection: the
 *    server sets `bot` truthy on bot-authored messages, and depending on
 *    config an incoming-webhook post can re-trigger outgoing webhooks —
 *    so guard BOTH the bot flag and our own marker/alias.
 *
 * Vars (wrangler.toml):  GITHUB_REPO, TRIGGER, AGENT_MARKER
 * Secrets:  GITHUB_PAT, ROCKETCHAT_OUTGOING_TOKEN
 */

const reply = (text) => new Response(
  JSON.stringify({ text }),
  { status: 200, headers: { 'Content-Type': 'application/json' } },
);

export default {
  async fetch(request, env, ctx) {
    if (request.method !== 'POST') {
      return new Response('method not allowed', { status: 405 });
    }

    let body;
    try {
      body = JSON.parse(await request.text());
    } catch {
      return new Response('bad body', { status: 400 });
    }
    if (!body || typeof body !== 'object') {
      return new Response('bad body', { status: 400 });
    }

    // Token check — Rocket.Chat's only verification. Unset env fails closed.
    if (!env.ROCKETCHAT_OUTGOING_TOKEN || body.token !== env.ROCKETCHAT_OUTGOING_TOKEN) {
      return new Response('bad token', { status: 401 });
    }

    const text = String(body.text || '');
    const userName = String(body.user_name || '');

    // Bot-loop guard #1 — Rocket.Chat sets `bot` truthy on bot-authored
    // messages (incoming-webhook posts included on some server configs).
    if (body.bot) {
      return new Response(null, { status: 200 });
    }

    // Bot-loop guard #2 — drop our own voice: posts under the agent's alias
    // or quoting its marker never become questions.
    const marker = env.AGENT_MARKER || '';
    if (marker && (userName === marker || text.includes(marker))) {
      return new Response(null, { status: 200 });
    }

    // Strip the leading trigger word (Rocket.Chat includes it in `text`) —
    // prefer the delivered trigger_word field, fall back to the configured one.
    const trigger = String(body.trigger_word || env.TRIGGER || '');
    let question = text.trim();
    if (trigger && question.toLowerCase().startsWith(trigger.toLowerCase())) {
      question = question.slice(trigger.length).trim();
    }
    if (!question) {
      return reply(`Ask me something — ${trigger || 'the trigger word'} your question.`);
    }

    const dispatch = fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/dispatches`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.GITHUB_PAT}`,
        Accept: 'application/vnd.github+json',
        'User-Agent': 'ai-automations-rocketchat-relay',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        event_type: 'rocketchat_event',
        client_payload: { kind: 'ask', text: question.slice(0, 1500) },
      }),
    });
    // The immediate response is the only synchronous reply — the real answer
    // arrives in the channel via the incoming (notify) webhook.
    ctx.waitUntil(dispatch);
    return reply('🤖 On it — I\'ll post the answer in this channel in a minute or two.');
  },
};
