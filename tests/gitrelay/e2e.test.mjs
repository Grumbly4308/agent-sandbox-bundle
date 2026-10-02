// End to end: the real `git` client, through the relay (started as its own
// process, the way the container starts it), to a real repository served by
// `git http-backend`. `node --test`.  [logical B30]
//
// The mock upstream demands the real token and records every Authorization
// header it is sent. The "agent" side is a clone made through the relay with
// no credential of any kind.
//
// The second half runs the relay the way it runs in a session: HTTPS to the
// upstream through a CONNECT proxy (a mock one, standing in for Squid).

import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { execFile, spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { startMockUpstream } from './mock-upstream.mjs';

const IMAGE_DIR = fileURLToPath(new URL('../../images/gitrelay/', import.meta.url));
const BRANCH = 'agent/asb-demo-0a1b2c';
const TOKEN = 'ghp_relaytestREALTOKEN5f3c9a7e';
const AUTHORIZATION = `Basic ${Buffer.from(`x-access-token:${TOKEN}`).toString('base64')}`;
const SECRETS = [TOKEN, Buffer.from(`x-access-token:${TOKEN}`).toString('base64')];

function found(program, args) {
  const result = spawnSync(program, args, { encoding: 'utf8' });
  return result.status === 0 ? result.stdout.trim() : '';
}
const execPath = found('git', ['--exec-path']);
const haveBackend = execPath !== '' && fs.existsSync(path.join(execPath, 'git-http-backend'));
const haveOpenssl = found('openssl', ['version']) !== '';
const skipAll = haveBackend ? false : 'git http-backend is not installed here: the end-to-end path is UNPROVEN on this machine';
const skipTls = skipAll || (haveOpenssl ? false : 'openssl is not installed here: the HTTPS-through-proxy path is UNPROVEN on this machine');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'gitrelay-e2e-'));
const upstreamRoot = path.join(tmp, 'upstream');
const bare = path.join(upstreamRoot, 'repo.git');
const agentDir = path.join(tmp, 'agent');
const children = [];
const servers = [];

// A git that reads no configuration of this machine's, uses no proxy, and
// fails instead of asking for a password.
const gitEnv = {
  PATH: process.env.PATH,
  HOME: path.join(tmp, 'home'),
  GIT_CONFIG_NOSYSTEM: '1',
  GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_TERMINAL_PROMPT: '0',
  GIT_AUTHOR_NAME: 'Test', GIT_AUTHOR_EMAIL: 'test@example.invalid',
  GIT_COMMITTER_NAME: 'Test', GIT_COMMITTER_EMAIL: 'test@example.invalid',
};

// Never the blocking kind of spawn for git: the mock upstream lives in this
// process and has to answer while git runs.
function git(args, cwd = tmp) {
  return new Promise((resolve) => {
    execFile('git', args, { cwd, env: gitEnv, encoding: 'utf8', timeout: 60000, maxBuffer: 1 << 26 }, (error, stdout, stderr) => {
      let status = 0;
      if (error) status = typeof error.code === 'number' ? error.code : -1;
      resolve({ status, stdout, stderr, all: `${stdout}${stderr}` });
    });
  });
}

async function gitOk(args, cwd = tmp) {
  const result = await git(args, cwd);
  assert.equal(result.status, 0, `git ${args.join(' ')}\n${result.all}`);
  return result.stdout.trim();
}

async function upstreamRef(ref) {
  return (await git(['rev-parse', '--verify', '--quiet', ref], bare)).stdout.trim();
}

async function commit(cwd, file, content, message) {
  fs.writeFileSync(path.join(cwd, file), content);
  await gitOk(['add', file], cwd);
  await gitOk(['commit', '-q', '-m', message], cwd);
  return gitOk(['rev-parse', 'HEAD'], cwd);
}

// Starts relay.mjs as a process and waits for its "listening" line.
function startRelay(name, env) {
  const runDir = path.join(tmp, `run-${name}`);
  fs.mkdirSync(runDir, { mode: 0o700 });
  const relay = { runDir, log: '', port: 0, child: null };
  relay.child = spawn(process.execPath, [path.join(IMAGE_DIR, 'relay.mjs')], {
    env: { PATH: process.env.PATH, RELAY_BRANCH: BRANCH, RELAY_LISTEN: '127.0.0.1:0', RELAY_RUN_DIR: runDir, ...env },
    stdio: ['ignore', 'pipe', 'inherit'],
  });
  children.push(relay.child);
  return new Promise((resolve, reject) => {
    relay.child.once('exit', (code) => reject(new Error(`relay exited with ${code}`)));
    relay.child.stdout.on('data', (chunk) => {
      relay.log += chunk.toString('utf8');
      if (relay.port === 0 && relay.log.includes('\n')) {
        relay.port = JSON.parse(relay.log.slice(0, relay.log.indexOf('\n'))).port;
        resolve(relay);
      }
    });
  });
}

// The relay's log entries, once the entry for the last request is in.
async function entries(relay) {
  await new Promise((resolve) => setTimeout(resolve, 100));
  return relay.log.trim().split('\n').map((line) => JSON.parse(line)).filter((entry) => entry.event === undefined);
}

function loadToken(relay, input) {
  return spawnSync(path.join(IMAGE_DIR, 'relay-load'), [], {
    env: { PATH: process.env.PATH, RELAY_RUN_DIR: relay.runDir },
    input,
    encoding: 'utf8',
  });
}

let upstream;
let relay;
let remote;
let mainAtStart;

test.after(() => {
  for (const child of children) child.kill('SIGKILL');
  for (const server of servers) {
    server.close();
    server.closeAllConnections?.();
  }
  fs.rmSync(tmp, { recursive: true, force: true });
});

test('setup: a repository on the mock git host, and the relay in front of it', { skip: skipAll }, async () => {
  fs.mkdirSync(gitEnv.HOME);
  fs.mkdirSync(upstreamRoot);
  const seed = path.join(tmp, 'seed');
  await gitOk(['init', '-q', '-b', 'main', seed]);
  mainAtStart = await commit(seed, 'README.md', 'seed\n', 'seed');
  // Forty branches with a commit each, so that a clone has enough to ask for
  // that git compresses its request.
  for (let i = 0; i < 40; i += 1) {
    await gitOk(['checkout', '-q', '-b', `topic/${i}`, 'main'], seed);
    await commit(seed, `topic-${i}.txt`, `${i}\n`, `topic ${i}`);
  }
  await gitOk(['checkout', '-q', 'main'], seed);
  await gitOk(['clone', '-q', '--bare', seed, bare]);
  // So that a client is allowed to ask for push options at all; the relay
  // must then refuse them.
  await gitOk(['config', 'receive.advertisePushOptions', 'true'], bare);

  upstream = await startMockUpstream({ root: upstreamRoot, authorization: AUTHORIZATION });
  servers.push(upstream.server);
  relay = await startRelay('plain', { RELAY_UPSTREAM_OVERRIDE: `http://127.0.0.1:${upstream.port}/repo.git` });
  remote = `http://127.0.0.1:${relay.port}/any/name/at/all.git`;
});

test('the health check answers once the relay listens', { skip: skipAll }, async () => {
  const env = { PATH: process.env.PATH, RELAY_LISTEN: `127.0.0.1:${relay.port}` };
  assert.equal(spawnSync(path.join(IMAGE_DIR, 'gitrelay-healthcheck'), [], { env }).status, 0);
  assert.equal(spawnSync(path.join(IMAGE_DIR, 'gitrelay-healthcheck'), [], { env: { ...env, RELAY_LISTEN: '127.0.0.1:1' } }).status, 1);
});

test('before the token is loaded, git is told so and is not asked for a password', { skip: skipAll }, async () => {
  const result = await git(['ls-remote', remote]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /503/);
  assert.match(result.stderr, /no token has been loaded/);
  assert.equal(upstream.seen.length, 0);
});

test('relay-load: refuses bad input without echoing it, stores good input 0600', { skip: skipAll }, async () => {
  for (const input of ['', 'not json SECRETINPUT', '["SECRETINPUT"]', '{"token":""}', '{"token":"has space SECRETINPUT"}',
    '{"token":"SECRETINPUT","username":"a:b"}', '{"token":"line\\nbreak-SECRETINPUT"}', '{"username":"SECRETINPUT"}']) {
    const result = loadToken(relay, input);
    assert.equal(result.status, 1, input);
    assert.equal(`${result.stdout}${result.stderr}`.includes('SECRETINPUT'), false, input);
  }
  assert.equal(fs.existsSync(path.join(relay.runDir, 'credential.json')), false);

  const result = loadToken(relay, JSON.stringify({ token: TOKEN, username: 'x-access-token' }));
  assert.equal(result.status, 0, result.stderr);
  assert.equal(`${result.stdout}${result.stderr}`.includes(TOKEN), false);
  const stored = path.join(relay.runDir, 'credential.json');
  assert.equal(fs.statSync(stored).mode & 0o777, 0o600);
  assert.deepEqual(fs.readdirSync(relay.runDir), ['credential.json'], 'no scratch file left behind');
});

test('clone through the relay (protocol v2), with no credential on the agent side', { skip: skipAll }, async () => {
  await gitOk(['clone', '-q', remote, agentDir]);
  assert.equal(await gitOk(['rev-parse', 'origin/main'], agentDir), mainAtStart);
  assert.equal(await gitOk(['rev-parse', 'origin/topic/39'], agentDir), await upstreamRef('refs/heads/topic/39'));

  // The upstream got the real token on every request...
  assert.ok(upstream.seen.length >= 2);
  assert.ok(upstream.seen.every((request) => request.authorization === AUTHORIZATION));
  // ...on the configured repository's path, whatever path the agent used...
  assert.ok(upstream.seen.every((request) => request.path.startsWith('/repo.git/')));
  // ...with git's protocol v2 header passed through.
  assert.ok(upstream.seen.every((request) => request.gitProtocol === 'version=2'));

  // The agent side holds nothing: not in the remote URL, not anywhere in the clone.
  assert.equal(await gitOk(['config', '--get', 'remote.origin.url'], agentDir), remote);
  const config = fs.readFileSync(path.join(agentDir, '.git', 'config'), 'utf8');
  for (const secret of SECRETS) assert.equal(config.includes(secret), false);
  assert.equal(spawnSync('grep', ['-r', '-l', '-e', TOKEN, agentDir, gitEnv.HOME]).status, 1, 'the token is nowhere on the agent side');
});

test('fetch: a gzip-compressed request from git passes through', { skip: skipAll }, async () => {
  const compressed = upstream.seen.filter((request) => request.path === '/repo.git/git-upload-pack' && request.contentEncoding === 'gzip');
  assert.ok(compressed.length >= 1, 'git compressed at least one fetch request and the upstream accepted it');
});

test('clone through the relay with the older protocol (v0)', { skip: skipAll }, async () => {
  const before = upstream.seen.length;
  const target = path.join(tmp, 'agent-v0');
  await gitOk(['-c', 'protocol.version=0', 'clone', '-q', remote, target]);
  assert.equal(await gitOk(['rev-parse', 'origin/main'], target), mainAtStart);
  assert.ok(upstream.seen.slice(before).every((request) => request.gitProtocol === ''));
});

test('push to the session branch succeeds', { skip: skipAll }, async () => {
  await gitOk(['checkout', '-q', '-b', BRANCH], agentDir);
  const tip = await commit(agentDir, 'work.txt', 'the agent\'s work\n', 'work');
  const result = await git(['push', 'origin', `HEAD:refs/heads/${BRANCH}`], agentDir);
  assert.equal(result.status, 0, result.all);
  assert.equal(await upstreamRef(`refs/heads/${BRANCH}`), tip);
  assert.ok(upstream.seen.every((request) => request.authorization === AUTHORIZATION));
  const last = (await entries(relay)).at(-1);
  assert.equal(last.verdict, 'allow');
  assert.equal(last.status, 200);
  assert.deepEqual(last.commands, [{ old: '0'.repeat(40), new: tip, ref: `refs/heads/${BRANCH}` }]);
});

// Runs a push that must be refused BY THE RELAY: git fails, prints the
// relay's reason, and the upstream never receives the push.
async function refusedPush(args, expected) {
  const pushesBefore = upstream.seen.filter((request) => request.method === 'POST' && request.path.endsWith('/git-receive-pack')).length;
  const refsBefore = await gitOk(['for-each-ref'], bare);
  const result = await git(['push', ...args], agentDir);
  assert.notEqual(result.status, 0, result.all);
  assert.match(result.stderr, expected);
  assert.match(result.stderr, /remote: git relay: push refused/);
  assert.equal(await gitOk(['for-each-ref'], bare), refsBefore, 'no ref changed upstream');
  const pushesAfter = upstream.seen.filter((request) => request.method === 'POST' && request.path.endsWith('/git-receive-pack')).length;
  assert.equal(pushesAfter, pushesBefore, 'the push never reached the upstream');
  assert.equal((await entries(relay)).at(-1).verdict, 'refuse');
  return result;
}

test('push to another branch is refused, with a message git prints', { skip: skipAll }, async () => {
  await refusedPush(['origin', 'HEAD:refs/heads/main'], /! \[remote rejected\] HEAD -> main \(only refs\/heads\/agent\/asb-demo-0a1b2c may be pushed through the git relay\)/);
  await refusedPush(['origin', 'HEAD:refs/heads/agent/other'], /! \[remote rejected\] HEAD -> agent\/other \(only refs\/heads\//);
  assert.equal(await upstreamRef('refs/heads/main'), mainAtStart);
});

test('push of a tag is refused', { skip: skipAll }, async () => {
  await gitOk(['tag', 'v1.0'], agentDir);
  await refusedPush(['origin', 'v1.0'], /! \[remote rejected\] v1\.0 -> v1\.0 \(tags may not be pushed through the git relay\)/);
  await refusedPush(['origin', '--tags'], /tags may not be pushed/);
  assert.equal(await upstreamRef('refs/tags/v1.0'), '');
});

test('deleting the session branch, or any branch, is refused', { skip: skipAll }, async () => {
  await refusedPush(['origin', `:refs/heads/${BRANCH}`], /! \[remote rejected\] agent\/asb-demo-0a1b2c \(deleting a ref is not allowed through the git relay\)/);
  await refusedPush(['origin', '--delete', 'topic/1'], /deleting a ref is not allowed/);
  assert.notEqual(await upstreamRef(`refs/heads/${BRANCH}`), '');
});

test('one bad ref refuses the whole push, the good ref included', { skip: skipAll }, async () => {
  const before = await upstreamRef(`refs/heads/${BRANCH}`);
  await commit(agentDir, 'more.txt', 'more\n', 'more');
  const result = await refusedPush(['origin', `HEAD:refs/heads/${BRANCH}`, 'HEAD:refs/heads/main'], /HEAD -> main \(only refs\/heads\//);
  assert.match(result.stderr, /HEAD -> agent\/asb-demo-0a1b2c \(not pushed: another ref in the same push was refused\)/);
  assert.equal(await upstreamRef(`refs/heads/${BRANCH}`), before);
  // `--all` sends every local branch; with a second local branch that is the
  // session branch plus one the relay does not allow.
  await gitOk(['branch', 'side'], agentDir);
  await refusedPush(['origin', '--all'], /side -> side \(only refs\/heads\//);
  await refusedPush(['origin', '--mirror'], /remote rejected/);
  assert.equal(await upstreamRef(`refs/heads/${BRANCH}`), before);
  assert.equal(await upstreamRef('refs/heads/side'), '');
});

test('push options are refused', { skip: skipAll }, async () => {
  // The session branch has an unpushed commit from the test above, so this
  // push would be allowed were it not for the option.
  await refusedPush(['-o', 'merge_request.create', 'origin', `HEAD:refs/heads/${BRANCH}`], /push options are not allowed through the git relay/);
});

test('a large push (git\'s probe, then a chunked body) goes through', { skip: skipAll }, async () => {
  const blob = Buffer.alloc(3 << 20);
  for (let i = 0; i < blob.length; i += 1) blob[i] = (i * 2654435761) >>> 24;   // does not compress to nothing
  const tip = await commit(agentDir, 'large.bin', blob, 'large');
  const before = upstream.seen.length;
  const result = await git(['-c', 'http.postBuffer=65536', 'push', 'origin', `HEAD:refs/heads/${BRANCH}`], agentDir);
  assert.equal(result.status, 0, result.all);
  assert.equal(await upstreamRef(`refs/heads/${BRANCH}`), tip);
  const posts = upstream.seen.slice(before).filter((request) => request.method === 'POST');
  assert.equal(posts.length, 2, 'the probe and the push');
  assert.equal(posts[1].transferEncoding, 'chunked');
  const lastTwo = (await entries(relay)).slice(-2);
  assert.deepEqual(lastTwo[0].commands, [], 'the probe names no ref');
  assert.equal(lastTwo[0].verdict, 'allow');
  assert.equal(lastTwo[1].commands.length, 1);
});

test('STATED LIMIT: a force push to the session branch is NOT refused by the relay', { skip: skipAll }, async () => {
  // Rewrite the tip and force it. The relay cannot tell this from an
  // ordinary push and forwards it; the upstream, unprotected, accepts it.
  const replaced = await upstreamRef(`refs/heads/${BRANCH}`);
  await gitOk(['commit', '-q', '--amend', '-m', 'rewritten'], agentDir);
  const rewritten = await gitOk(['rev-parse', 'HEAD'], agentDir);
  const forced = await git(['push', '--force', 'origin', `HEAD:refs/heads/${BRANCH}`], agentDir);
  assert.equal(forced.status, 0, forced.all);
  assert.equal(await upstreamRef(`refs/heads/${BRANCH}`), rewritten);
  assert.notEqual(rewritten, replaced);
  assert.equal((await entries(relay)).at(-1).verdict, 'allow');

  // What does stop it: a rule on the git host. Here, git's own setting.
  await gitOk(['config', 'receive.denyNonFastForwards', 'true'], bare);
  await gitOk(['commit', '-q', '--amend', '-m', 'rewritten again'], agentDir);
  const refused = await git(['push', '--force', 'origin', `HEAD:refs/heads/${BRANCH}`], agentDir);
  assert.notEqual(refused.status, 0);
  assert.match(refused.stderr, /non-fast-forward/);
  assert.equal(await upstreamRef(`refs/heads/${BRANCH}`), rewritten);
  assert.equal((await entries(relay)).at(-1).verdict, 'allow', 'forwarded by the relay; refused by the host');
});

test('a token the git host rejects: git gets 403 and a message, not a password prompt; a new token fixes it', { skip: skipAll }, async () => {
  assert.equal(loadToken(relay, JSON.stringify({ token: 'expired_token_0000' })).status, 0);
  const rejected = await git(['ls-remote', remote]);
  assert.notEqual(rejected.status, 0);
  assert.match(rejected.stderr, /403/);
  assert.match(rejected.stderr, /rejected the relay's token/);
  assert.doesNotMatch(rejected.stderr, /Username|Password|could not read/);

  // `username` left out: relay-load fills in x-access-token.
  assert.equal(loadToken(relay, JSON.stringify({ token: TOKEN })).status, 0);
  assert.equal((await git(['ls-remote', remote])).status, 0);
});

test('the log: one JSON line per request, and no credential in it', { skip: skipAll }, async () => {
  const lines = relay.log.trim().split('\n');
  assert.ok(lines.length > 20);
  for (const line of lines.slice(1)) {
    const entry = JSON.parse(line);
    assert.deepEqual(Object.keys(entry), ['time', 'method', 'path', 'commands', 'verdict', 'reason', 'status', 'ms']);
  }
  for (const secret of [...SECRETS, 'expired_token_0000', 'Basic ', 'uthorization']) {
    assert.equal(relay.log.includes(secret), false, secret);
  }
});

// ---------------------------------------------------------------------------
// As in a session: HTTPS upstream, reached through a CONNECT proxy.
// ---------------------------------------------------------------------------

const HOST = 'git.relay-test.example';
let tlsUpstream;
let connects;
let proxyPort;
let certFile;

test('setup: an HTTPS git host behind a CONNECT proxy', { skip: skipTls }, async () => {
  const keyFile = path.join(tmp, 'key.pem');
  certFile = path.join(tmp, 'cert.pem');
  const made = spawnSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', '-keyout', keyFile, '-out', certFile,
    '-subj', `/CN=${HOST}`, '-addext', `subjectAltName=DNS:${HOST}`], { encoding: 'utf8' });
  assert.equal(made.status, 0, made.stderr);
  tlsUpstream = await startMockUpstream({
    root: upstreamRoot,
    authorization: AUTHORIZATION,
    tlsOptions: { key: fs.readFileSync(keyFile), cert: fs.readFileSync(certFile) },
  });
  servers.push(tlsUpstream.server);

  // A stand-in for Squid: allows a tunnel to the one name, refuses the rest,
  // and records what it was asked for.
  connects = [];
  const proxy = http.createServer((request, response) => {
    connects.push(`${request.method} ${request.url}`);
    response.writeHead(403);
    response.end();
  });
  proxy.on('connect', (request, client) => {
    connects.push(`CONNECT ${request.url}`);
    if (request.url !== `${HOST}:443`) {
      client.end('HTTP/1.1 403 Forbidden\r\n\r\n');
      return;
    }
    const onward = net.connect(tlsUpstream.port, '127.0.0.1', () => {
      client.write('HTTP/1.1 200 Connection established\r\n\r\n');
      onward.pipe(client);
      client.pipe(onward);
    });
    onward.on('error', () => client.destroy());
    client.on('error', () => onward.destroy());
  });
  servers.push(proxy);
  proxyPort = await new Promise((resolve) => {
    proxy.listen(0, '127.0.0.1', () => resolve(proxy.address().port));
  });
});

test('through the proxy over TLS: fetch, an allowed push, a refused push', { skip: skipTls }, async () => {
  const secure = await startRelay('tls', {
    RELAY_UPSTREAM: `https://${HOST}/repo.git`,
    HTTPS_PROXY: `http://127.0.0.1:${proxyPort}`,
    NODE_EXTRA_CA_CERTS: certFile,   // node's own switch for trusting the test certificate
  });
  assert.equal(loadToken(secure, JSON.stringify({ token: TOKEN })).status, 0);
  const url = `http://127.0.0.1:${secure.port}/repo.git`;

  const listed = await git(['ls-remote', url]);
  assert.equal(listed.status, 0, listed.all);
  assert.match(listed.stdout, new RegExp(`${mainAtStart}\\s+refs/heads/main`));

  await gitOk(['config', 'receive.denyNonFastForwards', 'false'], bare);
  const tip = await commit(agentDir, 'over-tls.txt', 'tls\n', 'over tls');
  const pushed = await git(['push', '--force', url, `HEAD:refs/heads/${BRANCH}`], agentDir);
  assert.equal(pushed.status, 0, pushed.all);
  assert.equal(await upstreamRef(`refs/heads/${BRANCH}`), tip);

  const refused = await git(['push', url, 'HEAD:refs/heads/main'], agentDir);
  assert.notEqual(refused.status, 0);
  assert.match(refused.stderr, /only refs\/heads\/agent\/asb-demo-0a1b2c may be pushed/);
  assert.equal(await upstreamRef('refs/heads/main'), mainAtStart);

  assert.ok(tlsUpstream.seen.length >= 3);
  assert.ok(tlsUpstream.seen.every((request) => request.authorization === AUTHORIZATION));
  // The only thing the proxy was ever asked for: a tunnel to the one host.
  assert.ok(connects.length >= 3);
  assert.ok(connects.every((line) => line === `CONNECT ${HOST}:443`), connects.join(', '));
  for (const secret of SECRETS) assert.equal(secure.log.includes(secret), false);
});

test('the upstream\'s certificate is checked: an untrusted one gets no token', { skip: skipTls }, async () => {
  const before = tlsUpstream.seen.length;
  const strict = await startRelay('untrusted', {
    RELAY_UPSTREAM: `https://${HOST}/repo.git`,
    HTTPS_PROXY: `http://127.0.0.1:${proxyPort}`,
  });
  assert.equal(loadToken(strict, JSON.stringify({ token: TOKEN })).status, 0);
  const result = await git(['ls-remote', `http://127.0.0.1:${strict.port}/repo.git`]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /502/);
  assert.equal(tlsUpstream.seen.length, before, 'no request, so no token, reached the untrusted host');
  const last = (await entries(strict)).at(-1);
  assert.equal(last.verdict, 'error');
  assert.match(last.reason, /certificate|self.signed/i);
});

test('a host the proxy refuses is reported as such', { skip: skipTls }, async () => {
  const elsewhere = await startRelay('refused', {
    RELAY_UPSTREAM: 'https://not-on-the-list.example/repo.git',
    HTTPS_PROXY: `http://127.0.0.1:${proxyPort}`,
    NODE_EXTRA_CA_CERTS: certFile,
  });
  assert.equal(loadToken(elsewhere, JSON.stringify({ token: TOKEN })).status, 0);
  const result = await git(['ls-remote', `http://127.0.0.1:${elsewhere.port}/repo.git`]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /the egress proxy refused the git host \(HTTP 403\)/);
});
