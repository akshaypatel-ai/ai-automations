/**
 * Discord interactions → GitHub Actions relay (Cloudflare Worker).
 * Only needed for the optional /ask slash command — ship/incident are
 * GitHub-native and never touch this worker.
 *
 * Discord's interaction contract:
 *  - every request is signed with the app's Ed25519 key
 *    (X-Signature-Ed25519 + X-Signature-Timestamp over timestamp+body);
 *    unverified requests MUST get a 401 (Discord probes this at setup).
 *  - PING (type 1) → answer PONG {type: 1}.
 *  - slash command (type 2) → answer within 3s. The relay answers
 *    DEFERRED (type 5) immediately — "thinking…" — and wakes CI, which
 *    answers through the interaction's follow-up webhook (valid 15 min).
 *
 * Vars (wrangler.toml):  GITHUB_REPO
 * Secrets:  GITHUB_PAT, DISCORD_PUBLIC_KEY (app's public key, hex)
 */

function hexToBytes(hex) {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return bytes;
}

async function validSignature(publicKeyHex, signatureHex, timestamp, rawBody) {
  if (!publicKeyHex || !signatureHex || !timestamp) return false;
  try {
    const key = await crypto.subtle.importKey(
      'raw', hexToBytes(publicKeyHex), { name: 'Ed25519' }, false, ['verify'],
    );
    return await crypto.subtle.verify(
      'Ed25519', key, hexToBytes(signatureHex),
      new TextEncoder().encode(timestamp + rawBody),
    );
  } catch {
    return false;
  }
}

const json = (obj, status = 200) => new Response(JSON.stringify(obj), {
  status, headers: { 'Content-Type': 'application/json' },
});

export default {
  async fetch(request, env, ctx) {
    if (request.method !== 'POST') {
      return new Response('method not allowed', { status: 405 });
    }

    const rawBody = await request.text();
    const ok = await validSignature(
      env.DISCORD_PUBLIC_KEY,
      request.headers.get('x-signature-ed25519'),
      request.headers.get('x-signature-timestamp'),
      rawBody,
    );
    if (!ok) {
      return new Response('bad signature', { status: 401 });
    }

    let interaction;
    try {
      interaction = JSON.parse(rawBody);
    } catch {
      return new Response('bad json', { status: 400 });
    }

    // Endpoint verification ping.
    if (interaction.type === 1) {
      return json({ type: 1 });
    }

    // Slash command.
    if (interaction.type === 2 && interaction.data?.name === 'ask') {
      const question = (interaction.data.options || [])
        .find((o) => o.name === 'question')?.value || '';
      if (!question.trim()) {
        return json({ type: 4, data: { content: 'Ask me something: `/ask question:…`' } });
      }

      const dispatch = fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/dispatches`, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${env.GITHUB_PAT}`,
          Accept: 'application/vnd.github+json',
          'User-Agent': 'ai-automations-discord-relay',
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          event_type: 'discord_event',
          client_payload: {
            kind: 'ask',
            text: question.slice(0, 1500),
            app_id: interaction.application_id,
            interaction_token: interaction.token,
          },
        }),
      });
      // Answer DEFERRED within the 3s window; CI follows up via the
      // interaction webhook (valid 15 minutes).
      ctx.waitUntil(dispatch);
      return json({ type: 5 });
    }

    return json({ type: 4, data: { content: 'Unsupported interaction.' } });
  },
};
