/**
 * Azure DevOps Boards → GitHub Actions relay (Cloudflare Worker).
 *
 * Azure DevOps service hooks don't sign payloads, so authentication is the
 * secret embedded in the URL path (like Jira/Basecamp). The subscription form
 * also offers optional Basic auth — layer it on as extra hardening if you
 * like; the URL secret is the baseline. The Worker filters to events an
 * enabled handler can act on and forwards a trimmed payload.
 *
 * Vars (wrangler.toml):  GITHUB_REPO, ENABLED_HANDLERS, AGENT_MARKER
 * Secrets (wrangler secret put):  GITHUB_PAT, WEBHOOK_SECRET
 */

/** eventType prefix → handler family. */
function handlerFor(eventType) {
  if (eventType.startsWith('workitem.')) return 'workitems';
  return null;
}

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
    const headers = { 'Content-Type': 'application/json', 'User-Agent': 'ai-automations-azdo-relay' };
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
      'User-Agent': 'ai-automations-azdo-relay',
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

    let event;
    try {
      event = await request.json();
    } catch {
      return new Response('bad json', { status: 400 });
    }

    const eventType = event.eventType || '';
    const handler = handlerFor(eventType);
    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!handler || !enabled.includes(handler)) {
      return new Response('ignored: no enabled handler for ' + (eventType || 'unknown'), { status: 200 });
    }

    const resource = event.resource || {};

    /**
     * "Work item updated" fires on every field edit. The subscription's State
     * field filter should already drop non-state edits server-side — keep the
     * edge check for subscriptions created without it, and fail open when the
     * changed-fields map is absent.
     */
    if (eventType === 'workitem.updated' && resource.fields) {
      if (!('System.State' in resource.fields)) {
        return new Response('ignored: non-state work item edit', { status: 200 });
      }
    }

    /**
     * The agent's own comments echo back — the marker identifies them. The
     * commented payload carries the comment HTML in resource.fields
     * ["System.History"] (older shape) or resource.comment.text — check
     * defensively; absent text forwards (the resolver is the real guard).
     */
    if (eventType === 'workitem.commented' && env.AGENT_MARKER) {
      const text = String(resource.fields?.['System.History'] || resource.comment?.text || '');
      if (text && text.slice(0, 200).includes(env.AGENT_MARKER)) {
        return new Response('ignored: agent comment echo', { status: 200 });
      }
    }

    /** created/commented carry resource.id; updated carries resource.workItemId. */
    const itemId = resource.workItemId || resource.id || '';
    if (!itemId) {
      return new Response('ignored: no work item id', { status: 200 });
    }

    const resp = await dispatch(env, 'azdo_event', {
      kind: eventType,
      item_id: String(itemId),
      item_type: 'WorkItem',
      recording_type: 'workitems',
    });

    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
