// The relay as an HTTP server, fed hand-made requests, in front of a mock
// upstream that records what reaches it. No git involved: `node --test`.
// Proves what the relay sends upstream (the token, the fixed path, the exact
// bytes it filtered) and what it sends back.  [logical B30]

import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import zlib from 'node:zlib';

import { createRelay, loadConfig, pkt } from '../../images/gitrelay/relay.mjs';

const BRANCH = 'agent/asb-demo-0a1b2c';
const REF = `refs/heads/${BRANCH}`;
const ZERO = '0'.repeat(40);
const OLD = 'a'.repeat(40);
const NEW = 'b'.repeat(40);
const CAPS = ' report-status-v2 side-band-64k object-format=sha1 agent=git/2.39.5';
const FLUSH = Buffer.from('0000');
const TOKEN = 'relaytest_REAL_TOKEN_5f3c9a';
const AUTHORIZATION = `Basic ${Buffer.from(`x-access-token:${TOKEN}`).toString('base64')}`;
const UPSTREAM_REPLY = Buffer.from('mock upstream reply');

function pushBody(commands, pack = Buffer.from('PACK-not-really')) {
  const lines = commands.map((command, index) => pkt(index === 0 ? `${command}\0${CAPS}` : command));
  return Buffer.concat([...lines, FLUSH, pack]);
}

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve(server.address().port));
  });
}

// One request to the relay; `body` may be a Buffer or a list of Buffers sent
// as separate chunks.
function ask(port, { method = 'GET', url, headers = {}, body = null }) {
  return new Promise((resolve, reject) => {
    const request = http.request({ host: '127.0.0.1', port, method, path: url, headers, agent: false }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => resolve({ status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks) }));
    });
    request.on('error', reject);
    if (Array.isArray(body)) {
      for (const chunk of body) request.write(chunk);
      request.end();
    } else {
      request.end(body);
    }
  });
}

let runDir;
let upstream;
let relay;
let relayPort;
let seen = [];      // every request the mock upstream received
let logged = [];    // every log entry the relay wrote
let upstreamAnswer = null;   // set by a test to change the mock's answer
let arrivedUpstream = 0;     // body bytes the mock upstream has received so far

test.before(async () => {
  runDir = fs.mkdtempSync(path.join(os.tmpdir(), 'gitrelay-http-'));
  upstream = http.createServer((request, response) => {
    const chunks = [];
    request.on('data', (chunk) => {
      chunks.push(chunk);
      arrivedUpstream += chunk.length;
    });
    request.on('end', () => {
      seen.push({ method: request.method, url: request.url, headers: request.headers, body: Buffer.concat(chunks) });
      if (upstreamAnswer) {
        upstreamAnswer(response);
        return;
      }
      response.writeHead(200, {
        'Content-Type': 'application/x-git-receive-pack-result',
        'Cache-Control': 'no-cache',
        'Set-Cookie': 'session=upstream-cookie',
        'X-Upstream-Secret': 'do-not-pass',
      });
      response.end(UPSTREAM_REPLY);
    });
  });
  const upstreamPort = await listen(upstream);
  const config = loadConfig({
    RELAY_UPSTREAM_OVERRIDE: `http://127.0.0.1:${upstreamPort}/owner/project.git/`,
    RELAY_BRANCH: BRANCH,
    RELAY_RUN_DIR: runDir,
  });
  relay = createRelay(config, (entry) => logged.push(entry));
  relayPort = await listen(relay);
});

test.after(() => {
  relay.close();
  upstream.close();
  relay.closeAllConnections();
  upstream.closeAllConnections();
  fs.rmSync(runDir, { recursive: true, force: true });
});

test.beforeEach(() => {
  seen = [];
  logged = [];
  upstreamAnswer = null;
  arrivedUpstream = 0;
});

function storeToken(token = TOKEN) {
  fs.writeFileSync(path.join(runDir, 'credential.json'), JSON.stringify({ token, username: 'x-access-token' }), { mode: 0o600 });
}

// The log entry is written when the connection closes, a moment after the
// client has its answer.
async function lastLog() {
  for (let i = 0; i < 200 && logged.length === 0; i += 1) await new Promise((resolve) => setTimeout(resolve, 5));
  assert.equal(logged.length, 1, 'one log entry per request');
  return logged[0];
}

test('before a token is loaded every route answers 503, not 401', async () => {
  for (const request of [
    { url: '/x.git/info/refs?service=git-upload-pack' },
    { url: '/x.git/info/refs?service=git-receive-pack' },
    { method: 'POST', url: '/x.git/git-upload-pack', body: Buffer.from('0000') },
    { method: 'POST', url: '/x.git/git-receive-pack', body: pushBody([`${OLD} ${NEW} ${REF}`]) },
  ]) {
    const answer = await ask(relayPort, request);
    assert.equal(answer.status, 503, request.url);
    assert.match(answer.body.toString(), /no token has been loaded/);
  }
  assert.equal(seen.length, 0);
});

test('anything but the four routes is 404 and never reaches the upstream', async () => {
  storeToken();
  for (const request of [
    { url: '/' },
    { url: '/x.git/info/refs' },
    { url: '/x.git/info/refs?service=git-upload-archive' },
    { url: '/x.git/HEAD' },
    { url: '/x.git/objects/info/packs' },
    { url: '/x.git/info/lfs/objects/batch', method: 'POST', body: Buffer.from('{}') },
    { url: '/x.git/git-upload-pack' },
    { url: '/x.git/git-receive-pack' },
    { url: '/x.git/info/refs?service=git-receive-pack', method: 'POST', body: Buffer.from('0000') },
    { url: '/x.git/git-receive-pack', method: 'PUT', body: Buffer.from('0000') },
    { url: '/x.git/git-receive-pack/more', method: 'POST', body: Buffer.from('0000') },
  ]) {
    const answer = await ask(relayPort, request);
    assert.equal(answer.status, 404, `${request.method || 'GET'} ${request.url}`);
  }
  assert.equal(seen.length, 0);
});

test('fetch: forwarded to the fixed upstream path with the token; the agent\'s own credential is dropped', async () => {
  storeToken();
  const answer = await ask(relayPort, {
    url: '/some/other/repo.git/info/refs?service=git-upload-pack&extra=1',
    headers: { Authorization: 'Bearer agent-brought-this', Cookie: 'a=b', 'Git-Protocol': 'version=2', 'User-Agent': 'git/2.39.5', 'X-Forwarded-For': '10.0.0.3' },
  });
  assert.equal(answer.status, 200);
  assert.deepEqual(answer.body, UPSTREAM_REPLY);
  assert.equal(seen.length, 1);
  assert.equal(seen[0].url, '/owner/project.git/info/refs?service=git-upload-pack');
  assert.equal(seen[0].headers.authorization, AUTHORIZATION);
  assert.equal(seen[0].headers['git-protocol'], 'version=2');
  assert.equal(seen[0].headers['user-agent'], 'git/2.39.5');
  assert.equal(seen[0].headers.cookie, undefined);
  assert.equal(seen[0].headers['x-forwarded-for'], undefined);
  // Only the listed response headers come back.
  assert.equal(answer.headers['set-cookie'], undefined);
  assert.equal(answer.headers['x-upstream-secret'], undefined);
  assert.equal(answer.headers['content-type'], 'application/x-git-receive-pack-result');
});

test('fetch: the request body, gzip included, is passed through unchanged', async () => {
  storeToken();
  const plain = Buffer.concat([pkt('command=fetch\n'), Buffer.from('0001'), pkt(`want ${NEW}\n`), FLUSH]);
  const zipped = zlib.gzipSync(plain);
  const answer = await ask(relayPort, {
    method: 'POST',
    url: '/x.git/git-upload-pack',
    headers: { 'Content-Encoding': 'gzip', 'Content-Length': String(zipped.length), 'Git-Protocol': 'version=2' },
    body: zipped,
  });
  assert.equal(answer.status, 200);
  assert.equal(seen[0].url, '/owner/project.git/git-upload-pack');
  assert.equal(seen[0].headers['content-encoding'], 'gzip');
  assert.equal(seen[0].headers['content-type'], 'application/x-git-upload-pack-request');
  assert.equal(seen[0].headers['git-protocol'], 'version=2');
  assert.deepEqual(seen[0].body, zipped);
});

test('push: the allowed branch is forwarded byte for byte, with the token', async () => {
  storeToken();
  const body = pushBody([`${OLD} ${NEW} ${REF}`]);
  const answer = await ask(relayPort, {
    method: 'POST',
    url: '/attacker/elsewhere.git/git-receive-pack?x=y',
    headers: { 'Content-Length': String(body.length), Authorization: 'Basic YWdlbnQ6YWdlbnQ=', 'Git-Protocol': 'version=2' },
    body,
  });
  assert.equal(answer.status, 200);
  assert.deepEqual(answer.body, UPSTREAM_REPLY);
  assert.equal(seen.length, 1);
  assert.equal(seen[0].url, '/owner/project.git/git-receive-pack');
  assert.equal(seen[0].headers.authorization, AUTHORIZATION);
  assert.equal(seen[0].headers['content-length'], String(body.length));
  assert.equal(seen[0].headers['git-protocol'], undefined, 'a push is always sent upstream in the format the filter reads');
  assert.deepEqual(seen[0].body, body);
  const entry = await lastLog();
  assert.equal(entry.verdict, 'allow');
  assert.equal(entry.status, 200);
  assert.deepEqual(entry.commands, [{ old: OLD, new: NEW, ref: REF }]);
});

test('push: a gzip body is unpacked, filtered, and sent upstream unpacked', async () => {
  storeToken();
  const body = pushBody([`${ZERO} ${NEW} ${REF}`], crypto.randomBytes(200000));
  const answer = await ask(relayPort, {
    method: 'POST',
    url: '/x.git/git-receive-pack',
    headers: { 'Content-Encoding': 'gzip' },
    body: zlib.gzipSync(body),
  });
  assert.equal(answer.status, 200);
  assert.equal(seen[0].headers['content-encoding'], undefined);
  assert.equal(seen[0].headers['transfer-encoding'], 'chunked');
  assert.deepEqual(seen[0].body, body);
});

test('push: gzip does not hide a refused ref', async () => {
  storeToken();
  const body = pushBody([`${OLD} ${NEW} refs/heads/main`]);
  const answer = await ask(relayPort, {
    method: 'POST',
    url: '/x.git/git-receive-pack',
    headers: { 'Content-Encoding': 'gzip' },
    body: zlib.gzipSync(body),
  });
  assert.equal(answer.status, 200);
  assert.equal(answer.headers['content-type'], 'application/x-git-receive-pack-result');
  assert.match(answer.body.toString('latin1'), /ng refs\/heads\/main only refs\/heads\/agent\/asb-demo-0a1b2c may be pushed/);
  assert.equal(seen.length, 0, 'the upstream was never contacted');
  const entry = await lastLog();
  assert.equal(entry.verdict, 'refuse');
  assert.deepEqual(entry.commands, [{ old: OLD, new: NEW, ref: 'refs/heads/main' }]);
});

test('push: a second gzip member cannot carry a different command list past the filter', async () => {
  storeToken();
  // Two gzip streams back to back. Whatever a reader makes of that, the
  // upstream gets the unpacked bytes the filter saw, never the original.
  const good = zlib.gzipSync(pushBody([`${OLD} ${NEW} ${REF}`], Buffer.alloc(0)));
  const bad = zlib.gzipSync(pushBody([`${OLD} ${NEW} refs/heads/main`]));
  const answer = await ask(relayPort, {
    method: 'POST',
    url: '/x.git/git-receive-pack',
    headers: { 'Content-Encoding': 'gzip' },
    body: Buffer.concat([good, bad]),
  });
  assert.equal(answer.status, 200);
  assert.equal(seen.length, 1);
  assert.equal(seen[0].headers['content-encoding'], undefined);
  // The first flush packet ends the commands for the upstream as it did for
  // the filter; what follows is pack data to it.
  const firstFlush = seen[0].body.indexOf('0000');
  assert.equal(seen[0].body.subarray(0, firstFlush + 4).toString('latin1'), pushBody([`${OLD} ${NEW} ${REF}`], Buffer.alloc(0)).toString('latin1'));
});

test('push: tag, delete, other branch, mixed, push options: refused, upstream never contacted', async () => {
  storeToken();
  const cases = [
    [[`${ZERO} ${NEW} refs/tags/v1`], /tags may not be pushed/],
    [[`${OLD} ${ZERO} ${REF}`], /deleting a ref is not allowed/],
    [[`${OLD} ${NEW} refs/heads/main`], /only refs\/heads\/agent/],
    [[`${OLD} ${NEW} ${REF}`, `${OLD} ${NEW} refs/heads/main`], /another ref in the same push was refused/],
  ];
  for (const [commands, expected] of cases) {
    const answer = await ask(relayPort, { method: 'POST', url: '/x.git/git-receive-pack', body: pushBody(commands) });
    assert.equal(answer.status, 200, commands[0]);
    assert.match(answer.body.toString('latin1'), expected);
    assert.doesNotMatch(answer.body.toString('latin1'), /\nok /);
  }
  const options = Buffer.concat([pkt(`${OLD} ${NEW} ${REF}\0${CAPS} push-options`), FLUSH, pkt('ci.skip'), FLUSH]);
  const answer = await ask(relayPort, { method: 'POST', url: '/x.git/git-receive-pack', body: options });
  assert.match(answer.body.toString('latin1'), /push options are not allowed/);
  assert.equal(seen.length, 0);
});

test('push: truncated, oversized and non-gzip bodies are 400 and never reach the upstream', async () => {
  storeToken();
  const whole = pushBody([`${OLD} ${NEW} ${REF}`], Buffer.alloc(0));
  const cases = [
    [{ body: whole.subarray(0, 50) }, /ended before the end of its ref lines/],
    [{ body: whole.subarray(0, whole.length - 4) }, /ended before the end of its ref lines/],
    [{ body: Buffer.alloc(0) }, /ended before the end of its ref lines/],
    [{ body: Buffer.concat([Buffer.from('ffff'), Buffer.alloc(70000, 0x41)]) }, /longer than git allows/],
    [{ body: whole, headers: { 'Content-Encoding': 'gzip' } }, /not valid gzip/],
    [{ body: zlib.gzipSync(whole).subarray(0, 20), headers: { 'Content-Encoding': 'gzip' } }, /ended before|not valid gzip/],
  ];
  for (const [request, expected] of cases) {
    const answer = await ask(relayPort, { method: 'POST', url: '/x.git/git-receive-pack', ...request });
    assert.equal(answer.status, 400);
    assert.match(answer.body.toString(), expected);
  }
  const deflated = await ask(relayPort, { method: 'POST', url: '/x.git/git-receive-pack', headers: { 'Content-Encoding': 'deflate' }, body: whole });
  assert.equal(deflated.status, 415);
  assert.equal(seen.length, 0);
});

test('push: a large pack is streamed through intact, in pieces', async () => {
  storeToken();
  const pack = crypto.randomBytes(8 << 20);
  const head = pushBody([`${OLD} ${NEW} ${REF}`], Buffer.alloc(0));
  // The ref lines split across two writes, then the pack in 64 KB pieces.
  const pieces = [head.subarray(0, 10), head.subarray(10)];
  for (let at = 0; at < pack.length; at += 65536) pieces.push(pack.subarray(at, at + 65536));
  const answer = await ask(relayPort, { method: 'POST', url: '/x.git/git-receive-pack', body: pieces });
  assert.equal(answer.status, 200);
  assert.equal(seen[0].body.length, head.length + pack.length);
  assert.equal(
    crypto.createHash('sha256').update(seen[0].body).digest('hex'),
    crypto.createHash('sha256').update(head).update(pack).digest('hex'),
  );
});

test('push: the pack is not buffered: it reaches the upstream while the client is still sending', async () => {
  storeToken();
  const head = pushBody([`${OLD} ${NEW} ${REF}`], Buffer.alloc(0));
  const firstHalf = crypto.randomBytes(1 << 20);
  const answer = await new Promise((resolve, reject) => {
    const request = http.request({ host: '127.0.0.1', port: relayPort, method: 'POST', path: '/x.git/git-receive-pack', agent: false }, (response) => {
      response.resume();
      response.on('end', () => resolve(response.statusCode));
    });
    request.on('error', reject);
    request.write(head);
    request.write(firstHalf);
    // The request is left open. Only once the upstream holds everything sent
    // so far is the rest sent; a relay that buffered would never get there.
    const timer = setInterval(() => {
      if (arrivedUpstream < head.length + firstHalf.length) return;
      clearInterval(timer);
      request.end(Buffer.from('the rest'));
    }, 5);
  });
  assert.equal(answer, 200);
  assert.equal(seen[0].body.length, head.length + firstHalf.length + 8);
});

test('push: a refused push with a large pack still gets its refusal', async () => {
  storeToken();
  const body = pushBody([`${OLD} ${NEW} refs/heads/main`], crypto.randomBytes(8 << 20));
  const answer = await ask(relayPort, { method: 'POST', url: '/x.git/git-receive-pack', headers: { 'Content-Length': String(body.length) }, body });
  assert.equal(answer.status, 200);
  assert.match(answer.body.toString('latin1'), /ng refs\/heads\/main/);
  assert.equal(seen.length, 0);
});

test('an upstream 401 becomes 403 with a message for the operator; no challenge reaches git', async () => {
  storeToken();
  upstreamAnswer = (response) => {
    response.writeHead(401, { 'WWW-Authenticate': 'Basic realm="GitHub"' });
    response.end('Bad credentials');
  };
  const answer = await ask(relayPort, { url: '/x.git/info/refs?service=git-receive-pack' });
  assert.equal(answer.status, 403);
  assert.equal(answer.headers['www-authenticate'], undefined);
  assert.match(answer.body.toString(), /rejected the relay's token/);
});

test('an upstream redirect is not followed and not passed on', async () => {
  storeToken();
  upstreamAnswer = (response) => {
    response.writeHead(301, { Location: 'https://elsewhere.example/repo.git/info/refs?service=git-upload-pack' });
    response.end();
  };
  const answer = await ask(relayPort, { url: '/x.git/info/refs?service=git-upload-pack' });
  assert.equal(answer.status, 502);
  assert.equal(answer.headers.location, undefined);
  assert.equal(seen.length, 1);
});

test('a replaced token is used from the next request on, without a restart', async () => {
  storeToken('first_token_aaaa');
  await ask(relayPort, { url: '/x.git/info/refs?service=git-upload-pack' });
  storeToken('second_token_bbbb');
  await ask(relayPort, { url: '/x.git/info/refs?service=git-upload-pack' });
  assert.equal(seen[0].headers.authorization, `Basic ${Buffer.from('x-access-token:first_token_aaaa').toString('base64')}`);
  assert.equal(seen[1].headers.authorization, `Basic ${Buffer.from('x-access-token:second_token_bbbb').toString('base64')}`);
});

test('the log has the fields promised and never a credential', async () => {
  storeToken();
  await ask(relayPort, {
    method: 'POST',
    url: '/x.git/git-receive-pack',
    headers: { Authorization: 'Bearer agent-brought-this' },
    body: pushBody([`${OLD} ${NEW} ${REF}`]),
  });
  const entry = await lastLog();
  assert.deepEqual(Object.keys(entry), ['time', 'method', 'path', 'commands', 'verdict', 'reason', 'status', 'ms']);
  const text = JSON.stringify(entry);
  for (const secret of [TOKEN, AUTHORIZATION, Buffer.from(`x-access-token:${TOKEN}`).toString('base64'), 'agent-brought-this']) {
    assert.equal(text.includes(secret), false);
  }
});

test('configuration: refuses anything but one https repository and one branch', () => {
  const good = { RELAY_UPSTREAM: 'https://github.com/owner/project.git', RELAY_BRANCH: BRANCH, HTTPS_PROXY: 'http://10.89.0.2:3128' };
  assert.equal(loadConfig(good).basePath, '/owner/project.git');
  const bad = [
    { RELAY_UPSTREAM: '' },
    { RELAY_UPSTREAM: 'http://github.com/owner/project.git' },
    { RELAY_UPSTREAM: 'ssh://git@github.com/owner/project.git' },
    { RELAY_UPSTREAM: 'https://x-access-token:secret@github.com/owner/project.git' },
    { RELAY_UPSTREAM: 'https://github.com/owner/project.git?a=b' },
    { RELAY_UPSTREAM: 'https://140.82.112.3/owner/project.git' },
    { RELAY_UPSTREAM: 'https://[::1]/owner/project.git' },
    { RELAY_BRANCH: '' },
    { RELAY_BRANCH: 'a b' },
    { RELAY_BRANCH: 'a..b' },
    { RELAY_BRANCH: 'refs/heads/*' },
    { RELAY_BRANCH: '-x' },
    { RELAY_BRANCH: 'x.lock' },
    { HTTPS_PROXY: '' },
    { HTTPS_PROXY: 'https://10.89.0.2:3128' },
    { RELAY_UPSTREAM_OVERRIDE: 'https://127.0.0.1:1/x.git' },
  ];
  for (const change of bad) {
    assert.throws(() => loadConfig({ ...good, ...change }), Error, JSON.stringify(change));
  }
});
