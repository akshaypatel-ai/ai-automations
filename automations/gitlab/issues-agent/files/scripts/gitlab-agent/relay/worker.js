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
      'User-Agent': 'ai-automations-gitlab-relay',
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

    const resp = await dispatch(env, 'gitlab_event', {
      kind: `${objectKind}-${action || 'event'}`,
      item_id: String(iid),
      item_type: 'Issue',
      recording_type: 'issues',
    });

    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
