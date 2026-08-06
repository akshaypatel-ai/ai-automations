// Docker-server runtime — generic webhook receiver.
//
// The trick that makes this runtime zero-port: every recipe already ships a
// Cloudflare Worker (relay/worker.js) that does the hard part — signature
// verification, challenge echoes, noise filtering. This receiver runs those
// workers VERBATIM (Node ≥20 has Request/Response/crypto.subtle natively) and
// intercepts the one thing that differs: the `repository_dispatch` call to
// GitHub becomes a local job instead of a CI trigger.
//
// Auto-discovery: every scripts/*-agent/ in $REPO_DIR that has relay/worker.js
// is mounted at POST /<agent-name>/...  (path suffix forwarded unchanged, so
// URL-secret workers keep working: /clickup-agent/hook, /jira-agent/hook/<secret>).
// Worker env = relay/wrangler.toml [vars] + process.env (secrets from .env win).
//
// Jobs run one-at-a-time per agent (the drivers already treat every run as
// "everything new since saved state", so queueing is safe by design).

import { createServer } from 'node:http';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import path from 'node:path';

const REPO_DIR = process.env.REPO_DIR || '/repo';
const PORT = Number(process.env.PORT || 8787);

/** Minimal wrangler.toml [vars] parser (KEY = "value" lines only). */
function wranglerVars(file) {
  const vars = {};
  if (!existsSync(file)) return vars;
  let inVars = false;
  for (const raw of readFileSync(file, 'utf8').split('\n')) {
    const line = raw.trim();
    if (line.startsWith('[')) { inVars = line === '[vars]'; continue; }
    if (!inVars || !line || line.startsWith('#')) continue;
    const m = line.match(/^([A-Za-z0-9_]+)\s*=\s*"(.*)"\s*$/);
    if (m) vars[m[1]] = m[2];
  }
  return vars;
}

/** Discover installed agents. */
async function discoverAgents() {
  const agents = new Map();
  const scripts = path.join(REPO_DIR, 'scripts');
  if (!existsSync(scripts)) return agents;
  for (const name of readdirSync(scripts)) {
    const workerPath = path.join(scripts, name, 'relay', 'worker.js');
    if (!existsSync(workerPath)) continue;
    const mod = await import(pathToFileURL(workerPath).href);
    const env = {
      ...wranglerVars(path.join(scripts, name, 'relay', 'wrangler.toml')),
      ...process.env, // .env secrets override rendered vars
    };
    agents.set(name, { worker: mod.default, env, queue: [], running: false });
    console.log(`mounted /${name} → scripts/${name}/relay/worker.js`);
  }
  return agents;
}

/** Serialized per-agent job runner. */
function enqueue(agents, name, payload) {
  const agent = agents.get(name);
  agent.queue.push(payload);
  drain(name, agent);
}

function drain(name, agent) {
  if (agent.running || agent.queue.length === 0) return;
  agent.running = true;
  const p = agent.queue.shift();
  const env = {
    ...process.env,
    ITEM_ID: String(p.item_id ?? ''),
    ITEM_TYPE: String(p.item_type ?? ''),
    EVENT_KIND: String(p.kind ?? 'webhook'),
    // Notify/summon payloads travel whole:
    ASK_TEXT: String(p.text ?? ''),
    ASK_CHAT_ID: String(p.chat_id ?? ''),
    ASK_APP_ID: String(p.app_id ?? ''),
    ASK_TOKEN: String(p.interaction_token ?? ''),
    FILE_KEY: String(p.file_key ?? ''),
    ROOT_ID: String(p.root_id ?? ''),
    MODE: p.text !== undefined ? 'ask' : (process.env.MODE || ''),
  };
  console.log(`[${name}] run start (kind=${env.EVENT_KIND} item=${env.ITEM_ID || 'reconcile'})`);
  // Freshen the checkout first — state and code both live in git.
  const child = spawn('bash', ['-lc',
    `cd "$REPO_DIR" && git pull --rebase --quiet || true; bash scripts/${name}/agent-run.sh`,
  ], { env: { ...env, REPO_DIR }, stdio: 'inherit' });
  child.on('exit', (code) => {
    console.log(`[${name}] run finished (exit ${code})`);
    agent.running = false;
    drain(name, agent);
  });
}

const agents = await discoverAgents();
if (agents.size === 0) {
  console.error(`no agents found under ${REPO_DIR}/scripts/*-agent/relay/worker.js`);
  process.exit(1);
}

// The interception: workers call fetch() on api.github.com/.../dispatches —
// turn that into a local enqueue and report success. Everything else passes
// through (some workers legitimately call their tool's API).
const realFetch = globalThis.fetch;
let currentAgent = null;
globalThis.fetch = async (input, init) => {
  const url = typeof input === 'string' ? input : input.url;
  if (url.includes('api.github.com') && url.includes('/dispatches')) {
    const body = JSON.parse(init?.body ?? '{}');
    enqueue(agents, currentAgent, body.client_payload ?? {});
    return new Response(null, { status: 204 });
  }
  return realFetch(input, init);
};

createServer(async (req, res) => {
  try {
    const [, name, ...rest] = (req.url || '/').split('/');
    if (!agents.has(name)) { res.writeHead(404).end('unknown agent'); return; }

    const chunks = [];
    for await (const c of req) chunks.push(c);
    const body = Buffer.concat(chunks);

    // Rebuild the request with the agent prefix stripped, so URL-secret
    // workers see the same pathname they would on Cloudflare.
    const inner = new Request(`http://relay/${rest.join('/')}`, {
      method: req.method,
      headers: req.headers,
      body: ['GET', 'HEAD'].includes(req.method) ? undefined : body,
    });

    const agent = agents.get(name);
    currentAgent = name;
    const ctx = { waitUntil: (p) => { Promise.resolve(p).catch(() => {}); } };
    const out = await agent.worker.fetch(inner, agent.env, ctx);

    res.writeHead(out.status, Object.fromEntries(out.headers));
    res.end(Buffer.from(await out.arrayBuffer()));
  } catch (e) {
    console.error('receiver error:', e);
    res.writeHead(500).end('receiver error');
  }
}).listen(PORT, () => console.log(`receiver listening on :${PORT} (${agents.size} agent(s))`));
