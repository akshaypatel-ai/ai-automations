/**
 * Mattermost outgoing webhook → GitHub Actions relay (Cloudflare Worker).
 * Only needed for the optional `ask` handler — ship/incident are
 * GitHub-native and never touch this worker.
 *
 * Mattermost's outgoing-webhook contract:
 *  - fires when a message in the configured PUBLIC channel starts with the
 *    trigger word (outgoing webhooks don't work in private channels/DMs).
 *  - delivery is application/x-www-form-urlencoded by default; JSON is a
 *    per-webhook option — so the relay parses BOTH by content-type.
 *  - verification is the `token` field vs the secret Mattermost shows at
 *    creation — a plain constant compare, no HMAC (that's all Mattermost
 *    offers; keep the callback URL private too).
 *  - the immediate HTTP response {"text": ...} posts straight back to the
 *    channel. A CI run can't answer that fast, so the relay acks "on it"
 *    and CI posts the real answer via the incoming (notify) webhook.
 *
 * Vars (wrangler.toml):  GITHUB_REPO, TRIGGER, AGENT_MARKER
 * Secrets:  GITHUB_PAT, MATTERMOST_OUTGOING_TOKEN
 */

const reply = (text) => new Response(
  JSON.stringify({ text, response_type: 'in_channel' }),
  { status: 200, headers: { 'Content-Type': 'application/json' } },
);

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
      'User-Agent': 'ai-automations-mattermost-relay',
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

    const raw = await request.text();
    const contentType = request.headers.get('content-type') || '';
    let body;
    try {
      body = contentType.includes('application/json')
        ? JSON.parse(raw)
        : Object.fromEntries(new URLSearchParams(raw));
    } catch {
      return new Response('bad body', { status: 400 });
    }
    if (!body || typeof body !== 'object') {
      return new Response('bad body', { status: 400 });
    }

    // Token check — Mattermost's only verification. Unset env fails closed.
    if (!env.MATTERMOST_OUTGOING_TOKEN || body.token !== env.MATTERMOST_OUTGOING_TOKEN) {
      return new Response('bad token', { status: 401 });
    }

    const text = String(body.text || '');
    const userName = String(body.user_name || '');

    // Bot-loop protection is structural — Mattermost never fires outgoing
    // webhooks for webhook-created posts — but drop our own voice defensively.
    const marker = env.AGENT_MARKER || '';
    if (marker && (userName === marker || text.includes(marker))) {
      return new Response(null, { status: 200 });
    }

    // Strip the leading trigger word (Mattermost includes it in `text`) —
    // prefer the delivered trigger_word field, fall back to the configured one.
    const trigger = String(body.trigger_word || env.TRIGGER || '');
    let question = text.trim();
    if (trigger && question.toLowerCase().startsWith(trigger.toLowerCase())) {
      question = question.slice(trigger.length).trim();
    }
    if (!question) {
      return reply('Ask me something — the trigger word followed by your question.');
    }

    const dispatched = dispatch(env, 'mattermost_event', { kind: 'ask', text: question.slice(0, 1500) });
    // The immediate response is the only synchronous reply — the real answer
    // arrives in the channel via the incoming (notify) webhook.
    ctx.waitUntil(dispatched);
    return reply('🤖 On it — I\'ll post the answer in this channel in a minute or two.');
  },
};
