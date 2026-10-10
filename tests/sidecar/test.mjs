// test.mjs — the credential test for the sidecar (Phase A: no containers).
//
// Started by tests/sidecar/run.sh. Everything runs as ordinary processes on
// this machine's loopback address:
//
//   this test  ──►  sidecar.mjs  ──►  mock-upstream.mjs
//   (plays the      (the real         (plays the vendor and
//    agent's CLI,    server, as it     records what it is sent)
//    dummy token)    ships)
//
// The test plays a CLI holding a DUMMY credential, loads a fake "real" one
// into the sidecar through sidecar-load, and then reads the mock's record to
// see which of the two the "vendor" was sent. The barrier numbers in the
// check names point into docs/00-threat-model.md.
//
// What this cannot show: that the real vendors accept what the sidecar
// forwards, and anything about containers. See "Unproven until Phase B" in
// the component report.

import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { ACCOUNTS_CHECK, CLAUDE_REPLY_QUERY, CODEX_REPLY_QUERY, CODEX_REPLY_URL, claudeEvents, codexStream } from './mock-upstream.mjs';
import { selfSigned } from './selfsigned.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..', '..');
const SIDECAR = path.join(ROOT, 'images', 'credsidecar', 'sidecar.mjs');
const LOAD = path.join(ROOT, 'images', 'credsidecar', 'sidecar-load');
const HEALTHCHECK = path.join(ROOT, 'images', 'credsidecar', 'sidecar-healthcheck');
const AGENTS = path.join(ROOT, 'agents');
const MOCK = path.join(HERE, 'mock-upstream.mjs');

// Fake credentials. The REAL ones stand for what the operator's keyring
// holds; the DUMMY ones for what the agent's container is given.
const tag = crypto.randomBytes(6).toString('hex');
const REAL_1 = `sk-ant-oat01-REAL-FIRST-${tag}`;
const REAL_2 = `sk-ant-oat01-REAL-SECOND-${tag}`;
const REAL_KEY = `sk-ant-api03-REAL-KEY-${tag}`;
const REAL_CODEX = `eyJREAL.CODEX-ACCESS-${tag}.sig`;
const REAL_OPENAI_KEY = `sk-proj-REAL-OPENAI-${tag}`;
const REAL_TUNNEL = `sk-ant-oat01-REAL-TUNNEL-${tag}`;
const REAL_ACCOUNT = `acct-real-${tag}`;
const DUMMY = `sk-ant-oat01-DUMMY-${tag}`;
const DUMMY_KEY = `sk-ant-api03-DUMMY-KEY-${tag}`;
const DUMMY_ACCOUNT = `acct-dummy-${tag}`;
const DUMMY_COOKIE = `session=dummy-cookie-${tag}`;
const REAL_SECRETS = [REAL_1, REAL_2, REAL_KEY, REAL_CODEX, REAL_OPENAI_KEY, REAL_TUNNEL];
const DUMMIES = [DUMMY, DUMMY_KEY, DUMMY_ACCOUNT, DUMMY_COOKIE];

// ---------------------------------------------------------------------------
// Bookkeeping
// ---------------------------------------------------------------------------
let passed = 0;
let failed = 0;
function check(label, condition, detail = '') {
  if (condition) {
    passed += 1;
    console.log(`ok    ${label}`);
  } else {
    failed += 1;
    console.log(`FAIL  ${label}${detail ? `\n        ${detail}` : ''}`);
  }
}
const section = (title) => console.log(`\n# ${title}`);

const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'sidecar-test-'));
const children = [];
const sidecars = [];       // every sidecar started, for the leak check at the end
const clientSaw = [];      // everything any sidecar sent back to the "CLI"
const loaderSaid = [];     // everything sidecar-load printed

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function waitFor(probe, ms = 4000) {
  for (const deadline = Date.now() + ms; Date.now() < deadline;) {
    const value = probe();
    if (value) return value;
    await sleep(20);
  }
  return probe() || null;
}

// A child process gets a bare environment: nothing from this shell (a proxy
// setting, say) can leak into what is being tested.
const bareEnv = (extra) => ({ PATH: process.env.PATH, ...extra });

function run(script, env, input = null) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [script], { env: bareEnv(env), stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });
    child.on('close', (code) => resolve({ code, stdout, stderr }));
    child.stdin.end(input ?? '');
  });
}

async function startMock(tlsFiles = null) {
  const env = tlsFiles ? { MOCK_TLS_KEY: tlsFiles.key, MOCK_TLS_CERT: tlsFiles.cert } : {};
  const child = spawn(process.execPath, [MOCK], { env: bareEnv(env), stdio: ['ignore', 'pipe', 'inherit'] });
  children.push(child);
  let out = '';
  child.stdout.on('data', (d) => { out += d; });
  const ready = await waitFor(() => out.includes('\n'));
  if (!ready) throw new Error('the mock upstream did not start');
  const { port } = JSON.parse(out);
  const call = (method, urlPath) => new Promise((resolve, reject) => {
    const options = { host: '127.0.0.1', port, method, path: urlPath, agent: false };
    const req = tlsFiles
      ? https.request({ ...options, ca: fs.readFileSync(tlsFiles.cert), servername: tlsFiles.name })
      : http.request(options);
    req.on('response', (res) => {
      let text = '';
      res.on('data', (d) => { text += d; });
      res.on('end', () => resolve(JSON.parse(text)));
    });
    req.on('error', reject);
    req.end();
  });
  return { port, requests: () => call('GET', '/__mock/requests'), reset: () => call('POST', '/__mock/reset') };
}

// Start the sidecar exactly as the image does (`node sidecar.mjs`), with the
// test-only settings that move its port, its state directory and its
// upstream onto this machine.
async function startSidecar({ agent, auth, budget = '50', env = {}, waitForStart = true }) {
  const stateDir = fs.mkdtempSync(path.join(tempRoot, 'state-'));
  const child = spawn(process.execPath, [SIDECAR], {
    env: bareEnv({
      SANDBOX_AGENT: agent, SANDBOX_AUTH: auth, SANDBOX_BUDGET: budget,
      SANDBOX_SIDECAR_LISTEN: '127.0.0.1:0', SANDBOX_SIDECAR_STATE_DIR: stateDir, SANDBOX_AGENTS_DIR: AGENTS, ...env,
    }),
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  children.push(child);
  const sidecar = { child, stateDir, stdout: '', stderr: '', exitCode: undefined, port: 0 };
  sidecars.push(sidecar);
  child.stdout.on('data', (d) => { sidecar.stdout += d; });
  child.stderr.on('data', (d) => { sidecar.stderr += d; });
  sidecar.exited = new Promise((resolve) => child.on('close', (code) => { sidecar.exitCode = code; resolve(code); }));
  sidecar.lines = () => sidecar.stdout.split('\n').filter(Boolean);
  sidecar.events = () => sidecar.lines().map((line) => { try { return JSON.parse(line); } catch { return { unparsable: line }; } });
  sidecar.logged = (test) => waitFor(() => sidecar.events().filter(test).pop());
  sidecar.stop = () => { child.kill('SIGTERM'); return sidecar.exited; };
  sidecar.load = async (credential, args = []) => {
    const input = typeof credential === 'string' ? credential : JSON.stringify(credential);
    const result = await new Promise((resolve) => {
      const loader = spawn(process.execPath, [LOAD, ...args], { env: bareEnv({ SANDBOX_SIDECAR_STATE_DIR: stateDir }), stdio: ['pipe', 'pipe', 'pipe'] });
      let stdout = '';
      let stderr = '';
      loader.stdout.on('data', (d) => { stdout += d; });
      loader.stderr.on('data', (d) => { stderr += d; });
      loader.on('close', (code) => resolve({ code, stdout, stderr }));
      loader.stdin.end(input);
    });
    loaderSaid.push(result.stdout, result.stderr);
    return result;
  };
  sidecar.started = async () => {
    await waitFor(() => sidecar.exitCode !== undefined || sidecar.events().some((e) => e.event === 'start'));
    const start = sidecar.events().find((e) => e.event === 'start');
    if (start) sidecar.port = Number(start.listen.split(':').pop());
    return start;
  };
  if (waitForStart) await sidecar.started();
  return sidecar;
}

// One request as a CLI would make it. Records everything that comes back.
function call(port, { method = 'POST', urlPath, headers = {}, body = null, pieces = null, abortAfterFirstChunk = false }) {
  return new Promise((resolve) => {
    const payload = body === null ? null : Buffer.isBuffer(body) ? body : Buffer.from(typeof body === 'string' ? body : JSON.stringify(body));
    const allHeaders = { ...headers };
    if (payload) allHeaders['content-length'] = payload.length;
    const req = http.request({ host: '127.0.0.1', port, method, path: urlPath, headers: allHeaders, agent: false });
    const result = { status: 0, headers: {}, rawHeaders: [], body: '', chunks: [], error: null };
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      clientSaw.push(`${result.status} ${result.rawHeaders.join(' ')}\n${result.body}`);
      resolve(result);
    };
    req.on('response', (res) => {
      result.status = res.statusCode;
      result.headers = res.headers;
      result.rawHeaders = res.rawHeaders;
      // Kept as bytes and decoded once at the end: a piece may end in the
      // middle of a character.
      res.on('data', (d) => {
        result.chunks.push({ at: Date.now(), bytes: d });
        result.body = Buffer.concat(result.chunks.map((c) => c.bytes)).toString('utf8');
        if (abortAfterFirstChunk) req.destroy();
      });
      res.on('end', finish);
      res.on('error', finish);
      res.on('close', finish);
    });
    req.on('error', (err) => { result.error = err.code ?? err.message; if (result.status === 0 || abortAfterFirstChunk) finish(); });
    if (pieces) {
      for (const piece of pieces) req.write(piece);
      req.end();
    } else {
      req.end(payload ?? undefined);
    }
  });
}
const errorType = (reply) => { try { return JSON.parse(reply.body).error.type; } catch { return `(not a JSON error: ${reply.body.slice(0, 80)})`; } };

// What Claude Code sends (from the spike), with the dummy credential.
const CLAUDE_HEADERS = {
  authorization: `Bearer ${DUMMY}`,
  'content-type': 'application/json',
  'anthropic-version': '2023-06-01',
  'anthropic-beta': 'claude-code-20250219,oauth-2025-04-20,interleaved-thinking-2025-05-14',
  'user-agent': 'claude-cli/2.1.283 (external, cli)',
  'x-app': 'cli',
  'x-stainless-lang': 'js',
  'x-stainless-retry-count': '0',
  'x-claude-code-session-id': 'mock-session',
};
const CLAUDE_TOOLS = [
  { name: 'Bash', description: 'run a command', input_schema: { type: 'object' } },
  { type: 'custom', name: 'Read', input_schema: { type: 'object' } },
  { type: 'text_editor_20250728', name: 'str_replace_based_edit_tool' },
];
const claudeBody = (extra = {}) => ({ model: 'claude-mock-model', max_tokens: 64, messages: [{ role: 'user', content: 'hello' }], tools: CLAUDE_TOOLS, ...extra });
const claude = (port, body, extra = {}) => call(port, { urlPath: '/v1/messages?beta=true', headers: { ...CLAUDE_HEADERS, ...extra }, body });

const CODEX_HEADERS = {
  authorization: `Bearer ${DUMMY}`,
  'chatgpt-account-id': DUMMY_ACCOUNT,
  'content-type': 'application/json',
  accept: 'text/event-stream',
  'user-agent': 'codex_cli_rs/0.159.3',
  originator: 'codex_cli_rs',
};
const CODEX_TOOLS = [
  { type: 'function', name: 'shell', parameters: { type: 'object' } },
  { type: 'custom', name: 'apply_patch' },
  { type: 'web_search', external_web_access: true },
];
const codexBody = (extra = {}) => ({ model: 'gpt-mock-codex', stream: true, store: false, input: [{ type: 'message', role: 'user', content: [{ type: 'input_text', text: 'hello' }] }], tools: CODEX_TOOLS, ...extra });

// ---------------------------------------------------------------------------
// The tests
// ---------------------------------------------------------------------------
async function claudeOauth(mock) {
  section('Claude Code, subscription login (oauth)');
  const sidecar = await startSidecar({ agent: 'claude', auth: 'oauth', env: { SANDBOX_UPSTREAM_OVERRIDE: `http://127.0.0.1:${mock.port}` } });
  check('the sidecar starts', sidecar.port > 0, sidecar.stderr);
  const port = sidecar.port;

  const healthy = await run(HEALTHCHECK, { SANDBOX_SIDECAR_LISTEN: `127.0.0.1:${port}` });
  check('sidecar-healthcheck exits 0 while the listener answers', healthy.code === 0, healthy.stderr);

  // (4) No credential yet.
  let reply = await claude(port, claudeBody());
  check('[B22] before a credential is loaded the answer is 503, with Retry-After', reply.status === 503 && reply.headers['retry-after'] !== undefined && errorType(reply) === 'sandbox_credential_not_loaded', `${reply.status} ${reply.body}`);
  check('[B22] ... and nothing reached the vendor', (await mock.requests()).length === 0);

  // sidecar-load refuses bad input, loudly, and without repeating it.
  const badInputs = {
    'not JSON': `token=${REAL_1}`,
    'no token': JSON.stringify({ account_id: 'acct' }),
    'an unknown key': JSON.stringify({ token: REAL_1, refresh_token: REAL_2 }),
    'a token with a line break': JSON.stringify({ token: `${REAL_1}\r\nx-evil: 1` }),
    'two objects': `${JSON.stringify({ token: REAL_1 })}${JSON.stringify({ token: REAL_2 })}`,
    'an empty input': '',
  };
  for (const [what, input] of Object.entries(badInputs)) {
    const result = await sidecar.load(input);
    check(`sidecar-load fails on ${what} and stores nothing`, result.code !== 0 && result.stderr.includes('nothing was stored') && !fs.existsSync(path.join(sidecar.stateDir, 'cred', 'credential.json')), `exit ${result.code}: ${result.stderr}`);
  }

  // Load the first "real" credential.
  const loaded = await sidecar.load({ token: REAL_1 });
  const credFile = path.join(sidecar.stateDir, 'cred', 'credential.json');
  check('sidecar-load stores a well-formed credential', loaded.code === 0, loaded.stderr);
  check('[B22] the credential file is 0600 in a 0700 directory', fs.existsSync(credFile) && (fs.statSync(credFile).mode & 0o777) === 0o600 && (fs.statSync(path.dirname(credFile)).mode & 0o777) === 0o700);

  // (1) (2) The swap.
  const sent = claudeBody();
  reply = await call(port, { urlPath: '/v1/messages?beta=true', headers: { ...CLAUDE_HEADERS, 'x-api-key': DUMMY_KEY, cookie: DUMMY_COOKIE }, body: sent });
  let seen = await mock.requests();
  let last = seen[seen.length - 1];
  check('a model request is forwarded and answered', reply.status === 200 && seen.length === 1, `${reply.status} ${reply.body}`);
  check('[B22] the vendor received the REAL token', last?.headers.authorization === `Bearer ${REAL_1}`, String(last?.headers.authorization));
  check('[B22] the dummy the agent sent is nowhere in what the vendor received', DUMMIES.every((d) => !JSON.stringify(seen).includes(d)));
  check('[B22] x-api-key and cookie from the agent were dropped', last && !('x-api-key' in last.headers) && !('cookie' in last.headers));
  check('[B22] the request went to the configured upstream host, path and query unchanged', last?.headers.host === 'api.anthropic.com' && last?.url === '/v1/messages?beta=true', `${last?.headers.host} ${last?.url}`);
  const passedOn = ['anthropic-version', 'anthropic-beta', 'user-agent', 'x-app', 'x-stainless-lang', 'x-stainless-retry-count', 'x-claude-code-session-id'];
  check('the CLI\'s other headers pass through unchanged', passedOn.every((h) => last?.headers[h] === CLAUDE_HEADERS[h]), JSON.stringify(last?.headers));
  check('[B23] the body the vendor received is byte-for-byte what the CLI sent', last?.body === JSON.stringify(sent));
  check('the vendor\'s reply headers pass through, except cookies', reply.headers['x-request-id'] === 'mock-request-id' && reply.headers['set-cookie'] === undefined);
  let entry = await sidecar.logged((e) => e.event === 'request' && e.status === 200);
  check('[B25] the request is logged with model, tools and the budget left', entry?.model === 'claude-mock-model' && entry.stream === false && entry.tools.includes('Bash') && entry.tool_types.includes('text_editor_20250728') && entry.budget_left === 49 && typeof entry.ms === 'number', JSON.stringify(entry));

  // count_tokens is forwarded but is not a model request.
  reply = await call(port, { urlPath: '/v1/messages/count_tokens?beta=true', headers: CLAUDE_HEADERS, body: claudeBody() });
  entry = await sidecar.logged((e) => e.path === '/v1/messages/count_tokens');
  check('[B24] count_tokens is forwarded and does not use the budget', reply.status === 200 && JSON.parse(reply.body).input_tokens === 42 && entry?.budget_left === 49, `${reply.status} ${JSON.stringify(entry)}`);

  // (5) Replace the credential mid-run.
  await sidecar.load({ token: REAL_2 });
  reply = await claude(port, claudeBody());
  seen = await mock.requests();
  last = seen[seen.length - 1];
  check('[B22] replacing the credential mid-run changes the next request\'s header', reply.status === 200 && last.headers.authorization === `Bearer ${REAL_2}`, String(last.headers.authorization));

  // (6) Unlisted paths.
  await mock.reset();
  const unlisted = [
    ['GET', '/v1/models'], ['POST', '/v1/files'], ['POST', '/v1/messages/'], ['POST', '//v1/messages'],
    ['POST', '/v1/messages/../messages'], ['POST', '/v1/%6dessages'], ['GET', '/v1/messages'], ['PUT', '/v1/messages'],
    ['POST', '/v1/messages/batches'], ['POST', '/'], ['POST', 'http://evil.example/v1/messages'],
  ];
  const statuses = [];
  for (const [method, urlPath] of unlisted) statuses.push((await call(port, { method, urlPath, headers: CLAUDE_HEADERS, body: method === 'POST' || method === 'PUT' ? claudeBody() : null })).status);
  check('[B23] an unlisted path or method is 404', statuses.every((s) => s === 404), statuses.join(' '));

  // (7) Request features that make the vendor contact other hosts.
  const refused = {
    'top-level mcp_servers': claudeBody({ mcp_servers: [{ type: 'url', url: 'https://evil.example/mcp', name: 'x' }] }),
    'an empty mcp_servers': claudeBody({ mcp_servers: [] }),
    'a web_fetch tool': claudeBody({ tools: [...CLAUDE_TOOLS, { type: 'web_fetch_20250910', name: 'web_fetch' }] }),
    'a code_execution tool': claudeBody({ tools: [{ type: 'code_execution_20250825', name: 'code_execution' }] }),
    'an mcp_toolset tool': claudeBody({ tools: [{ type: 'mcp_toolset', mcp_server_name: 'x' }] }),
    'an unknown tool type': claudeBody({ tools: [{ type: 'brand_new_tool_20270101', name: 'shiny' }] }),
    'a tool whose type is not a string': claudeBody({ tools: [{ type: 7, name: 'odd' }] }),
    'an image fetched by URL': claudeBody({ messages: [{ role: 'user', content: [{ type: 'image', source: { type: 'url', url: 'https://evil.example/?leak=1' } }] }] }),
    'a document fetched by URL inside a tool result': claudeBody({ messages: [{ role: 'user', content: [{ type: 'tool_result', tool_use_id: 't', content: [{ type: 'document', source: { type: 'url', url: 'https://evil.example/x.pdf' } }] }] }] }),
    'a body that is a list': [claudeBody()],
  };
  for (const [what, body] of Object.entries(refused)) {
    reply = await claude(port, body);
    check(`[B23] ${what} is refused with 400`, reply.status === 400 && errorType(reply).startsWith('sandbox_'), `${reply.status} ${reply.body}`);
  }
  reply = await claude(port, '{"model": "x", "messages": [}');
  check('[B23] a body that is not JSON is refused with 400', reply.status === 400 && errorType(reply) === 'sandbox_body_unreadable', `${reply.status} ${reply.body}`);
  reply = await claude(port, claudeBody(), { 'content-encoding': 'gzip' });
  check('[B23] a compressed body, which could not be checked, is refused with 400', reply.status === 400 && errorType(reply) === 'sandbox_body_unreadable', `${reply.status} ${reply.body}`);
  check('[B23] ... and none of the refused requests reached the vendor', (await mock.requests()).length === 0);
  entry = await sidecar.logged((e) => e.refused === 'sandbox_tool_type_unknown' && String(e.detail).includes('brand_new_tool_20270101'));
  check('[B23] an unknown tool type is logged with its name', entry !== null && entry.detail.includes('shiny'), JSON.stringify(entry));

  // A tool_use whose input happens to look like a URL source is data, not a fetch.
  reply = await claude(port, claudeBody({ messages: [{ role: 'assistant', content: [{ type: 'tool_use', id: 't', name: 'Read', input: { source: { type: 'url', url: 'https://example.org' } } }] }, { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't', content: 'ok' }] }] }));
  check('[B23] what a client-side tool was called with is not mistaken for a fetch', reply.status === 200, `${reply.status} ${reply.body}`);

  // The same key twice: this check and the vendor must not read two
  // different bodies. The vendor gets the form that was checked.
  await mock.reset();
  reply = await claude(port, '{"model":"claude-mock-model","tools":[{"type":"web_fetch_20250910","name":"web_fetch"}],"messages":[{"role":"user","content":"hi"}],"tools":[]}');
  seen = await mock.requests();
  entry = await sidecar.logged((e) => e.rewritten === true);
  check('[B23] a body with a key given twice reaches the vendor only in the form that was checked', reply.status === 200 && seen.length === 1 && !seen[0].body.includes('web_fetch') && seen[0].body === '{"model":"claude-mock-model","tools":[],"messages":[{"role":"user","content":"hi"}]}' && entry !== null, seen[0]?.body);

  // (9) Streaming.
  const streamStart = Date.now();
  reply = await claude(port, claudeBody({ stream: true }));
  const expected = claudeEvents(false).join('');
  check('a streamed reply arrives intact and in order', reply.status === 200 && reply.body === expected && reply.headers['content-type'] === 'text/event-stream');
  const first = reply.chunks[0]?.at ?? 0;
  const final = reply.chunks[reply.chunks.length - 1]?.at ?? 0;
  check('... piece by piece as the vendor sends it, not held back to the end', reply.chunks.length >= 4 && final - first >= 150, `${reply.chunks.length} pieces over ${final - first} ms (whole call ${Date.now() - streamStart} ms)`);

  // (10) Web search, the Claude Code shape: its own request, one server tool.
  const query = `sandbox escape via ${tag} café \u001b[2J\nsecond line`;
  const searchBody = {
    model: 'claude-mock-model', max_tokens: 64, stream: true,
    tools: [{ type: 'web_search_20250305', name: 'web_search', max_uses: 8 }],
    messages: [{ role: 'user', content: [{ type: 'text', text: `Perform a web search for the query: ${query}` }] }],
  };
  reply = await claude(port, searchBody);
  entry = await sidecar.logged((e) => Array.isArray(e.web_search) && e.web_search.some((s) => s.from === 'request'));
  check('[B25] web search is let through', reply.status === 200 && reply.body === claudeEvents(true).join(''), `${reply.status}`);
  check('[B25] the web search query in a Claude request is in the log', entry?.web_search.some((s) => s.from === 'request' && s.query === query), JSON.stringify(entry));
  check('[B25] the query the model chose is read from the streamed reply as well (unproven against the real API)', entry?.web_search.some((s) => s.from === 'response' && s.query === CLAUDE_REPLY_QUERY), JSON.stringify(entry));
  // Search enabled next to other tools, not streamed: only the reply shows the query.
  reply = await claude(port, claudeBody({ tools: [...CLAUDE_TOOLS, { type: 'web_search_20250305', name: 'web_search' }], messages: [{ role: 'user', content: 'look it up' }, { role: 'assistant', content: [{ type: 'server_tool_use', id: 's', name: 'web_search', input: { query: 'an earlier search in the history' } }] }, { role: 'user', content: 'again' }] }));
  entry = await sidecar.logged((e) => Array.isArray(e.web_search) && e.web_search.some((s) => s.query === 'an earlier search in the history'));
  check('[B25] searches in the request history and in a non-streamed reply are logged', reply.status === 200 && entry?.web_search.some((s) => s.from === 'response' && s.query === CLAUDE_REPLY_QUERY), JSON.stringify(entry));

  // (11) The vendor rejects the credential.
  reply = await claude(port, claudeBody(), { 'x-mock-status': '401' });
  check('[B22] a 401 from the vendor reaches the agent as 403 with a message for the operator', reply.status === 403 && errorType(reply) === 'sandbox_credential_rejected' && reply.headers['www-authenticate'] === undefined && !reply.body.includes('invalid bearer token'), `${reply.status} ${reply.body}`);

  // (12) Oversized bodies.
  await mock.reset();
  const declared = await new Promise((resolve) => {
    const socket = net.connect(port, '127.0.0.1', () => socket.write(`POST /v1/messages HTTP/1.1\r\nHost: sidecar\r\nContent-Type: application/json\r\nContent-Length: ${40 * 1024 * 1024}\r\n\r\n{"model":`));
    let text = '';
    socket.on('data', (d) => { text += d; if (text.includes('\r\n\r\n')) socket.destroy(); });
    socket.on('close', () => resolve(text));
    socket.on('error', () => resolve(text));
  });
  clientSaw.push(declared);
  check('[B24] a body declared larger than 32 MB is refused with 413 before it is read', declared.startsWith('HTTP/1.1 413'), declared.slice(0, 60));
  const megabyte = Buffer.alloc(1024 * 1024, 0x20);
  reply = await call(port, { urlPath: '/v1/messages', headers: CLAUDE_HEADERS, pieces: [Buffer.from('{"model":"x","pad":"'), ...Array(33).fill(megabyte), Buffer.from('"}')] });
  check('[B24] a body that grows past 32 MB while being read is refused with 413', reply.status === 413 && errorType(reply) === 'sandbox_body_too_large', `${reply.status} ${reply.error}`);
  check('[B24] ... and neither reached the vendor', (await mock.requests()).length === 0);

  // At most 8 requests in flight.
  const slow = Array.from({ length: 8 }, () => call(port, { urlPath: '/v1/messages/count_tokens', headers: { ...CLAUDE_HEADERS, 'x-mock-delay-ms': '700' }, body: claudeBody() }));
  await sleep(200);   // let the eight reach the server first
  const ninth = await call(port, { urlPath: '/v1/messages/count_tokens', headers: CLAUDE_HEADERS, body: claudeBody() });
  const slowReplies = await Promise.all(slow);
  check('[B24] a ninth request while eight are in flight is told to retry (503), and the eight complete', ninth.status === 503 && errorType(ninth) === 'sandbox_busy' && slowReplies.every((r) => r.status === 200), `${ninth.status} / ${slowReplies.map((r) => r.status).join(' ')}`);

  // A client that leaves mid-stream must not take the server with it.
  await call(port, { urlPath: '/v1/messages?beta=true', headers: CLAUDE_HEADERS, body: claudeBody({ stream: true }), abortAfterFirstChunk: true });
  entry = await sidecar.logged((e) => e.cut_short === true);
  reply = await claude(port, claudeBody());
  check('a client that leaves mid-stream is logged and the next request still works', entry !== null && reply.status === 200, JSON.stringify(entry));

  check('sidecar-healthcheck fails when nothing is listening', (await run(HEALTHCHECK, { SANDBOX_SIDECAR_LISTEN: '127.0.0.1:1' })).code !== 0);
  check('the sidecar exits cleanly on SIGTERM', (await sidecar.stop()) === 0 && sidecar.events().some((e) => e.event === 'stop'));
}

async function budgetAndLogCap(mock) {
  section('Budget, and the cap on log lines');
  await mock.reset();
  const sidecar = await startSidecar({ agent: 'claude', auth: 'oauth', budget: '2', env: { SANDBOX_UPSTREAM_OVERRIDE: `http://127.0.0.1:${mock.port}` } });
  await sidecar.load({ token: REAL_1 });
  const port = sidecar.port;
  let cappedSent = 0;

  // A refused request costs nothing.
  let reply = await claude(port, claudeBody({ mcp_servers: [] }));
  cappedSent += 1;
  const two = [await claude(port, claudeBody()), await claude(port, claudeBody())];
  reply = await claude(port, claudeBody());
  cappedSent += 1;
  const seen = await mock.requests();
  check('[B24] requests within the budget are forwarded; a refused one did not use it', two.every((r) => r.status === 200) && seen.length === 2, two.map((r) => r.status).join(' '));
  check('[B24] the request after the budget is 403 with a clear JSON error (not 401, not 429)', reply.status === 403 && errorType(reply) === 'sandbox_budget_exhausted' && JSON.parse(reply.body).type === 'error', `${reply.status} ${reply.body}`);
  check('[B24] ... and the vendor did not see it', seen.length === 2);
  reply = await call(port, { urlPath: '/v1/messages/count_tokens', headers: CLAUDE_HEADERS, body: claudeBody() });
  cappedSent += 1;
  check('[B24] a route that is not a model request still works past the budget', reply.status === 200);

  // Flood the log with refusals.
  for (let batch = 0; batch < 20; batch += 1) {
    await Promise.all(Array.from({ length: 8 }, (_, n) => call(port, { method: 'GET', urlPath: `/flood/${batch}/${n}` })));
    cappedSent += 8;
  }
  await sidecar.stop();
  const events = sidecar.events();
  const cappedWritten = events.filter((e) => e.event === 'request' && !(e.status === 200 && e.path === '/v1/messages')).length;
  const suppressed = events.filter((e) => e.event === 'suppressed').reduce((sum, e) => sum + e.count, 0);
  check('[B25] refused requests cannot flood the log: at most 60 lines a minute are written', cappedWritten <= 60, `${cappedWritten} lines`);
  check('[B25] ... and the lines left out are counted in the log', suppressed > 0 && cappedWritten + suppressed === cappedSent, `${cappedWritten} written + ${suppressed} suppressed, ${cappedSent} sent`);
  check('[B25] the model requests themselves were all logged', events.filter((e) => e.event === 'request' && e.status === 200 && e.path === '/v1/messages').length === 2);
}

async function codexOauth(mock) {
  section('Codex, ChatGPT login (oauth)');
  await mock.reset();
  const sidecar = await startSidecar({ agent: 'codex', auth: 'oauth', env: { SANDBOX_UPSTREAM_OVERRIDE: `http://127.0.0.1:${mock.port}` } });
  const port = sidecar.port;
  const codex = (body, extra = {}) => call(port, { urlPath: '/backend-api/codex/responses', headers: { ...CODEX_HEADERS, ...extra }, body });

  await sidecar.load({ token: REAL_CODEX });
  let reply = await codex(codexBody());
  check('[B22] a Codex credential without an account id is "not ready" (503), not sent half-made', reply.status === 503 && reply.body.includes('account_id') && (await mock.requests()).length === 0, `${reply.status} ${reply.body}`);

  await sidecar.load({ token: REAL_CODEX, account_id: REAL_ACCOUNT });
  reply = await codex(codexBody());
  let seen = await mock.requests();
  const last = seen[seen.length - 1];
  check('[B22] the vendor received the real bearer token', reply.status === 200 && last?.headers.authorization === `Bearer ${REAL_CODEX}`, `${reply.status} ${last?.headers.authorization}`);
  check('[B22] chatgpt-account-id was replaced by the real one', last?.headers['chatgpt-account-id'] === REAL_ACCOUNT, String(last?.headers['chatgpt-account-id']));
  check('[B22] the dummy token and dummy account id are nowhere in what the vendor received', DUMMIES.every((d) => !JSON.stringify(seen).includes(d)));
  check('[B22] the request went to chatgpt.com', last?.headers.host === 'chatgpt.com' && last?.url === '/backend-api/codex/responses');
  check('the Codex stream arrives intact and in order', reply.body === codexStream() && reply.chunks.length > 5, `${reply.chunks.length} pieces`);
  const entry = await sidecar.logged((e) => Array.isArray(e.web_search));
  check('[B25] the search query in a canned Codex reply stream is in the log (unproven against the real API)', entry?.web_search.some((s) => s.from === 'response' && s.kind === 'search' && s.query === CODEX_REPLY_QUERY), JSON.stringify(entry));
  check('[B25] ... and so is a page the vendor opened; each item once', entry?.web_search.some((s) => s.kind === 'open_page' && s.url === CODEX_REPLY_URL) && entry.web_search.length === 2, JSON.stringify(entry));

  reply = await call(port, { method: 'GET', urlPath: '/backend-api/wham/accounts/check', headers: CODEX_HEADERS });
  seen = await mock.requests();
  check('GET /backend-api/wham/accounts/check returns what the vendor returns, asked with the real credential', reply.status === 200 && reply.body === JSON.stringify(ACCOUNTS_CHECK) && seen[seen.length - 1].headers.authorization === `Bearer ${REAL_CODEX}`, `${reply.status} ${reply.body}`);
  const gets = [];
  for (const urlPath of ['/backend-api/codex/models', '/backend-api/wham/usage', '/backend-api/wham/rate-limit-reset-credits']) gets.push((await call(port, { method: 'GET', urlPath, headers: CODEX_HEADERS })).status);
  check('the other Codex routes are forwarded', gets.every((s) => s === 200), gets.join(' '));

  await mock.reset();
  const refused = {
    'an OpenAI remote "mcp" tool': codexBody({ tools: [...CODEX_TOOLS, { type: 'mcp', server_label: 'x', server_url: 'https://evil.example/mcp' }] }),
    'a file_search tool': codexBody({ tools: [{ type: 'file_search', vector_store_ids: ['vs_1'] }] }),
    'a code_interpreter tool': codexBody({ tools: [{ type: 'code_interpreter', container: { type: 'auto' } }] }),
    'an unknown OpenAI tool type': codexBody({ tools: [{ type: 'brand_new_openai_tool' }] }),
    'a tool with no type': codexBody({ tools: [{ name: 'untyped' }] }),
    'an mcp tool hidden inside a namespace': codexBody({ tools: [{ type: 'namespace', name: 'ns', tools: [{ type: 'mcp', server_url: 'https://evil.example' }] }] }),
    // Codex 0.162 declares its tools in an "additional_tools" input item, not in "tools".
    'an mcp tool declared in an additional_tools input item': codexBody({ tools: undefined, input: [{ type: 'additional_tools', id: 'at_1', role: 'developer', tools: [{ type: 'namespace', name: 'functions', tools: [{ type: 'custom', name: 'exec' }, { type: 'mcp', server_url: 'https://evil.example' }] }] }, { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'hello' }] }] }),
    'a file_search tool declared in an additional_tools input item': codexBody({ tools: undefined, input: [{ type: 'additional_tools', id: 'at_1', role: 'developer', tools: [{ type: 'file_search', vector_store_ids: ['vs_1'] }] }, { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'hello' }] }] }),
    'an image the vendor would fetch by URL': codexBody({ input: [{ type: 'message', role: 'user', content: [{ type: 'input_image', image_url: 'https://evil.example/?leak=1' }] }] }),
    'a file the vendor would fetch by URL': codexBody({ input: [{ type: 'message', role: 'user', content: [{ type: 'input_file', file_url: 'https://evil.example/x' }] }] }),
  };
  for (const [what, body] of Object.entries(refused)) {
    reply = await codex(body);
    check(`[B23] ${what} is refused with 400`, reply.status === 400 && errorType(reply).startsWith('sandbox_'), `${reply.status} ${reply.body}`);
  }
  reply = await call(port, { method: 'GET', urlPath: '/backend-api/wham/usage', headers: CODEX_HEADERS, body: '{"smuggled":true}' });
  check('[B23] a body on a route that takes none is refused with 400', reply.status === 400, `${reply.status}`);
  reply = await call(port, { urlPath: '/backend-api/codex/responses/compact', headers: CODEX_HEADERS, body: codexBody() });
  check('[B23] an unlisted Codex path is 404', reply.status === 404);
  check('[B23] ... and none of the refused requests reached the vendor', (await mock.requests()).length === 0);
  reply = await codex(codexBody({ tools: [{ type: 'namespace', name: 'ns', tools: [{ type: 'function', name: 'inner' }] }, { type: 'local_shell' }, { type: 'image_generation' }, { type: 'tool_search' }, { type: 'apply_patch' }, { type: 'web_search_preview' }], input: [{ type: 'message', role: 'user', content: [{ type: 'input_image', image_url: 'data:image/png;base64,AAAA' }] }] }));
  check('[B23] the tool types Codex uses, and an inline image, are let through', reply.status === 200, `${reply.status} ${reply.body.slice(0, 200)}`);
  reply = await codex(codexBody({ tools: undefined, input: [{ type: 'additional_tools', id: 'at_1', role: 'developer', tools: [{ type: 'namespace', name: 'functions', tools: [{ type: 'custom', name: 'exec' }, { type: 'function', name: 'wait' }] }, { type: 'web_search' }] }, { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'hello' }] }] }));
  check('[B23] the tools Codex 0.162 declares in an additional_tools input item are let through', reply.status === 200, `${reply.status} ${reply.body.slice(0, 200)}`);

  // Standalone web search: the CLI posts the queries to <provider>/alpha/search itself.
  const searchBody = (commands, input = [{ type: 'message', role: 'user', content: [{ type: 'input_text', text: 'look it up' }] }]) =>
    ({ id: 'search-session', model: 'gpt-mock-codex', input, commands, settings: { external_web_access: true }, max_output_tokens: 2500 });
  const search = (body) => call(port, { urlPath: '/backend-api/codex/alpha/search', headers: CODEX_HEADERS, body });
  await mock.reset();
  const before = (await sidecar.logged((e) => e.event === 'request' && typeof e.budget_left === 'number')).budget_left;
  reply = await search(searchBody({ search_query: [{ q: 'standalone search query' }, { q: 'a second query', recency: 7 }], image_query: [{ q: 'an image query' }], open: [{ ref_id: 'https://example.com/docs' }], find: [{ ref_id: 'turn0search0', pattern: 'install' }], weather: [{ location: 'Paris' }] }));
  seen = await mock.requests();
  check('[B23] Codex\'s standalone web search is forwarded to the vendor with the real credential', reply.status === 200 && reply.body.includes('search result from the mock') && seen.length === 1 && seen[0].headers.authorization === `Bearer ${REAL_CODEX}`, `${reply.status} ${reply.body.slice(0, 200)}`);
  const searchEntry = await sidecar.logged((e) => e.path === '/backend-api/codex/alpha/search' && e.status === 200);
  const kinds = (searchEntry?.web_search ?? []).map((s) => `${s.kind}:${s.query ?? s.url ?? s.pattern ?? ''}`);
  check('[B25] every query, page and pattern in a standalone search is in the log', kinds.includes('search:standalone search query') && kinds.includes('search:a second query') && kinds.includes('image_search:an image query') && kinds.includes('open_page:https://example.com/docs') && kinds.includes('find_in_page:turn0search0') && kinds.includes('weather:') && searchEntry.web_search.every((s) => s.from === 'request'), JSON.stringify(searchEntry));
  check('[B24] a standalone search uses one request of the budget', searchEntry?.budget_left === before - 1, `${before} -> ${searchEntry?.budget_left}`);
  reply = await search(searchBody({ search_query: [{ q: 'x' }] }, [{ type: 'message', role: 'user', content: [{ type: 'input_image', image_url: 'https://evil.example/?leak=1' }] }]));
  check('[B23] a standalone search carrying an image the vendor would fetch by URL is refused with 400', reply.status === 400 && errorType(reply).startsWith('sandbox_'), `${reply.status} ${reply.body}`);
  reply = await search('{"commands":');
  check('[B23] a standalone search that is not JSON is refused with 400', reply.status === 400, `${reply.status}`);
  await sidecar.stop();
}

async function apiKeyModes(mock) {
  section('API-key modes');
  const override = { SANDBOX_UPSTREAM_OVERRIDE: `http://127.0.0.1:${mock.port}` };

  await mock.reset();
  let sidecar = await startSidecar({ agent: 'claude', auth: 'apikey', env: override });
  await sidecar.load({ token: REAL_KEY });
  let reply = await call(sidecar.port, { urlPath: '/v1/messages?beta=true', headers: { ...CLAUDE_HEADERS, authorization: `Bearer ${DUMMY}`, 'x-api-key': DUMMY_KEY }, body: claudeBody() });
  let seen = await mock.requests();
  check('[B22] claude + apikey: the vendor received the real key in x-api-key and no Authorization header', reply.status === 200 && seen[0]?.headers['x-api-key'] === REAL_KEY && !('authorization' in seen[0].headers) && DUMMIES.every((d) => !JSON.stringify(seen).includes(d)), JSON.stringify(seen[0]?.headers));
  await sidecar.stop();

  await mock.reset();
  sidecar = await startSidecar({ agent: 'opencode', auth: 'apikey', env: override });
  await sidecar.load({ token: REAL_KEY });
  reply = await call(sidecar.port, { urlPath: '/v1/messages', headers: { 'content-type': 'application/json', 'anthropic-version': '2023-06-01', 'x-api-key': DUMMY_KEY }, body: claudeBody() });
  seen = await mock.requests();
  check('[B22] opencode + apikey: POST /v1/messages carries the real x-api-key', reply.status === 200 && seen[0]?.headers['x-api-key'] === REAL_KEY && seen[0].headers.host === 'api.anthropic.com' && !JSON.stringify(seen).includes(DUMMY_KEY), JSON.stringify(seen[0]?.headers));
  reply = await call(sidecar.port, { urlPath: '/v1/responses', headers: { 'content-type': 'application/json', authorization: `Bearer ${DUMMY}` }, body: codexBody() });
  check('[B22, B23] opencode: an OpenAI path is 404, so the Anthropic key is never sent to another vendor', reply.status === 404 && (await mock.requests()).length === 1);
  await sidecar.stop();

  await mock.reset();
  sidecar = await startSidecar({ agent: 'codex', auth: 'apikey', env: override });
  await sidecar.load({ token: REAL_OPENAI_KEY });
  reply = await call(sidecar.port, { urlPath: '/v1/responses', headers: CODEX_HEADERS, body: codexBody() });
  seen = await mock.requests();
  check('[B22] codex + apikey: /v1/responses goes to api.openai.com with the real key; the agent\'s account header is dropped', reply.status === 200 && seen[0]?.headers.authorization === `Bearer ${REAL_OPENAI_KEY}` && seen[0].headers.host === 'api.openai.com' && !('chatgpt-account-id' in seen[0].headers), JSON.stringify(seen[0]?.headers));
  reply = await call(sidecar.port, { urlPath: '/v1/chat/completions', headers: CODEX_HEADERS, body: { model: 'gpt-mock', messages: [{ role: 'user', content: 'hi' }], tools: [{ type: 'function', function: { name: 'f', parameters: {} } }] } });
  const models = await call(sidecar.port, { method: 'GET', urlPath: '/v1/models', headers: CODEX_HEADERS });
  check('codex + apikey: /v1/chat/completions and /v1/models are forwarded', reply.status === 200 && models.status === 200, `${reply.status} ${models.status}`);
  reply = await call(sidecar.port, { urlPath: '/v1/chat/completions', headers: CODEX_HEADERS, body: { model: 'gpt-mock', messages: [{ role: 'user', content: [{ type: 'image_url', image_url: { url: 'https://evil.example/?leak=1' } }] }] } });
  check('[B23] chat completions: an image the vendor would fetch by URL is refused', reply.status === 400, `${reply.status}`);
  reply = await call(sidecar.port, { method: 'GET', urlPath: '/backend-api/wham/accounts/check', headers: CODEX_HEADERS });
  check('[B23] codex + apikey: the ChatGPT paths are 404', reply.status === 404);
  await sidecar.stop();
}

async function refusalsToStart(mock) {
  section('Refusing to start');
  const override = { SANDBOX_UPSTREAM_OVERRIDE: `http://127.0.0.1:${mock.port}` };
  const cases = [
    ['opencode with oauth (it has no subscription mode)', { agent: 'opencode', auth: 'oauth', env: override }, 'no "oauth" credential mode'],
    ['an agent with no sidecar.json', { agent: 'nosuchagent', auth: 'oauth', env: override }, 'sidecar.json'],
    ['an agent name that is a path', { agent: '../claude', auth: 'oauth', env: override }, 'SANDBOX_AGENT'],
    ['a credential mode that is neither oauth nor apikey', { agent: 'claude', auth: 'token', env: override }, 'SANDBOX_AUTH'],
    ['a budget that is not a number', { agent: 'claude', auth: 'oauth', budget: 'lots', env: override }, 'SANDBOX_BUDGET'],
    ['no proxy and no test upstream', { agent: 'claude', auth: 'oauth' }, 'HTTPS_PROXY'],
    ['a test upstream that is not on loopback', { agent: 'claude', auth: 'oauth', env: { SANDBOX_UPSTREAM_OVERRIDE: 'http://192.0.2.1:80' } }, 'SANDBOX_UPSTREAM_OVERRIDE'],
  ];
  for (const [what, options, expect] of cases) {
    const sidecar = await startSidecar(options);
    const code = await Promise.race([sidecar.exited, sleep(3000).then(() => 'still running')]);
    check(`the sidecar refuses to start with ${what}`, typeof code === 'number' && code !== 0 && sidecar.stderr.includes(expect) && sidecar.port === 0, `exit ${code}: ${sidecar.stderr}`);
  }

  // A sidecar.json with a mistake in it stops the start, it is not half-used.
  const agentsDir = fs.mkdtempSync(path.join(tempRoot, 'agents-'));
  fs.mkdirSync(path.join(agentsDir, 'typo'));
  const doc = JSON.parse(fs.readFileSync(path.join(AGENTS, 'claude', 'sidecar.json'), 'utf8'));
  doc.modes.oauth.routes[0].modle = true;
  fs.writeFileSync(path.join(agentsDir, 'typo', 'sidecar.json'), JSON.stringify(doc));
  const sidecar = await startSidecar({ agent: 'typo', auth: 'oauth', env: { ...override, SANDBOX_AGENTS_DIR: agentsDir } });
  const code = await Promise.race([sidecar.exited, sleep(3000).then(() => 'still running')]);
  check('the sidecar refuses to start with an unknown key in sidecar.json', typeof code === 'number' && code !== 0 && sidecar.stderr.includes('unknown key modle'), `exit ${code}: ${sidecar.stderr}`);
}

async function upstreamDown() {
  section('Vendor unreachable');
  const closed = await new Promise((resolve) => {
    const probe = net.createServer().listen(0, '127.0.0.1', () => { const { port } = probe.address(); probe.close(() => resolve(port)); });
  });
  const sidecar = await startSidecar({ agent: 'claude', auth: 'oauth', env: { SANDBOX_UPSTREAM_OVERRIDE: `http://127.0.0.1:${closed}` } });
  await sidecar.load({ token: REAL_1 });
  const reply = await claude(sidecar.port, claudeBody());
  check('an upstream that cannot be reached gives 502 with a JSON error', reply.status === 502 && errorType(reply) === 'sandbox_upstream_failed', `${reply.status} ${reply.body}`);
  await sidecar.stop();
}

// The path used in a real session: an HTTP CONNECT through the proxy, then
// TLS to the vendor with ordinary certificate checking. Here the "proxy" is
// a few lines that record the CONNECT target and join the tunnel to a local
// TLS copy of the mock; the sidecar runs with no test override at all.
async function throughProxyWithTls() {
  section('Through a CONNECT proxy, with TLS');
  const writeFiles = (name) => {
    const dir = fs.mkdtempSync(path.join(tempRoot, 'tls-'));
    const { key, cert } = selfSigned(name);
    fs.writeFileSync(path.join(dir, 'key.pem'), key, { mode: 0o600 });
    fs.writeFileSync(path.join(dir, 'cert.pem'), cert);
    return { key: path.join(dir, 'key.pem'), cert: path.join(dir, 'cert.pem'), name };
  };
  const right = writeFiles('api.anthropic.com');
  const wrong = writeFiles('some-other-host.example');
  const vendor = await startMock(right);
  const impostor = await startMock(wrong);

  const targets = [];
  let tunnelTo = vendor.port;
  let refuse = false;
  const proxy = http.createServer((req, res) => { res.writeHead(405); res.end(); });
  proxy.on('connect', (req, client, head) => {
    targets.push(req.url);
    if (refuse) return client.end('HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n');
    const onward = net.connect(tunnelTo, '127.0.0.1', () => {
      client.write('HTTP/1.1 200 Connection established\r\n\r\n');
      if (head.length > 0) onward.write(head);
      onward.pipe(client);
      client.pipe(onward);
    });
    onward.on('error', () => client.destroy());
    client.on('error', () => onward.destroy());
  });
  await new Promise((resolve) => proxy.listen(0, '127.0.0.1', resolve));
  const proxyEnv = { HTTPS_PROXY: `http://127.0.0.1:${proxy.address().port}` };

  // The certificate is trusted and names the right host.
  let sidecar = await startSidecar({ agent: 'claude', auth: 'oauth', env: { ...proxyEnv, NODE_EXTRA_CA_CERTS: right.cert } });
  await sidecar.load({ token: REAL_TUNNEL });
  let reply = await claude(sidecar.port, claudeBody({ stream: true }));
  let seen = await vendor.requests();
  check('[B21] the sidecar asks the proxy for a tunnel to <upstream host>:443 and nothing else', targets.length === 1 && targets[0] === 'api.anthropic.com:443', targets.join(' '));
  check('[B22] through the tunnel, over TLS, the vendor received the real token and not the dummy', reply.status === 200 && seen.length === 1 && seen[0].headers.authorization === `Bearer ${REAL_TUNNEL}` && !JSON.stringify(seen).includes(DUMMY), `${reply.status} ${reply.body.slice(0, 200)}`);
  check('a streamed reply arrives intact through the tunnel', reply.body === claudeEvents(false).join(''));

  // The proxy says no (the host is not on the sidecar's allowlist).
  refuse = true;
  reply = await claude(sidecar.port, claudeBody());
  check('a tunnel the proxy refuses gives 502 with a JSON error', reply.status === 502 && errorType(reply) === 'sandbox_upstream_unreachable' && reply.body.includes('403'), `${reply.status} ${reply.body}`);
  refuse = false;

  // Trusted certificate, wrong host: someone else answers inside the tunnel.
  tunnelTo = impostor.port;
  await sidecar.stop();
  sidecar = await startSidecar({ agent: 'claude', auth: 'oauth', env: { ...proxyEnv, NODE_EXTRA_CA_CERTS: `${wrong.cert}` } });
  await sidecar.load({ token: REAL_TUNNEL });
  reply = await claude(sidecar.port, claudeBody());
  check('[B22] a server whose certificate names another host is refused (502) and is sent nothing', reply.status === 502 && (await impostor.requests()).length === 0, `${reply.status} ${reply.body}`);
  await sidecar.stop();

  // Right host name, but a certificate nobody vouches for.
  tunnelTo = vendor.port;
  await vendor.reset();
  sidecar = await startSidecar({ agent: 'claude', auth: 'oauth', env: proxyEnv });
  await sidecar.load({ token: REAL_TUNNEL });
  reply = await claude(sidecar.port, claudeBody());
  check('[B22] a server with an untrusted certificate is refused (502) and is sent nothing', reply.status === 502 && (await vendor.requests()).length === 0, `${reply.status} ${reply.body}`);
  await sidecar.stop();
  proxy.close();
}

function leakChecks() {
  section('Across every run above');
  const logs = sidecars.map((s) => s.stdout + s.stderr).join('\n');
  check('[B22] no real token appears in anything a sidecar sent back to the client', REAL_SECRETS.every((secret) => clientSaw.every((text) => !text.includes(secret))) && clientSaw.length > 100, `${clientSaw.length} replies examined`);
  check('[B22, B25] no real token appears in any sidecar log line', REAL_SECRETS.every((secret) => !logs.includes(secret)));
  check('[B22] sidecar-load never printed a credential', REAL_SECRETS.every((secret) => loaderSaid.every((text) => !text.includes(secret))));
  const lines = sidecars.flatMap((s) => s.lines());
  const notJson = lines.filter((line) => { try { return !JSON.parse(line).t; } catch { return true; } });
  check('[B25] every log line is one JSON object', notJson.length === 0 && lines.length > 50, notJson.slice(0, 3).join(' | '));
  check('[B25] every log line is printable ASCII and of bounded length (nothing the agent sent can draw on a terminal)', lines.every((line) => /^[\x20-\x7e]*$/.test(line) && line.length <= 16 * 1024));
}

// ---------------------------------------------------------------------------
const watchdog = setTimeout(() => { console.log('FAIL  the test run did not finish within 3 minutes'); cleanup(); process.exit(1); }, 180_000);
// [TLS] Codex with a subscription talks to the sidecar in HTTPS only.
async function tlsMode(mock) {
  section('TLS to the agent (Codex with a subscription)');
  await mock.reset();
  const name = 'sidecar.test';
  const { key, cert } = selfSigned(name);
  const sidecar = await startSidecar({
    agent: 'codex', auth: 'oauth', waitForStart: false,
    env: { SANDBOX_SIDECAR_TLS: '1', SANDBOX_UPSTREAM_OVERRIDE: `http://127.0.0.1:${mock.port}` },
  });
  await new Promise((resolve) => setTimeout(resolve, 400));
  check('[TLS] nothing listens before the key and certificate are loaded', sidecar.exitCode === undefined && !sidecar.events().some((e) => e.event === 'start'), sidecar.stdout);

  let result = await sidecar.load({ key: 'not a key', cert }, ['--tls']);
  check('[TLS] sidecar-load --tls refuses a key that is not one', result.code !== 0 && result.stderr.includes('nothing was stored') && !fs.existsSync(path.join(sidecar.stateDir, 'cred', 'tls.json')), `exit ${result.code}: ${result.stderr}`);
  result = await sidecar.load({ token: REAL_CODEX }, ['--tls']);
  check('[TLS] sidecar-load --tls refuses a credential in place of a key', result.code !== 0, result.stderr);
  result = await sidecar.load({ key, cert }, ['--tls']);
  check('[TLS] sidecar-load --tls stores a key and certificate', result.code === 0, result.stderr);
  check('[TLS] and does not print the key', !result.stdout.includes('PRIVATE KEY') && !result.stderr.includes('PRIVATE KEY'));
  const start = await sidecar.started();
  check('[TLS] the sidecar then listens, in TLS', start?.tls === true && sidecar.port > 0, JSON.stringify(start));

  const get = (mod, urlPath, extra = {}) => new Promise((resolve) => {
    const req = mod.request({ host: '127.0.0.1', port: sidecar.port, method: 'GET', path: urlPath, agent: false, timeout: 4000, ...extra }, (res) => {
      let text = '';
      res.on('data', (d) => { text += d; });
      res.on('end', () => resolve({ status: res.statusCode, body: text }));
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', (err) => resolve({ status: 0, error: err.code ?? err.message }));
    req.end();
  });
  const trusted = { ca: cert, servername: name };
  let reply = await get(https, '/healthz', trusted);
  check('[TLS] a client trusting the session certificate is answered', reply.status === 200, JSON.stringify(reply));
  reply = await get(https, '/healthz');
  check('[TLS] a client that does not trust it is refused by its own check', reply.status === 0, JSON.stringify(reply));
  reply = await get(http, '/healthz');
  check('[TLS] plain HTTP gets no answer', reply.status !== 200, JSON.stringify(reply));
  const healthy = await run(HEALTHCHECK, { SANDBOX_SIDECAR_LISTEN: `127.0.0.1:${sidecar.port}`, SANDBOX_SIDECAR_TLS: '1' });
  check('[TLS] sidecar-healthcheck speaks TLS to a TLS sidecar', healthy.code === 0, healthy.stderr);
  const plainCheck = await run(HEALTHCHECK, { SANDBOX_SIDECAR_LISTEN: `127.0.0.1:${sidecar.port}` });
  check('[TLS] and a plain-HTTP health check of it fails', plainCheck.code !== 0, plainCheck.stderr);

  await sidecar.load({ token: REAL_CODEX, account_id: REAL_ACCOUNT });
  reply = await get(https, '/backend-api/wham/accounts/check', { ...trusted, headers: CODEX_HEADERS });
  const last = (await mock.requests()).pop();
  check('[TLS][B22] a request over TLS reaches the vendor with the real token', reply.status === 200 && last?.headers.authorization === `Bearer ${REAL_CODEX}` && last?.headers['chatgpt-account-id'] === REAL_ACCOUNT, `${JSON.stringify(reply)} ${last?.headers.authorization}`);
  await sidecar.stop();

  // A TLS file that is not private stops the sidecar; it never falls back
  // to plain HTTP.
  const loose = await startSidecar({
    agent: 'codex', auth: 'oauth', waitForStart: false,
    env: { SANDBOX_SIDECAR_TLS: '1', SANDBOX_UPSTREAM_OVERRIDE: `http://127.0.0.1:${mock.port}` },
  });
  await waitFor(() => loose.exitCode !== undefined || loose.events().some((e) => e.event === 'tls'));
  check('[TLS] a TLS sidecar says it is waiting for its key', loose.events().some((e) => e.event === 'tls'), `exit ${loose.exitCode}: ${loose.stderr}`);
  const file = path.join(loose.stateDir, 'cred', 'tls.json');
  fs.writeFileSync(file, JSON.stringify({ key, cert }), { mode: 0o644 });
  fs.chmodSync(file, 0o644);
  await waitFor(() => loose.exitCode !== undefined);
  check('[TLS] a TLS file others can read stops the sidecar, and it never listens', loose.exitCode !== undefined && loose.exitCode !== 0 && !loose.events().some((e) => e.event === 'start'), `exit ${loose.exitCode}: ${loose.stderr}`);
}

function cleanup() {
  for (const child of children) child.kill('SIGKILL');
  fs.rmSync(tempRoot, { recursive: true, force: true });
}

try {
  const mock = await startMock();
  await claudeOauth(mock);
  await budgetAndLogCap(mock);
  await codexOauth(mock);
  await tlsMode(mock);
  await apiKeyModes(mock);
  await refusalsToStart(mock);
  await upstreamDown();
  await throughProxyWithTls();
  leakChecks();
} catch (err) {
  failed += 1;
  console.log(`FAIL  the test run stopped early: ${err.stack ?? err}`);
}
clearTimeout(watchdog);
cleanup();
console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
