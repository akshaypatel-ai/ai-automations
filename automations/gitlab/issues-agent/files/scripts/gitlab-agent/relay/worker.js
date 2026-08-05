/**
 * GitLab → GitHub Actions relay (Cloudflare Worker).
 *
 * GitLab webhooks aren't HMAC-signed: every delivery carries the Secret token
 * from the webhook form verbatim in the X-Gitlab-Token header, so a plain
 * full-string compare against GITLAB_WEBHOOK_TOKEN authenticates it. The
 * Worker filters to events an enabled handler can act on and forwards a
 * trimmed payload.
 *
 * Vars (wrangler.toml):  GITHUB_REPO, ENABLED_HANDLERS, WATCHED_LABELS, AGENT_MARKER
 * Secrets (wrangler secret put):  GITHUB_PAT, GITLAB_WEBHOOK_TOKEN
 */

/** object_kind → handler family. */
function handlerFor(objectKind) {
  if (objectKind === 'issue' || objectKind === 'note') return 'issues';
  return null;
}

export default {
  async fetch(request, env) {
    if (request.method !== 'POST') {
      return new Response('method not allowed', { status: 405 });
    }

    if (request.headers.get('x-gitlab-token') !== env.GITLAB_WEBHOOK_TOKEN) {
      return new Response('bad token', { status: 401 });
    }

    let event;
    try {
      event = await request.json();
    } catch {
      return new Response('bad json', { status: 400 });
    }

    const objectKind = event.object_kind || '';
    const handler = handlerFor(objectKind);
    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!handler || !enabled.includes(handler)) {
      return new Response('ignored: no enabled handler for ' + (objectKind || 'unknown'), { status: 200 });
    }

    const attrs = event.object_attributes || {};
    let iid = '';
    let action = '';

    if (objectKind === 'issue') {
      action = attrs.action || '';
      if (action === 'close') {
        return new Response('ignored: issue closed', { status: 200 });
      }
      /**
       * Issue hooks fire on every field edit. The payload's labels array is
       * the state AFTER the change, so only issues currently carrying a
       * watched label can produce work — label applications pass, everything
       * else is noise.
       */
      const watched = (env.WATCHED_LABELS || '').split(',').map((s) => s.trim()).filter(Boolean);
      const labels = (attrs.labels || []).map((l) => l.title);
      if (watched.length && !labels.some((l) => watched.includes(l))) {
        return new Response('ignored: no watched label', { status: 200 });
      }
      iid = attrs.iid;
    } else {
      if (attrs.noteable_type !== 'Issue') {
        return new Response('ignored: note on ' + (attrs.noteable_type || 'unknown'), { status: 200 });
      }
      /** The agent's own comments echo back — the marker identifies them. */
      if (env.AGENT_MARKER && String(attrs.note || '').startsWith(env.AGENT_MARKER)) {
        return new Response('ignored: agent comment echo', { status: 200 });
      }
      iid = event.issue?.iid;
    }

    if (!iid) {
      return new Response('ignored: no issue iid', { status: 200 });
    }

    const resp = await fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/dispatches`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.GITHUB_PAT}`,
        Accept: 'application/vnd.github+json',
        'User-Agent': 'ai-automations-gitlab-relay',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        event_type: 'gitlab_event',
        client_payload: {
          kind: `${objectKind}-${action || 'event'}`,
          item_id: String(iid),
          item_type: 'Issue',
          recording_type: 'issues',
        },
      }),
    });

    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
