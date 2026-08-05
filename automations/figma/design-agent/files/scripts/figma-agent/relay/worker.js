/**
 * Figma webhook → GitHub Actions relay (Cloudflare Worker).
 *
 * Figma's webhook contract (v2):
 *  - deliveries are verified by the PASSCODE IN THE BODY: the passcode chosen
 *    at webhook creation comes back as body.passcode on every delivery. No
 *    HMAC, no signature header — so the passcode must be long and random
 *    (e.g. openssl rand -hex 24), and mismatches get a 401.
 *  - creating a webhook fires a PING event first — the webhook only goes
 *    healthy once it's answered 200 (handled here).
 *  - FILE_COMMENT payloads carry the comment as an ARRAY of text fragments
 *    (body.comment) — joined here before any gating.
 *  - Figma can't @mention a bot account, so a TRIGGER prefix (e.g. "@ai")
 *    is the summon. Comments without it are acked and dropped — this IS the
 *    noise gate; a busy design file never wakes CI.
 *  - no reply deadline: answers go out later as comment-thread replies from
 *    CI, so the relay just verifies, dispatches, and acks.
 *
 * Vars (wrangler.toml):  GITHUB_REPO, ENABLED_HANDLERS, TRIGGER,
 *                        AGENT_MARKER, WATCHED_FILE
 * Secrets:  GITHUB_PAT, FIGMA_PASSCODE (the webhook-creation passcode)
 */

export default {
  async fetch(request, env) {
    if (request.method !== 'POST') {
      return new Response('method not allowed', { status: 405 });
    }

    let body;
    try {
      body = await request.json();
    } catch {
      return new Response('bad json', { status: 400 });
    }

    // Figma's only verification: the creation passcode echoed in the body.
    if (!env.FIGMA_PASSCODE || body.passcode !== env.FIGMA_PASSCODE) {
      return new Response('bad passcode', { status: 401 });
    }

    // Webhook creation fires a PING first — answer it so the hook goes live.
    if (body.event_type === 'PING') {
      return new Response('pong', { status: 200 });
    }

    // Comments are the single routed family.
    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (body.event_type !== 'FILE_COMMENT' || !enabled.includes('comments')) {
      return new Response('ignored: not a routed event', { status: 200 });
    }

    // Comment text arrives as fragments — join before gating on it.
    const text = (body.comment || []).map((c) => c.text || '').join(' ').trim();

    // The summon: a trigger prefix, since Figma can't @mention a bot.
    // Case-insensitive — designers type "@AI" too.
    const trigger = String(env.TRIGGER || '').trim();
    if (!trigger) {
      return new Response('ignored: no trigger configured', { status: 200 });
    }
    if (!text.toLowerCase().startsWith(trigger.toLowerCase())) {
      return new Response('ignored: no trigger prefix', { status: 200 });
    }
    const question = text.slice(trigger.length).trim();
    if (!question) {
      return new Response('ignored: empty question', { status: 200 });
    }

    /**
     * Loop protection: replies are posted by the token owner's account, so
     * they come back through this webhook like any other comment — the
     * marker they always start with drops them here.
     */
    if (env.AGENT_MARKER && text.includes(env.AGENT_MARKER)) {
      return new Response('ignored: own reply', { status: 200 });
    }

    /** Scope to one file when configured — else every file the team emits. */
    if (env.WATCHED_FILE && body.file_key !== env.WATCHED_FILE) {
      return new Response('ignored: other file', { status: 200 });
    }

    // Replies carry parent_id = the thread's root; roots have it empty.
    // Either way this is the id CI must reply to.
    const rootId = String(body.parent_id || body.comment_id);

    const resp = await fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/dispatches`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.GITHUB_PAT}`,
        Accept: 'application/vnd.github+json',
        'User-Agent': 'ai-automations-figma-relay',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        event_type: 'figma_event',
        client_payload: {
          kind: 'ask',
          text: question.slice(0, 1500),
          file_key: body.file_key,
          root_id: rootId,
        },
      }),
    });

    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
