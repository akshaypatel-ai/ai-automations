/**
 * Microsoft Teams outgoing webhook → GitHub Actions relay (Cloudflare Worker).
 * Only needed for the optional `ask` handler — ship/incident are
 * GitHub-native and never touch this worker.
 *
 * Teams' outgoing-webhook contract:
 *  - every POST carries "Authorization: HMAC <base64>" — HMAC-SHA256 of the
 *    raw body, keyed with the base64-DECODED security token shown at creation.
 *  - the reply must be synchronous, within ~5 seconds, {"type":"message",...}.
 *    A CI run can't make that window, so the relay acknowledges immediately
 *    and CI posts the real answer to the channel via the notify webhook.
 *
 * Vars (wrangler.toml):  GITHUB_REPO
 * Secrets:  GITHUB_PAT, TEAMS_SECURITY_TOKEN (base64, as shown by Teams)
 */

async function validSignature(tokenB64, rawBodyBytes, header) {
  if (!header || !header.startsWith('HMAC ')) return false;
  try {
    const keyBytes = Uint8Array.from(atob(tokenB64), (c) => c.charCodeAt(0));
    const key = await crypto.subtle.importKey(
      'raw', keyBytes, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
    );
    const mac = await crypto.subtle.sign('HMAC', key, rawBodyBytes);
    const b64 = btoa(String.fromCharCode(...new Uint8Array(mac)));
    return b64 === header.slice(5).trim();
  } catch {
    return false;
  }
}

/** Teams sends HTML-ish text with the bot mention inline — reduce to the question. */
function extractQuestion(text) {
  return (text || '')
    .replace(/<at>.*?<\/at>/g, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

const reply = (text) => new Response(JSON.stringify({ type: 'message', text }), {
  status: 200, headers: { 'Content-Type': 'application/json' },
});

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
      'User-Agent': 'ai-automations-teams-relay',
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

    const rawBuffer = await request.arrayBuffer();
    const ok = await validSignature(
      env.TEAMS_SECURITY_TOKEN, rawBuffer, request.headers.get('authorization'),
    );
    if (!ok) {
      return new Response('bad signature', { status: 401 });
    }

    let body;
    try {
      body = JSON.parse(new TextDecoder().decode(rawBuffer));
    } catch {
      return new Response('bad json', { status: 400 });
    }

    const question = extractQuestion(body.text);
    if (!question) {
      return reply('Ask me something — mention me followed by your question.');
    }

    const dispatched = dispatch(env, 'teams_event', { kind: 'ask', text: question.slice(0, 1500) });
    // Outgoing webhooks only allow this one synchronous reply — the real
    // answer arrives in the channel via the notify webhook.
    ctx.waitUntil(dispatched);
    return reply('🤖 On it — I\'ll post the answer in this channel in a minute or two.');
  },
};
