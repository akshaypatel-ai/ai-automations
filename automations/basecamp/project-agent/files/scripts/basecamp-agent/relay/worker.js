/**
 * Basecamp → GitHub Actions relay (Cloudflare Worker).
 *
 * Basecamp webhooks cannot send the Authorization header GitHub's API needs,
 * so this Worker receives the webhook, filters it to events an enabled
 * handler can act on, and forwards a trimmed payload as a repository_dispatch.
 *
 * Vars (wrangler.toml):  GITHUB_REPO, BUCKET_ID, ENABLED_HANDLERS,
 *                        WATCHED_COLUMNS, WATCHED_TODOLIST, AGENT_MARKER
 * Secrets (wrangler secret put):  GITHUB_PAT, WEBHOOK_SECRET
 */

/** Recording type → handler family (comments route via their parent's type). */
const HANDLER_FOR = {
  'Kanban::Card': 'cards',
  'Todo': 'todos',
  'Todolist': 'todos',
  'Message': 'messages',
  'Document': 'docs',
  'Upload': 'docs',
  'Vault': 'docs',
  'Question': 'checkins',
  'Question::Answer': 'checkins',
  'Schedule::Entry': 'schedule',
};

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

    const recording = event.recording || {};
    if (String(recording.bucket?.id ?? '') !== String(env.BUCKET_ID)) {
      return new Response('ignored: other bucket', { status: 200 });
    }

    const type = recording.type || '';
    const isComment = type === 'Comment';
    const itemType = isComment ? (recording.parent?.type || '') : type;
    const itemId = isComment ? recording.parent?.id : recording.id;

    const handler = HANDLER_FOR[itemType];
    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!handler || !enabled.includes(handler)) {
      return new Response('ignored: no enabled handler for ' + (itemType || 'unknown'), { status: 200 });
    }

    /**
     * Card moves to unwatched columns (Done, Ready for review, …) never
     * produce work — skip the Actions run. Fail open when the column is
     * missing from the payload.
     */
    const watched = (env.WATCHED_COLUMNS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (itemType === 'Kanban::Card' && !isComment && watched.length) {
      const cardColumn = String(recording.parent?.id ?? '');
      if (cardColumn && !watched.includes(cardColumn)) {
        return new Response('ignored: unwatched column', { status: 200 });
      }
    }

    /** Optional todolist scoping (comment events pass through — the resolver re-checks). */
    if (itemType === 'Todo' && !isComment && env.WATCHED_TODOLIST) {
      const list = String(recording.parent?.id ?? '');
      if (list && list !== String(env.WATCHED_TODOLIST)) {
        return new Response('ignored: unwatched todolist', { status: 200 });
      }
    }

    /**
     * The agent's own comments echo straight back as webhooks; the marker
     * near the top of the tag-stripped body identifies them (mirrors
     * resolve-item.sh).
     */
    if (isComment && env.AGENT_MARKER) {
      const stripped = String(recording.content || '').replace(/<[^>]*>/g, '').slice(0, 120);
      if (stripped.includes(env.AGENT_MARKER)) {
        return new Response('ignored: agent comment echo', { status: 200 });
      }
    }

    const resp = await fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/dispatches`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.GITHUB_PAT}`,
        Accept: 'application/vnd.github+json',
        'User-Agent': 'ai-automations-basecamp-relay',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        event_type: 'basecamp_event',
        client_payload: {
          kind: event.kind || '',
          item_id: itemId,
          item_type: itemType,
          recording_id: recording.id,
          recording_type: type,
          creator_name: event.creator?.name || '',
        },
      }),
    });

    /** Non-2xx makes Basecamp retry the webhook later — desired on GitHub hiccups. */
    if (!resp.ok) {
      return new Response(`github dispatch failed: ${resp.status}`, { status: 502 });
    }
    return new Response('dispatched', { status: 200 });
  },
};
