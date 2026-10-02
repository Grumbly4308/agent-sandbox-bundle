// relay.mjs — the git relay.  [logical B30]
//
// Optional (`./sandbox run --git-relay`), off by default. For workflows where
// the agent has to push by itself. The relay holds ONE narrow git token so
// the agent never does: the agent talks plain HTTP to this process, and this
// process talks HTTPS to exactly one repository, adding the token on the way.
//
// READ THIS FIRST — what the relay does NOT do:
//
//   * What is pushed through the relay does NOT go through `./sandbox export`.
//     No attribution strip, no dependency diff and no secret scan is applied
//     to it. Whatever the agent commits lands on the branch as it is. Review
//     the branch on the git host before you merge it.
//
//   * It cannot refuse a force push. A push names, per ref, the old commit
//     and the new one. Whether the new one continues the old one's history
//     (a fast-forward) or replaces it (a rewrite) can only be told by walking
//     the commits, and the relay passes the pack through without unpacking
//     it. So the agent CAN rewrite the session branch. If that matters,
//     protect the branch on the git host with a "no force push" rule: the
//     host has the commits and can check.
//
//   * It does not limit what is fetched. Anything the token can read in the
//     one repository, the agent can read: every branch, every tag.
//
// What it does do:
//
//   * One upstream. The repository path in the agent's request is ignored;
//     every request goes to RELAY_UPSTREAM. The agent cannot name another
//     repository or another host.
//   * Four routes of git's smart-HTTP protocol and nothing else:
//       GET  .../info/refs?service=git-upload-pack     fetch: list the refs
//       POST .../git-upload-pack                       fetch: get the objects
//       GET  .../info/refs?service=git-receive-pack    push: list the refs
//       POST .../git-receive-pack                      push: FILTERED, below
//     Anything else is answered 404.
//   * The push filter. A push request starts with one line per ref to change
//     ("<old-id> <new-id> <ref-name>"), then the pack (the commits and
//     files). The relay reads those lines, never the pack, and forwards the
//     push only if EVERY line targets exactly refs/heads/<RELAY_BRANCH> and
//     none is a delete. Tags, other branches and deletes are refused, and one
//     bad line refuses the whole push. So are push options (on some hosts
//     they open merge requests or skip CI), signed pushes and pushes from a
//     shallow clone: anything the relay does not understand, it refuses.
//   * The token is never given to the agent and never logged. Whatever
//     credential the agent sends is dropped.
//
// Configuration (environment):
//   RELAY_UPSTREAM            https URL of the one repository
//   RELAY_BRANCH              the one branch the agent may push
//   HTTPS_PROXY               the egress proxy; the relay has no other way out
//   RELAY_UPSTREAM_OVERRIDE   tests only: a plain-http URL used instead of
//                             RELAY_UPSTREAM, reached without the proxy
//   RELAY_LISTEN, RELAY_RUN_DIR   tests only: where to listen (default
//                             0.0.0.0:8081) and where the token file lives
//                             (default /run/relay)
// The token arrives on stdin through `relay-load`, after the container has
// started. Until then every route answers 503.
//
// Node standard library only.

import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import tls from 'node:tls';
import zlib from 'node:zlib';
import { pipeline } from 'node:stream';
import { pathToFileURL } from 'node:url';

// git's own ceiling for one pkt-line, its four length digits included.
const PKT_MAX = 65520;
// The most of a push the relay ever holds in memory: the ref lines. With one
// branch allowed, an honest push has one. The pack is streamed, never held.
const COMMANDS_MAX_BYTES = 131072;
const IN_FLIGHT_MAX = 8;        // requests served at once; the ninth gets 503
const IDLE_MS = 300000;         // a connection silent for five minutes is closed
const CONNECT_MS = 15000;       // how long the proxy and the git host get to answer the connection
const DRAIN_MS = 30000;         // how long a refused push may keep sending before it is cut off

const SERVICES = ['git-upload-pack', 'git-receive-pack'];

// What a git client may ask for on the first ref line of a push. Anything
// else is refused, `push-options` and `push-cert` in particular: this list is
// an allowlist so that a capability invented later is refused until someone
// has read what it does.
const PUSH_CAPABILITIES = ['report-status', 'report-status-v2', 'side-band', 'side-band-64k', 'quiet', 'atomic', 'ofs-delta'];
const PUSH_CAPABILITY_PREFIXES = ['agent=', 'object-format=', 'session-id='];

// The only response headers passed back to the agent. No cookies, no
// authentication challenges, no redirects.
const RESPONSE_HEADERS = ['content-type', 'content-encoding', 'content-length', 'cache-control', 'expires', 'pragma'];

const FLUSH = Buffer.from('0000', 'latin1');
const EMPTY = Buffer.alloc(0);

// ---------------------------------------------------------------------------
// pkt-lines
// ---------------------------------------------------------------------------
// git frames its protocol in "pkt-lines": four hex digits giving the length
// of the line, those four digits included, then the payload. "0000" is a
// flush packet: end of a section.

export function pkt(payload) {
  const body = Buffer.isBuffer(payload) ? payload : Buffer.from(payload, 'latin1');
  return Buffer.concat([Buffer.from((body.length + 4).toString(16).padStart(4, '0'), 'latin1'), body]);
}

// Reads the ref lines at the start of a push body, from chunks as they
// arrive, and stops at the flush packet that ends them. It never looks at
// what follows (the pack): those bytes are handed back in `rest`.
//
// It is stricter than git: lowercase hex lengths only, no special packets,
// nothing oversized. The upstream is sent exactly the bytes read here, so
// whatever the upstream parses, the relay has parsed the same bytes.
export class CommandReader {
  constructor() {
    this.pending = EMPTY;   // bytes received but not yet a whole pkt-line
    this.headParts = [];    // every byte consumed, to forward unchanged
    this.lines = [];        // the payloads, one Buffer per pkt-line
    this.bytes = 0;
    this.done = false;      // the flush packet has been read
    this.error = '';        // why the body is not a well-formed push, if it is not
    this.rest = EMPTY;      // bytes after the flush packet, from the last chunk
  }

  get head() {
    return Buffer.concat(this.headParts);
  }

  // Returns true once there is nothing more to read here: either the flush
  // packet has been seen or the body is malformed.
  push(chunk) {
    if (this.done || this.error) return true;
    this.pending = this.pending.length ? Buffer.concat([this.pending, chunk]) : chunk;
    while (this.pending.length >= 4) {
      const digits = this.pending.toString('latin1', 0, 4);
      if (!/^[0-9a-f]{4}$/.test(digits)) return this.#fail('a pkt-line length is not four lowercase hex digits');
      const length = parseInt(digits, 16);
      if (length === 0) {
        this.headParts.push(this.pending.subarray(0, 4));
        this.rest = this.pending.subarray(4);
        this.pending = EMPTY;
        this.done = true;
        return true;
      }
      if (length < 4) return this.#fail('a special packet where a ref line was expected');
      if (length === 4) return this.#fail('an empty pkt-line');
      if (length > PKT_MAX) return this.#fail('a pkt-line longer than git allows');
      if (this.bytes + length > COMMANDS_MAX_BYTES) return this.#fail('too many ref lines in one push');
      if (this.pending.length < length) break;
      this.headParts.push(this.pending.subarray(0, length));
      this.lines.push(this.pending.subarray(4, length));
      this.bytes += length;
      this.pending = this.pending.subarray(length);
    }
    return false;
  }

  // The body ended. If the flush packet never came, it was cut short.
  end() {
    if (!this.done && !this.error) this.#fail('the push ended before the end of its ref lines');
  }

  #fail(why) {
    this.error = why;
    this.pending = EMPTY;
    return true;
  }
}

// ---------------------------------------------------------------------------
// The push filter  [logical B30]
// ---------------------------------------------------------------------------

const COMMAND = /^([0-9a-f]{40}|[0-9a-f]{64}) ([0-9a-f]{40}|[0-9a-f]{64}) ([^\x00-\x20\x7f]+)$/;

// Decides one push from its ref lines. `lines` are the pkt-line payloads
// before the flush packet; `branch` is RELAY_BRANCH.
//
// Returns { allow, reason, commands, capabilities, reportable }:
//   commands     [{ old, new, ref, reason }]; reason is '' for a line that
//                would have been fine by itself
//   reportable   every line was a ref line, so a refusal can be reported to
//                the client ref by ref
//
// Lines are compared as bytes (held as latin1 strings, one character per
// byte), and a ref name must equal refs/heads/<branch> exactly: no prefix
// match, no trailing byte.
export function judgePush(lines, branch) {
  const allowedRef = Buffer.from(`refs/heads/${branch}`, 'utf8').toString('latin1');
  const result = { allow: false, reason: '', commands: [], capabilities: [], reportable: false };
  let general = '';

  for (let i = 0; i < lines.length; i += 1) {
    // git drops one trailing newline from each line; so do we, and only one.
    let text = lines[i].toString('latin1');
    if (text.endsWith('\n')) text = text.slice(0, -1);

    // The first line carries the capabilities after a NUL byte. git would
    // read capabilities after a NUL on ANY line, so a NUL on a later line is
    // refused: it could switch something on behind the filter's back.
    const nul = text.indexOf('\0');
    if (nul !== -1) {
      if (i !== 0) {
        result.reason = 'capabilities on a line other than the first';
        return result;
      }
      result.capabilities = text.slice(nul + 1).split(' ').filter((word) => word !== '');
      text = text.slice(0, nul);
    }

    const match = COMMAND.exec(text);
    if (!match || match[1].length !== match[2].length) {
      if (text.startsWith('shallow ')) result.reason = 'pushes from a shallow clone are not supported';
      else if (text.startsWith('push-cert')) result.reason = 'signed pushes are not supported';
      else result.reason = 'a line that is not a ref update';
      return result;
    }

    const command = { old: match[1], new: match[2], ref: match[3], reason: '' };
    if (/^0+$/.test(command.new)) command.reason = 'deleting a ref is not allowed through the git relay';
    else if (command.ref.startsWith('refs/tags/')) command.reason = 'tags may not be pushed through the git relay';
    else if (command.ref !== allowedRef) command.reason = `only refs/heads/${branch} may be pushed through the git relay`;
    result.commands.push(command);
  }
  result.reportable = true;

  for (const capability of result.capabilities) {
    if (PUSH_CAPABILITIES.includes(capability)) continue;
    if (PUSH_CAPABILITY_PREFIXES.some((prefix) => capability.startsWith(prefix))) continue;
    general = capability === 'push-options'
      ? 'push options are not allowed through the git relay'
      : 'the push asks for a capability the git relay does not allow';
    break;
  }

  const refused = result.commands.filter((command) => command.reason !== '');
  if (general === '' && refused.length === 0) {
    // Also true for a push with no ref lines at all: git sends one, a lone
    // flush packet, to test the connection before a large push. It changes
    // nothing upstream.
    result.allow = true;
    return result;
  }
  // One refusal refuses the whole push, so every ref gets a reason.
  for (const command of result.commands) {
    if (command.reason === '') command.reason = general || 'not pushed: another ref in the same push was refused';
  }
  result.reason = general || refused[0].reason;
  return result;
}

// The body of a refusal that git understands, so `git push` prints
//   ! [remote rejected] main -> main (only refs/heads/... may be pushed ...)
// instead of a bare HTTP error. It is the "report-status" reply a git server
// gives when a hook declines a push: "unpack ok" means "the transfer was not
// the problem", then one "ng <ref> <why>" per ref. Returns null when the
// client did not ask for a report or the lines could not be read as refs.
export function refusalReport(judged, branch) {
  const asked = judged.capabilities;
  if (!judged.reportable || judged.commands.length === 0) return null;
  if (!asked.includes('report-status') && !asked.includes('report-status-v2')) return null;
  const report = Buffer.concat([
    pkt('unpack ok\n'),
    ...judged.commands.map((command) => pkt(`ng ${command.ref} ${command.reason}\n`)),
    FLUSH,
  ]);
  // With a side band, the reply travels inside numbered channels: 1 carries
  // the report, 2 carries text git prints as "remote: ...".
  let chunk = 0;
  if (asked.includes('side-band-64k')) chunk = 65000;
  else if (asked.includes('side-band')) chunk = 900;
  if (chunk === 0) return report;
  const note = Buffer.from(
    `git relay: push refused. This relay accepts pushes to refs/heads/${branch} only: no other branch, no tag, no delete.\n`,
    'utf8',
  );
  const parts = [pkt(Buffer.concat([Buffer.from([2]), note]))];
  for (let at = 0; at < report.length; at += chunk) {
    parts.push(pkt(Buffer.concat([Buffer.from([1]), report.subarray(at, at + chunk)])));
  }
  parts.push(FLUSH);
  return Buffer.concat(parts);
}

// ---------------------------------------------------------------------------
// Configuration and the token
// ---------------------------------------------------------------------------

// A branch name git itself would accept. The launcher picks it; this only
// stops a mistake from becoming a filter that matches something odd.
function validBranch(name) {
  if (typeof name !== 'string' || name === '' || name.length > 200) return false;
  if (/[\x00-\x20\x7f~^:?*[\\]/.test(name)) return false;
  if (name.includes('..') || name.includes('@{') || name.includes('//')) return false;
  if (name.startsWith('/') || name.startsWith('-') || name.endsWith('/') || name.endsWith('.')) return false;
  return name.split('/').every((part) => !part.startsWith('.') && !part.endsWith('.lock'));
}

export function loadConfig(env) {
  const override = env.RELAY_UPSTREAM_OVERRIDE || '';
  const raw = override || env.RELAY_UPSTREAM || '';
  if (raw === '') throw new Error('RELAY_UPSTREAM is not set: the https URL of the one repository');
  let upstream;
  try {
    upstream = new URL(raw);
  } catch {
    throw new Error('RELAY_UPSTREAM is not a URL');
  }
  if (override) {
    if (upstream.protocol !== 'http:') throw new Error('RELAY_UPSTREAM_OVERRIDE is for tests and must be a plain http URL');
  } else if (upstream.protocol !== 'https:') {
    throw new Error('RELAY_UPSTREAM must be an https URL');
  }
  // A token in the URL would end up in the environment and in `podman
  // inspect`. The token comes through relay-load and nowhere else.
  if (upstream.username !== '' || upstream.password !== '') throw new Error('RELAY_UPSTREAM must not contain a user name or a token');
  if (upstream.search !== '' || upstream.hash !== '') throw new Error('RELAY_UPSTREAM must not contain a query or a fragment');
  // The egress proxy refuses destinations given as bare addresses, and a
  // certificate is checked against a name.
  if (!override && (net.isIP(upstream.hostname) !== 0 || upstream.hostname.startsWith('['))) {
    throw new Error('RELAY_UPSTREAM must name a host, not an address');
  }

  if (!validBranch(env.RELAY_BRANCH)) throw new Error('RELAY_BRANCH is not set to a valid branch name');

  let proxy = null;
  if (!override) {
    try {
      proxy = new URL(env.HTTPS_PROXY || '');
    } catch {
      throw new Error('HTTPS_PROXY is not set: the relay reaches the git host through the egress proxy only');
    }
    if (proxy.protocol !== 'http:') throw new Error('HTTPS_PROXY must be an http URL');
  }

  const listen = /^(.+):(\d{1,5})$/.exec(env.RELAY_LISTEN || '0.0.0.0:8081');
  if (!listen) throw new Error('RELAY_LISTEN must be host:port');

  return {
    upstream,
    basePath: upstream.pathname.replace(/\/+$/, ''),
    branch: env.RELAY_BRANCH,
    proxy,
    override: override !== '',
    listenHost: listen[1],
    listenPort: Number(listen[2]),
    runDir: env.RELAY_RUN_DIR || '/run/relay',
  };
}

// The Authorization header for the upstream, or null while no token has been
// loaded. Read on every request, so a replacement piped in through relay-load
// is used from the next request on, without a restart.
function readAuthorization(config) {
  try {
    const stored = JSON.parse(fs.readFileSync(path.join(config.runDir, 'credential.json'), 'utf8'));
    if (typeof stored.token !== 'string' || !/^[\x21-\x7e]{1,4096}$/.test(stored.token)) return null;
    if (typeof stored.username !== 'string' || !/^[\x21-\x39\x3b-\x7e]{1,256}$/.test(stored.username)) return null;
    return `Basic ${Buffer.from(`${stored.username}:${stored.token}`, 'latin1').toString('base64')}`;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Talking to the upstream
// ---------------------------------------------------------------------------

// Opens a tunnel through the egress proxy (CONNECT) and starts TLS inside it.
// The proxy looks the name up; this container has no resolver.
function tunnel(config) {
  const host = config.upstream.hostname;
  const port = Number(config.upstream.port || 443);
  return new Promise((resolve, reject) => {
    const connect = http.request({
      host: config.proxy.hostname,
      port: Number(config.proxy.port || 80),
      method: 'CONNECT',
      path: `${host}:${port}`,
      headers: { Host: `${host}:${port}` },
      agent: false,
      timeout: CONNECT_MS,
    });
    connect.once('timeout', () => connect.destroy(new Error('the egress proxy did not answer in time')));
    connect.once('error', reject);
    connect.once('connect', (response, socket) => {
      if (response.statusCode !== 200) {
        socket.destroy();
        reject(new Error(`the egress proxy refused the git host (HTTP ${response.statusCode})`));
        return;
      }
      // The certificate is checked against the host name, with Node's own
      // list of authorities. There is no option here to switch that off.
      const secure = tls.connect({ socket, servername: host, ALPNProtocols: ['http/1.1'] });
      secure.setTimeout(CONNECT_MS, () => secure.destroy(new Error('the git host did not complete TLS in time')));
      secure.once('error', reject);
      secure.once('secureConnect', () => {
        secure.setTimeout(0);
        resolve(secure);
      });
    });
    connect.end();
  });
}

// One upstream request on its own connection. The path is built here from
// RELAY_UPSTREAM and one of four fixed suffixes; nothing from the agent's
// request line reaches it.
async function openUpstream(config, method, suffix, headers) {
  const options = {
    method,
    path: `${config.basePath}${suffix}`,
    headers: { Host: config.upstream.host, ...headers },
    timeout: IDLE_MS,
  };
  if (config.override) {
    return http.request({ ...options, host: config.upstream.hostname, port: Number(config.upstream.port || 80), agent: false });
  }
  const secure = await tunnel(config);
  return http.request({ ...options, createConnection: () => secure });
}

// The request headers sent upstream, built from scratch. Of the agent's own
// headers only harmless, checked ones are copied; its Authorization, cookies
// and anything else are dropped.
function upstreamHeaders(request, authorization, service, kind) {
  const headers = {
    Authorization: authorization,
    Accept: kind === 'advertisement' ? `application/x-${service}-advertisement` : `application/x-${service}-result`,
    'User-Agent': 'git/agent-sandbox-relay',
  };
  const agent = request.headers['user-agent'];
  if (typeof agent === 'string' && /^git\/[\x20-\x7e]{1,100}$/.test(agent)) headers['User-Agent'] = agent;
  const encodings = request.headers['accept-encoding'];
  if (typeof encodings === 'string' && /^[A-Za-z0-9 ,;=.*-]{1,100}$/.test(encodings)) headers['Accept-Encoding'] = encodings;
  // Protocol version 2 is asked for with this header. It is passed through
  // for fetch only: a push is always sent upstream without it, so the push
  // body is in the one format the filter reads.
  const protocol = request.headers['git-protocol'];
  if (service === 'git-upload-pack' && typeof protocol === 'string' && /^[\x21-\x7e]{1,256}$/.test(protocol)) {
    headers['Git-Protocol'] = protocol;
  }
  if (kind === 'request') headers['Content-Type'] = `application/x-${service}-request`;
  return headers;
}

function sendText(response, status, message) {
  response.writeHead(status, { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store', Connection: 'close' });
  response.end(`git relay: ${message}\n`);
}

// Streams the upstream's answer back to the agent.
function relayResponse(upstreamResponse, response, entry) {
  return new Promise((resolve, reject) => {
    const status = upstreamResponse.statusCode;
    if (status === 401 || status === 407) {
      // Passed on as 401, git would ask the agent for a user name and a
      // password. There is nothing the agent can or should supply.
      upstreamResponse.resume();
      entry.reason = 'the git host rejected the token';
      sendText(response, 403, 'the git host rejected the relay\'s token. This is for the operator to fix (the token\'s scope or expiry); retrying will not help.');
      resolve();
      return;
    }
    if (status >= 300 && status < 400) {
      // Following a redirect would send the token to a URL nobody configured.
      upstreamResponse.resume();
      entry.reason = 'the git host answered with a redirect';
      sendText(response, 502, 'the git host answered with a redirect. RELAY_UPSTREAM must be the repository\'s final URL.');
      resolve();
      return;
    }
    const headers = {};
    for (const name of RESPONSE_HEADERS) {
      if (upstreamResponse.headers[name] !== undefined) headers[name] = upstreamResponse.headers[name];
    }
    response.writeHead(status, headers);
    pipeline(upstreamResponse, response, (error) => (error ? reject(error) : resolve()));
  });
}

// Sends one request upstream and streams the answer back. `body` is a stream
// or null; `head` holds bytes already read from it, sent first.
function exchange(upstreamRequest, head, body, response, entry) {
  return new Promise((resolve, reject) => {
    let answered = false;
    upstreamRequest.once('response', (upstreamResponse) => {
      answered = true;
      relayResponse(upstreamResponse, response, entry).then(resolve, reject);
    });
    upstreamRequest.once('timeout', () => upstreamRequest.destroy(new Error('the git host did not answer in time')));
    // After the upstream has answered, an error on the sending side (it
    // stopped reading the pack because it had already said no) is not news.
    upstreamRequest.on('error', (error) => {
      if (!answered) reject(error);
    });
    response.once('close', () => upstreamRequest.destroy());
    if (body === null) {
      upstreamRequest.end();
      return;
    }
    for (const part of head) {
      if (part.length > 0) upstreamRequest.write(part);
    }
    pipeline(body, upstreamRequest, (error) => {
      if (error && !answered) reject(error);
    });
  });
}

// ---------------------------------------------------------------------------
// The four routes
// ---------------------------------------------------------------------------

function bodyLength(request) {
  const length = request.headers['content-length'];
  return typeof length === 'string' && /^\d{1,15}$/.test(length) ? length : '';
}

// GET info/refs: the list of refs, for a fetch or before a push.
async function advertise(config, authorization, service, request, response, entry) {
  entry.verdict = 'allow';
  const headers = upstreamHeaders(request, authorization, service, 'advertisement');
  const upstreamRequest = await openUpstream(config, 'GET', `/info/refs?service=${service}`, headers);
  await exchange(upstreamRequest, [], null, response, entry);
}

// POST git-upload-pack: a fetch. Forwarded as it is; nothing in it can change
// the repository.
async function fetchObjects(config, authorization, request, response, entry) {
  const headers = upstreamHeaders(request, authorization, 'git-upload-pack', 'request');
  const encoding = request.headers['content-encoding'];
  if (encoding !== undefined && encoding !== 'gzip') {
    entry.verdict = 'refuse';
    entry.reason = 'a request encoding other than gzip';
    sendText(response, 415, 'only gzip request bodies are supported.');
    return;
  }
  if (encoding === 'gzip') headers['Content-Encoding'] = 'gzip';
  const length = bodyLength(request);
  if (length !== '') headers['Content-Length'] = length;
  else headers['Transfer-Encoding'] = 'chunked';
  entry.verdict = 'allow';
  const upstreamRequest = await openUpstream(config, 'POST', '/git-upload-pack', headers);
  await exchange(upstreamRequest, [], request, response, entry);
}

// Reads from `body` until the ref lines are complete, then pauses it, leaving
// the pack unread.
function readCommands(body) {
  return new Promise((resolve) => {
    const reader = new CommandReader();
    const finish = () => {
      body.pause();
      body.off('data', onData);
      body.off('end', onEnd);
      body.off('error', onError);
      resolve(reader);
    };
    const onData = (chunk) => {
      if (reader.push(chunk)) finish();
    };
    const onEnd = () => {
      reader.end();
      finish();
    };
    const onError = () => {
      reader.error = 'the push body could not be read (cut off, or not valid gzip)';
      finish();
    };
    body.on('data', onData);
    body.on('end', onEnd);
    body.on('error', onError);
  });
}

// Reads and throws away the rest of a refused push, so the client has
// finished sending by the time the refusal is written and gets to read it.
// Nothing is kept, and it gives up after DRAIN_MS.
function drain(request, body) {
  return new Promise((resolve) => {
    if (body !== request) {
      request.unpipe(body);
      body.destroy();
    }
    if (request.readableEnded || request.destroyed) {
      resolve();
      return;
    }
    const timer = setTimeout(resolve, DRAIN_MS);
    const done = () => {
      clearTimeout(timer);
      resolve();
    };
    request.once('end', done);
    request.once('close', done);
    request.resume();
  });
}

// What goes into the log for a push: the ref lines, cut to a fixed size.
function loggedCommands(commands) {
  return commands.slice(0, 20).map((command) => ({
    old: command.old,
    new: command.new,
    ref: Buffer.from(command.ref, 'latin1').toString('utf8').slice(0, 200),
  }));
}

// POST git-receive-pack: a push. The filter.  [logical B30]
async function push(config, authorization, request, response, entry) {
  const encoding = request.headers['content-encoding'];
  if (encoding !== undefined && encoding !== 'gzip') {
    entry.verdict = 'refuse';
    entry.reason = 'a request encoding other than gzip';
    sendText(response, 415, 'only gzip request bodies are supported.');
    return;
  }
  // A gzip body is unpacked here and sent upstream unpacked, so the upstream
  // reads exactly the bytes the filter read, not its own reading of the
  // compressed ones.
  const body = encoding === 'gzip' ? request.pipe(zlib.createGunzip()) : request;
  if (body !== request) {
    body.on('error', () => {});
    request.once('error', (error) => body.destroy(error));
  }

  const reader = await readCommands(body);
  if (reader.error !== '') {
    entry.verdict = 'refuse';
    entry.reason = reader.error;
    await drain(request, body);
    sendText(response, 400, `push refused: ${reader.error}.`);
    return;
  }

  const judged = judgePush(reader.lines, config.branch);
  entry.commands = loggedCommands(judged.commands);
  if (!judged.allow) {
    entry.verdict = 'refuse';
    entry.reason = judged.reason;
    await drain(request, body);
    const report = refusalReport(judged, config.branch);
    if (report === null) {
      sendText(response, 403, `push refused: ${judged.reason}.`);
      return;
    }
    response.writeHead(200, {
      'Content-Type': 'application/x-git-receive-pack-result',
      'Cache-Control': 'no-cache',
      Connection: 'close',
    });
    response.end(report);
    return;
  }

  entry.verdict = 'allow';
  const headers = upstreamHeaders(request, authorization, 'git-receive-pack', 'request');
  const length = bodyLength(request);
  if (encoding === undefined && length !== '') headers['Content-Length'] = length;
  else headers['Transfer-Encoding'] = 'chunked';
  const upstreamRequest = await openUpstream(config, 'POST', '/git-receive-pack', headers);
  await exchange(upstreamRequest, [reader.head, reader.rest], body, response, entry);
}

async function route(config, request, response, entry) {
  let url;
  try {
    url = new URL(request.url, 'http://relay.invalid');
  } catch {
    url = null;
  }
  // Only the end of the path counts: whatever repository the agent names,
  // the upstream is the configured one.
  let handler = null;
  if (url !== null) {
    const service = url.searchParams.get('service');
    if (request.method === 'GET' && url.pathname.endsWith('/info/refs') && SERVICES.includes(service)) {
      handler = (authorization) => advertise(config, authorization, service, request, response, entry);
    } else if (request.method === 'POST' && url.pathname.endsWith('/git-upload-pack')) {
      handler = (authorization) => fetchObjects(config, authorization, request, response, entry);
    } else if (request.method === 'POST' && url.pathname.endsWith('/git-receive-pack')) {
      handler = (authorization) => push(config, authorization, request, response, entry);
    }
  }
  if (handler === null) {
    entry.verdict = 'not-found';
    sendText(response, 404, 'not found. This relay serves git fetch and push for one repository and nothing else.');
    return;
  }
  const authorization = readAuthorization(config);
  if (authorization === null) {
    entry.verdict = 'not-ready';
    sendText(response, 503, 'no token has been loaded yet.');
    return;
  }
  await handler(authorization);
}

// One JSON line per request on stdout, where Podman collects it [logical
// B28]. No header is ever logged, so no credential is: not the relay's, not
// one the agent may have sent.
function logLine(entry) {
  process.stdout.write(`${JSON.stringify(entry)}\n`);
}

export function createRelay(config, log = logLine) {
  let inFlight = 0;
  const server = http.createServer({ requestTimeout: 0, headersTimeout: CONNECT_MS, maxHeaderSize: 16384 }, (request, response) => {
    const started = Date.now();
    const entry = {
      time: new Date(started).toISOString(),
      method: String(request.method).slice(0, 16),
      path: String(request.url).slice(0, 200),
      commands: [],
      verdict: '',
      reason: '',
      status: 0,
      ms: 0,
    };
    inFlight += 1;
    response.once('close', () => {
      inFlight -= 1;
      entry.status = response.headersSent ? response.statusCode : 0;
      entry.ms = Date.now() - started;
      entry.reason = entry.reason.slice(0, 200);
      log(entry);
    });
    request.on('error', () => {});
    if (inFlight > IN_FLIGHT_MAX) {
      entry.verdict = 'busy';
      sendText(response, 503, 'too many requests at once; try again.');
      return;
    }
    route(config, request, response, entry).catch((error) => {
      entry.verdict = 'error';
      entry.reason = String(error && error.message);
      if (response.headersSent) response.destroy();
      else sendText(response, 502, `could not reach the git host: ${entry.reason}.`);
    });
  });
  // requestTimeout is off above because a large push may take longer than
  // any fixed total; a connection that goes silent is still closed.
  server.setTimeout(IDLE_MS);
  return server;
}

function main() {
  let config;
  try {
    config = loadConfig(process.env);
  } catch (error) {
    process.stderr.write(`gitrelay: ${error.message}\n`);
    process.exit(1);
  }
  const server = createRelay(config);
  // Podman stops a container with SIGTERM; as the first process, node would
  // otherwise ignore it and be killed five seconds later.
  process.on('SIGTERM', () => process.exit(0));
  process.on('SIGINT', () => process.exit(0));
  server.listen(config.listenPort, config.listenHost, () => {
    logLine({
      time: new Date().toISOString(),
      event: 'listening',
      port: server.address().port,
      upstream: `${config.upstream.origin}${config.basePath}`,
      branch: config.branch,
      test_override: config.override,
    });
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(fs.realpathSync(process.argv[1])).href) {
  main();
}
