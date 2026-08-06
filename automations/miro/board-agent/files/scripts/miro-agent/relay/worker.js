/**
 * Miro webhook → GitHub Actions relay (Cloudflare Worker).
 *
 * Miro's webhook contract (v2-experimental board subscriptions):
 *  - the API is labeled EXPERIMENTAL — delivery shapes vary across versions,
 *    so every field below is extracted defensively.
 *  - there is NO delivery signature: the secret in the URL path is the whole
 *    authentication (same model as the monday/Basecamp recipes) — keep it
 *    long and random (e.g. openssl rand -hex 24); wrong path gets a 404
 *    before anything is parsed.
 *  - creating a subscription sends a challenge POST {"challenge": "…"} —
 *    echoed back as JSON (monday-style); the subscription only goes live
 *    once it's answered.
 *  - Miro's REST v2 has no usable board-comments API, so a STICKY NOTE
 *    carrying a TRIGGER prefix (e.g. "@ai") is the summon. Stickies without
 *    it are acked and dropped — this IS the noise gate; a busy board never
 *    wakes CI.
 *  - creates AND updates are forwarded: people often create an empty sticky
 *    and type into it, so the trigger usually ARRIVES on an update event.
 *    No dedupe is needed — the reply sticky starts with the marker and never
 *    carries the trigger, and a human editing their question sticky again
 *    SHOULD re-summon: that's a new question.
 *
 * Vars (wrangler.toml):  GITHUB_REPO, ENABLED_HANDLERS, TRIGGER,
 *                        AGENT_MARKER, WATCHED_BOARD
 * Secrets:  GITHUB_PAT, WEBHOOK_SECRET (the URL-path secret)
 */

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
      'User-Agent': 'ai-automations-miro-relay',
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

    // The URL secret is the only verification — the experimental API sends
    // no signature to check.
    const url = new URL(request.url);
    if (url.pathname !== `/hook/${env.WEBHOOK_SECRET}`) {
      return new Response('not found', { status: 404 });
    }

    let body;
    try {
      body = await request.json();
    } catch {
      return new Response('bad json', { status: 400 });
    }

    // Subscription-creation challenge: echo it back as JSON.
    if (body.challenge) {
      return new Response(JSON.stringify({ challenge: body.challenge }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    // Experimental API — extract defensively across the shapes it emits.
    const type = String(body.eventType || (body.event && body.event.type) || '');
    const event = body.event || {};
    const item = event.item || body.item || {};
    const boardId = event.boardId || body.boardId || '';

    // Stickies are the single routed family.
    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!enabled.includes('stickies')) {
      return new Response('ignored: handler disabled', { status: 200 });
    }
    if (item.type !== 'sticky_note') {
      return new Response('ignored: not a sticky note', { status: 200 });
    }
    if (type.toLowerCase().includes('delete')) {
      return new Response('ignored: deletion', { status: 200 });
    }
    if (!item.id) {
      return new Response('ignored: no item id', { status: 200 });
    }

    // Sticky content is HTML-ish ("<p>@ai …</p>") — strip tags before gating.
    const text = String((item.data && item.data.content) || '').replace(/<[^>]*>/g, ' ').trim();

    // The summon: a trigger prefix. Case-insensitive — people type "@AI" too.
    const trigger = String(env.TRIGGER || '').trim();
    if (!trigger) {
      return new Response('ignored: no trigger configured', { status: 200 });
    }
    if (!text.toLowerCase().startsWith(trigger.toLowerCase())) {
      return new Response('ignored: no trigger prefix', { status: 200 });
    }

    /**
     * Echo protection: the reply sticky the agent places comes back through
     * this webhook like any other item event — the marker it always starts
     * with drops it here (it never starts with the trigger either; belt and
     * braces).
     */
    if (env.AGENT_MARKER && text.includes(env.AGENT_MARKER)) {
      return new Response('ignored: own reply', { status: 200 });
    }

    /** Scope to the watched board — fail open when either side is absent. */
    if (env.WATCHED_BOARD && boardId && String(boardId) !== env.WATCHED_BOARD) {
      return new Response('ignored: other board', { status: 200 });
    }

    const question = text.slice(trigger.length).trim();
    if (!question) {
      return new Response('ignored: empty question', { status: 200 });
    }

    const resp = await dispatch(env, 'miro_event', {
      kind: 'ask',
      text: question.slice(0, 1500),
      item_id: String(item.id),
    });

    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
