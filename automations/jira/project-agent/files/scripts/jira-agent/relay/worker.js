/**
 * Jira Cloud → GitHub Actions relay (Cloudflare Worker).
 *
 * Jira's admin-registered webhooks don't sign payloads, so authentication is
 * the secret embedded in the URL path (like Basecamp). The Worker filters to
 * events an enabled handler can act on and forwards a trimmed payload.
 *
 * Vars (wrangler.toml):  GITHUB_REPO, ENABLED_HANDLERS, PROJECT_KEY,
 *                        WATCHED_STATUSES, AGENT_MARKER
 * Secrets (wrangler secret put):  GITHUB_PAT, WEBHOOK_SECRET
 */

/** webhookEvent prefix → handler family. */
function handlerFor(webhookEvent) {
  if (webhookEvent.startsWith('jira:issue') || webhookEvent.startsWith('comment')) return 'issues';
  if (webhookEvent.startsWith('sprint')) return 'sprints';
  if (webhookEvent.startsWith('jira:version')) return 'versions';
  if (webhookEvent.startsWith('worklog')) return 'worklogs';
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
      'User-Agent': 'ai-automations-jira-relay',
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

    const webhookEvent = event.webhookEvent || '';
    const handler = handlerFor(webhookEvent);
    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!handler || !enabled.includes(handler)) {
      return new Response('ignored: no enabled handler for ' + (webhookEvent || 'unknown'), { status: 200 });
    }

    const issue = event.issue || {};
    if (env.PROJECT_KEY && issue.fields?.project?.key && issue.fields.project.key !== env.PROJECT_KEY) {
      return new Response('ignored: other project', { status: 200 });
    }

    /**
     * Issue updates fire on every field edit. Only status transitions into a
     * watched status (or creation in one) can produce work — comments arrive
     * as their own events. Fail open when the changelog is missing.
     */
    const watched = (env.WATCHED_STATUSES || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (handler === 'issues' && watched.length) {
      if (webhookEvent === 'jira:issue_updated') {
        const statusChange = (event.changelog?.items || []).find((i) => i.field === 'status');
        if (!statusChange && !event.comment) {
          return new Response('ignored: non-status issue edit', { status: 200 });
        }
        if (statusChange && !watched.includes(statusChange.toString)) {
          return new Response('ignored: unwatched status', { status: 200 });
        }
      }
      if (webhookEvent === 'jira:issue_created') {
        const statusName = issue.fields?.status?.name || '';
        if (statusName && !watched.includes(statusName)) {
          return new Response('ignored: unwatched status', { status: 200 });
        }
      }
    }

    /** The agent's own comments echo back — the marker identifies them. */
    if (event.comment && env.AGENT_MARKER) {
      if (String(event.comment.body || '').slice(0, 120).includes(env.AGENT_MARKER)) {
        return new Response('ignored: agent comment echo', { status: 200 });
      }
    }

    const itemId = issue.key || '';
    if (handler === 'issues' && !itemId) {
      return new Response('ignored: no issue key', { status: 200 });
    }

    const resp = await dispatch(env, 'jira_event', {
      kind: webhookEvent,
      item_id: itemId,
      item_type: 'Issue',
      recording_type: webhookEvent,
    });

    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
