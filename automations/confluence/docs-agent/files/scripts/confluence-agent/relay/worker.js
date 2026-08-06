/**
 * Confluence → GitHub Actions relay (Cloudflare Worker).
 *
 * Confluence Cloud has no admin-configurable webhooks (that's a Connect/Forge
 * app feature), so the doorbell is a Confluence Automation rule (Premium+)
 * whose "Send web request" action POSTs here. Those requests carry no
 * portable HMAC, so authentication is the secret embedded in the URL path —
 * same model as the monday recipe. The rule's JSON body you define at setup:
 *   {"page_id": "{{page.id}}", "event": "label-added" | "comment-added"}
 *
 * Vars (wrangler.toml):  GITHUB_REPO, ENABLED_HANDLERS
 * Secrets (wrangler secret put):  GITHUB_PAT, WEBHOOK_SECRET
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
    const headers = { 'Content-Type': 'application/json', 'User-Agent': 'ai-automations-confluence-relay' };
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
      'User-Agent': 'ai-automations-confluence-relay',
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

    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!enabled.includes('pages')) {
      return new Response('ignored: pages handler disabled', { status: 200 });
    }

    const pageId = body.page_id || '';
    if (!pageId) {
      return new Response('ignored: no page id (the Automation web-request body must include page_id)', { status: 200 });
    }

    const resp = await dispatch(env, 'confluence_event', {
      kind: body.event || 'page-event',
      item_id: String(pageId),
      item_type: 'Page',
      recording_type: 'pages',
    });

    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
