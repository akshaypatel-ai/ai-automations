// Serverless runtime — AWS Lambda handler for `DISPATCH_KIND=url` relays.
//
// The relay worker POSTs the SAME shape it sends GitHub:
//   { "event_type": "<tool>_event", "client_payload": { kind, item_id, ... } }
// This handler parses that body from a Lambda Function URL event, maps the
// client_payload to the exact env vars the docker-server receiver sets
// (ITEM_ID, ITEM_TYPE, EVENT_KIND, ASK_TEXT, ASK_CHAT_ID, ASK_APP_ID,
// ASK_TOKEN, FILE_KEY, ROOT_ID, MODE=ask when text is present), then runs
// scripts/<AGENT_NAME>/agent-run.sh SYNCHRONOUSLY and returns the exit code.
//
// Synchronous is fine here: the relay already answered the tool's webhook
// with a 200 before (or regardless of) how long this takes — nobody is
// holding a webhook open waiting on us. What is NOT fine is Lambda's hard
// 15-minute cap: analyze / respond / triage runs (2–8 min) fit comfortably;
// `implement` playbook runs (15–20 min) DO NOT — put those on docker-server
// or Cloud Run (60-min timeout) instead. See core/runtimes/serverless/README.md.
//
// Lambda's filesystem is read-only except /tmp, so the repo checkout lives
// there and is cloned on cold start (and re-pulled every invoke — state and
// code both live in git). Warm containers reuse the clone.
//
// Env vars (function configuration):
//   REPO_DIR        checkout path, default /tmp/repo
//   AGENT_NAME      which scripts/<name>/agent-run.sh to run (e.g. clickup-agent)
//   DISPATCH_TOKEN  optional shared secret; when set, requests must carry
//                   `Authorization: Bearer <token>` (mismatch → 401)
//   GITHUB_REPO     owner/repo of the agent repo (cold-start clone)
//   GITHUB_PAT      PAT with contents read+write on that repo (clone + state pushes)
//   ...plus whatever the driver needs (ANTHROPIC_API_KEY, tool tokens, ...).

import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import path from 'node:path';

const REPO_DIR = process.env.REPO_DIR || '/tmp/repo';

/** Cold-start clone into Lambda's writable /tmp. Warm invokes skip this. */
function ensureRepo() {
  if (existsSync(path.join(REPO_DIR, '.git'))) return true;
  const repo = process.env.GITHUB_REPO;
  const pat = process.env.GITHUB_PAT;
  if (!repo || !pat) {
    console.error('cold start: GITHUB_REPO / GITHUB_PAT not set, cannot clone');
    return false;
  }
  const clone = spawnSync('git', [
    'clone', '--depth', '50', '--quiet',
    `https://x-access-token:${pat}@github.com/${repo}.git`, REPO_DIR,
  ], { stdio: 'inherit', env: process.env });
  return clone.status === 0;
}

export async function handler(event) {
  // Optional bearer auth — mirrors the relay's DISPATCH_TOKEN secret.
  const token = process.env.DISPATCH_TOKEN;
  if (token) {
    const auth = event.headers?.authorization ?? event.headers?.Authorization ?? '';
    if (auth !== `Bearer ${token}`) {
      return { statusCode: 401, body: 'bad token' };
    }
  }

  let payload;
  try {
    const raw = event.isBase64Encoded
      ? Buffer.from(event.body || '', 'base64').toString('utf8')
      : (event.body || '{}');
    payload = JSON.parse(raw);
  } catch {
    return { statusCode: 400, body: 'bad json' };
  }
  const p = payload.client_payload ?? {};

  const agent = process.env.AGENT_NAME;
  if (!agent) return { statusCode: 500, body: 'AGENT_NAME not set' };
  if (!ensureRepo()) return { statusCode: 500, body: 'repo clone failed' };

  // Same env contract as core/runtimes/docker-server/receiver.mjs drain().
  const env = {
    ...process.env,
    REPO_DIR,
    ITEM_ID: String(p.item_id ?? ''),
    ITEM_TYPE: String(p.item_type ?? ''),
    EVENT_KIND: String(p.kind ?? 'webhook'),
    ASK_TEXT: String(p.text ?? ''),
    ASK_CHAT_ID: String(p.chat_id ?? ''),
    ASK_APP_ID: String(p.app_id ?? ''),
    ASK_TOKEN: String(p.interaction_token ?? ''),
    FILE_KEY: String(p.file_key ?? ''),
    ROOT_ID: String(p.root_id ?? ''),
    MODE: p.text !== undefined ? 'ask' : (process.env.MODE || ''),
  };

  console.log(`[${agent}] run start (kind=${env.EVENT_KIND} item=${env.ITEM_ID || 'reconcile'})`);
  // Freshen the checkout first — state and code both live in git.
  const run = spawnSync('bash', ['-lc',
    `cd "$REPO_DIR" && git pull --rebase --quiet || true; bash scripts/${agent}/agent-run.sh`,
  ], { env, stdio: 'inherit' });
  console.log(`[${agent}] run finished (exit ${run.status})`);

  return {
    statusCode: 200,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      event_type: payload.event_type ?? '',
      exit_code: run.status,
    }),
  };
}
