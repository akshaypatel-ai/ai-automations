/**
 * Sentry → GitHub Actions relay (Cloudflare Worker).
 *
 * Fed by a Sentry INTERNAL INTEGRATION (Settings → Developer Settings) whose
 * webhook URL points here, with "Alert Rule Action" enabled — issue alert
 * rules then add the action "Send a notification via <integration>".
 *
 * Every delivery is signed: sentry-hook-signature = hex HMAC-SHA256 of the
 * raw body, keyed with the integration's Client Secret. The
 * sentry-hook-resource header names the payload family
 * ("event_alert" | "issue" | "installation" | …).
 *
 * Vars (wrangler.toml):  GITHUB_REPO, ENABLED_HANDLERS
 * Secrets:  GITHUB_PAT, SENTRY_CLIENT_SECRET
 */

async function validSignature(secret, rawBody, signature) {
  if (!signature) return false;
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(rawBody));
  const hex = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, '0')).join('');
  return hex === signature;
}

export default {
  async fetch(request, env) {
    if (request.method !== 'POST') {
      return new Response('method not allowed', { status: 405 });
    }

    const rawBody = await request.text();
    const ok = await validSignature(env.SENTRY_CLIENT_SECRET, rawBody, request.headers.get('sentry-hook-signature'));
    if (!ok) {
      return new Response('bad signature', { status: 401 });
    }

    let event;
    try {
      event = JSON.parse(rawBody);
    } catch {
      return new Response('bad json', { status: 400 });
    }

    const resource = request.headers.get('sentry-hook-resource') || '';

    /** Sentry pings when the integration itself is installed/uninstalled. */
    if (resource === 'installation') {
      return new Response('ok', { status: 200 });
    }

    const enabled = (env.ENABLED_HANDLERS || '').split(',').map((s) => s.trim()).filter(Boolean);
    if (!enabled.includes('issues')) {
      return new Response('ignored: issues handler disabled', { status: 200 });
    }

    /**
     * Routes that wake the agent:
     *   event_alert              an issue alert rule fired → the event's parent issue
     *   issue (action: created)  a brand-new issue appeared
     * Everything else (resolved/assigned/ignored, comments, metric alerts) is
     * acknowledged and dropped — the agent re-reads truth from the API anyway.
     */
    const action = event.action || '';
    let issueId = '';
    if (resource === 'event_alert') {
      issueId = event.data?.event?.issue_id || '';
    } else if (resource === 'issue' && action === 'created') {
      issueId = event.data?.issue?.id || '';
    } else {
      return new Response(`ignored: no route for ${resource || 'unknown'}/${action || 'no-action'}`, { status: 200 });
    }
    if (!issueId) {
      return new Response('ignored: no issue id in payload', { status: 200 });
    }

    const resp = await fetch(`https://api.github.com/repos/${env.GITHUB_REPO}/dispatches`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.GITHUB_PAT}`,
        Accept: 'application/vnd.github+json',
        'User-Agent': 'ai-automations-sentry-relay',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        event_type: 'sentry_event',
        client_payload: {
          kind: `${resource}-${action || 'alert'}`,
          item_id: String(issueId),
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
