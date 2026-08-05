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

    const resp = await fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/dispatches`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.GITHUB_PAT}`,
        Accept: 'application/vnd.github+json',
        'User-Agent': 'ai-automations-jira-relay',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        event_type: 'jira_event',
        client_payload: {
          kind: webhookEvent,
          item_id: itemId,
          item_type: 'Issue',
          recording_type: webhookEvent,
        },
      }),
    });

    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
