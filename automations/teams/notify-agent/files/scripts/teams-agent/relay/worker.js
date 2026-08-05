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

    const dispatch = fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/dispatches`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.GITHUB_PAT}`,
        Accept: 'application/vnd.github+json',
        'User-Agent': 'ai-automations-teams-relay',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        event_type: 'teams_event',
        client_payload: { kind: 'ask', text: question.slice(0, 1500) },
      }),
    });
    // Outgoing webhooks only allow this one synchronous reply — the real
    // answer arrives in the channel via the notify webhook.
    ctx.waitUntil(dispatch);
    return reply('🤖 On it — I\'ll post the answer in this channel in a minute or two.');
  },
};
