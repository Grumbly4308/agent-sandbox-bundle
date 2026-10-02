#!/usr/bin/env node
// sidecar.mjs — the credential sidecar.
//
// What this is
//   A small web server that sits between the agent and the model vendor. The
//   agent's CLI is told that this server IS the vendor's API and is given a
//   dummy token. For each request this server checks that it is one the CLI
//   needs, throws the dummy away, puts the real token in, and sends the
//   request to the one vendor host named in the agent's sidecar.json. The
//   real token is never in the agent's container, so the agent cannot steal
//   it (closes reference finding H1: the whole-account login used to be
//   mounted into the agent on every run).
//
// The barriers it implements (register in docs/00-threat-model.md)
//   [logical B22] swap the dummy credential for the real one; one upstream.
//   [logical B23] forward only the listed routes; refuse request features
//                 that make the vendor's servers contact other hosts.
//   [logical B24] count model requests against a budget; cap body size and
//                 the number of requests in flight.
//   [logical B25] log every request, and every web search query it can see.
//   [logical B21] is the proxy's (the vendor's hosts are allowed from this
//                 container's address only); this file's part is to reach the
//                 vendor only through that proxy.
//
// Environment (set by ./sandbox through topology.sh)
//   SANDBOX_AGENT    which agents/<name>/sidecar.json to serve
//   SANDBOX_AUTH     oauth | apikey: which block of that file to use
//   SANDBOX_BUDGET   how many model requests this run may make
//   HTTPS_PROXY      http://<proxy address>:3128, the only way out
// Environment that only the tests set (tests/sidecar/run.sh)
//   SANDBOX_UPSTREAM_OVERRIDE  http://127.0.0.1:<port>: talk plain HTTP to a
//                              mock instead of the vendor. Loopback only.
//   SANDBOX_SIDECAR_LISTEN     address:port to listen on (default 0.0.0.0:8080)
//   SANDBOX_SIDECAR_STATE_DIR  where the credential is kept (default /run/sidecar)
//   SANDBOX_AGENTS_DIR         where the sidecar.json files are
//                              (default /usr/share/sandbox/agents)
//
// ---------------------------------------------------------------------------
// The sidecar.json schema (JSON has no comments, so it is documented here)
// ---------------------------------------------------------------------------
// {
//   "schema": 1,
//   "modes": {                        one block per credential mode the agent
//     "oauth": {                      supports. A mode that is not listed is
//                                     refused at start (OpenCode has no oauth).
//       "upstream": "https://api.anthropic.com",
//                                     the ONLY host requests are sent to.
//                                     https, port 443, a name, no path.
//       "strip": ["authorization", "x-api-key", "cookie"],
//                                     request headers thrown away: whatever
//                                     the agent sent as a credential.
//       "inject": { "authorization": "Bearer {token}" },
//                                     headers added. {token} and {account_id}
//                                     come from the loaded credential. An
//                                     injected name is also stripped first.
//       "routes": [
//         { "method": "POST", "path": "/v1/messages",
//           "body": "anthropic-messages", "model": true }
//       ]                             everything else is 404. "path" is
//                                     matched exactly (the query string is
//                                     passed on but not matched). "body"
//                                     names a rule set below: the request
//                                     body is then read, checked and logged.
//                                     Without "body" no request body is
//                                     forwarded. "model": true counts the
//                                     request against the budget and needs
//                                     "body".
//     }
//   },
//   "bodies": {
//     "anthropic-messages": {
//       "dialect": "anthropic-messages",
//                                     which vendor format the body is in:
//                                     anthropic-messages | openai-responses |
//                                     openai-chat. Decides where the code
//                                     looks for tools, remote content and web
//                                     search queries (see DIALECTS below).
//       "deny_keys": ["mcp_servers"], top-level keys that are refused
//       "tools_untyped": true,        may an entry of "tools" have no "type"?
//       "tools_allow": ["custom", "bash_*"],
//                                     tool types let through. A trailing *
//                                     matches any ending.
//       "tools_deny": ["web_fetch*"], tool types known to make the vendor
//                                     contact other hosts. Listed only to
//                                     give a clearer refusal: a type on
//                                     NEITHER list is refused too, and logged
//                                     with its name so you can see what to
//                                     add to tools_allow.
//       "web_search": ["web_search_*"]
//                                     which allowed types are the vendor's
//                                     web search (for the log)
//     }
//   }
// }
// A new agent that speaks one of the three dialects needs a sidecar.json and
// no change here. Unknown keys anywhere in the file are refused at start, so
// a typing mistake cannot silently switch a check off.
// ---------------------------------------------------------------------------

import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import tls from 'node:tls';
import { pipeline } from 'node:stream';

// ---------------------------------------------------------------------------
// Fixed limits. None of these is an option.
// ---------------------------------------------------------------------------
const BODY_MAX = 32 * 1024 * 1024;       // [logical B24] largest request body accepted
const HELD_MAX = 64 * 1024 * 1024;       // [logical B24] request bodies held in memory at once, all requests together (the container has 256 MB)
const MAX_IN_FLIGHT = 8;                 // [logical B24] requests being served at once
const MAX_CONNECTIONS = 64;              // open client connections; the CLIs use a handful
const TUNNEL_TIMEOUT_MS = 30_000;        // proxy CONNECT plus TLS handshake
const UPSTREAM_IDLE_MS = 10 * 60_000;    // silence from the vendor before giving up (the vendors' own client timeout)
const SHUTDOWN_GRACE_MS = 3_000;         // on SIGTERM; Podman kills after 5 s
const SCAN_LINE_MAX = 1024 * 1024;       // longest reply line examined for a web search query
const SCAN_JSON_MAX = 4 * 1024 * 1024;   // largest non-streamed reply examined for one
const CAPPED_LINES_PER_MINUTE = 60;      // [logical B25] log lines per minute for requests the budget does not bound
const LOG_LINE_MAX = 16 * 1024;          // [logical B25] longest log line
const LOG_LIST_MAX = 64;                 // tool names and types logged per request
const LOG_SEARCH_MAX = 10;               // web searches logged per request

// What a stored credential may look like. The character set is the one
// allowed for a bearer token (RFC 6750); it has no quote, backslash, space
// or line break, so a token can neither break a header nor hide in a log
// line under a different spelling. sidecar-load applies the same rule.
const TOKEN_RE = /^[A-Za-z0-9._~+/=-]{8,16384}$/;
const ACCOUNT_RE = /^[A-Za-z0-9._:-]{1,128}$/;

// Headers that describe one connection, not the request, and so are never
// copied from one side to the other. host and content-length are set afresh.
const HOP_BY_HOP = new Set([
  'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
  'proxy-connection', 'te', 'trailer', 'transfer-encoding', 'upgrade',
  'host', 'content-length', 'expect',
]);
// Dropped from replies as well: the agent's cookies are stripped on the way
// in, so handing it the vendor's cookies would serve no purpose.
const REPLY_DROP = new Set([...HOP_BY_HOP, 'set-cookie']);

// ---------------------------------------------------------------------------
// Logging  [logical B25]
// One JSON object per line on stdout; Podman collects it (B28). Every string
// is cut to a fixed length before it gets here, JSON.stringify escapes
// control characters, and what is left outside printable ASCII is escaped
// too, so nothing the agent sends can draw on the operator's terminal or
// forge a second line. No header value is ever logged.
// ---------------------------------------------------------------------------
const seenTokens = [];   // every token loaded this run, for the last-resort scrub below

const clip = (value, max) => {
  const text = String(value);
  return text.length > max ? `${text.slice(0, max)}...` : text;
};

function log(fields) {
  const t = new Date().toISOString();
  let line = JSON.stringify({ t, ...fields });
  if (line.length > LOG_LINE_MAX) {
    line = JSON.stringify({ t, event: fields.event, status: fields.status, note: 'log line over the size limit; other fields dropped' });
  }
  line = line.replace(/[\u007f-\uffff]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, '0')}`);
  // No code path puts the token in a log line. This is a second line of
  // defence in case a library error message ever quotes a header.
  for (const token of seenTokens) line = line.split(token).join('[credential]');
  process.stdout.write(`${line}\n`);
}

function die(message) {
  log({ event: 'fatal', message: clip(message, 500) });
  process.stderr.write(`sidecar: ${message}\n`);
  process.exit(1);
}

// Model requests that were forwarded are bounded by the budget, so their log
// lines are too. Everything else (refusals, routes that do not count) could
// be repeated without end to push real entries out of the log, so those
// lines share a per-minute allowance. What is left out is counted, and the
// count is logged.
const capped = { windowStart: Date.now(), written: 0, suppressed: 0 };

function flushSuppressed() {
  if (capped.suppressed > 0) {
    log({ event: 'suppressed', count: capped.suppressed, note: 'request lines left out by the per-minute cap' });
  }
  capped.windowStart = Date.now();
  capped.written = 0;
  capped.suppressed = 0;
}

function logCapped(fields) {
  if (Date.now() - capped.windowStart >= 60_000) flushSuppressed();
  if (capped.written < CAPPED_LINES_PER_MINUTE) {
    capped.written += 1;
    log(fields);
  } else {
    capped.suppressed += 1;
  }
}

// ---------------------------------------------------------------------------
// Start-up: read the environment and this agent's sidecar.json. Anything
// wrong stops the process with a message; nothing is guessed.
// ---------------------------------------------------------------------------
const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const isStringList = (v) => Array.isArray(v) && v.every((s) => typeof s === 'string' && s.length > 0);
const onlyKeys = (obj, allowed) => Object.keys(obj).filter((k) => !allowed.includes(k));

const AGENT = process.env.SANDBOX_AGENT ?? '';
const AUTH = process.env.SANDBOX_AUTH ?? '';
const STATE_DIR = process.env.SANDBOX_SIDECAR_STATE_DIR || '/run/sidecar';
const AGENTS_DIR = process.env.SANDBOX_AGENTS_DIR || '/usr/share/sandbox/agents';
const CRED_DIR = path.join(STATE_DIR, 'cred');
const CRED_FILE = path.join(CRED_DIR, 'credential.json');

function readRouting() {
  if (!/^[a-z0-9][a-z0-9_-]{0,31}$/.test(AGENT)) die('SANDBOX_AGENT must be the name of an agent plug-in');
  if (AUTH !== 'oauth' && AUTH !== 'apikey') die('SANDBOX_AUTH must be oauth or apikey');
  const file = path.join(AGENTS_DIR, AGENT, 'sidecar.json');
  const bad = (why) => die(`${file}: ${why}`);
  let doc;
  try {
    doc = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    bad(`cannot be read: ${err.message}`);
  }
  if (!isObject(doc) || doc.schema !== 1) bad('"schema" must be 1');
  if (onlyKeys(doc, ['schema', 'modes', 'bodies']).length) bad(`unknown key ${onlyKeys(doc, ['schema', 'modes', 'bodies'])[0]}`);
  if (!isObject(doc.modes)) bad('"modes" must be an object');
  const bodies = doc.bodies ?? {};
  if (!isObject(bodies)) bad('"bodies" must be an object');

  // A credential mode the agent's plug-in does not list is refused here.
  // This is how "OpenCode has no subscription login" is enforced: its file
  // has no "oauth" block.
  if (!Object.hasOwn(doc.modes, AUTH)) {
    die(`agent "${AGENT}" has no "${AUTH}" credential mode (${file} lists: ${Object.keys(doc.modes).join(', ')}); refusing to start`);
  }
  const mode = doc.modes[AUTH];
  if (!isObject(mode)) bad(`modes.${AUTH} must be an object`);
  const modeKeys = ['upstream', 'strip', 'inject', 'routes'];
  if (onlyKeys(mode, modeKeys).length) bad(`modes.${AUTH}: unknown key ${onlyKeys(mode, modeKeys)[0]}`);

  // [logical B22] Exactly one upstream, fixed here at start. It is never
  // taken from a request.
  let upstream;
  try {
    upstream = new URL(mode.upstream);
  } catch {
    bad(`modes.${AUTH}.upstream is not a URL`);
  }
  if (upstream.protocol !== 'https:' || upstream.port !== '' || upstream.pathname !== '/' || upstream.search || upstream.hash
      || upstream.username || upstream.password || !/^(?=.*[a-z])[a-z0-9.-]+$/.test(upstream.hostname)) {
    bad(`modes.${AUTH}.upstream must be https://<host name> and nothing more`);
  }

  const headerName = /^[a-z0-9-]+$/;
  if (!isStringList(mode.strip) || !mode.strip.every((h) => headerName.test(h))) bad(`modes.${AUTH}.strip must be a list of lower-case header names`);
  if (!isObject(mode.inject) || Object.keys(mode.inject).length === 0) bad(`modes.${AUTH}.inject must name at least one header`);
  for (const [name, template] of Object.entries(mode.inject)) {
    if (!headerName.test(name) || typeof template !== 'string'
        || !/^[A-Za-z0-9 ._-]*\{(token|account_id)\}$/.test(template)) {
      bad(`modes.${AUTH}.inject.${name} must be optional plain text followed by {token} or {account_id}`);
    }
  }

  const rules = new Map();
  const ruleKeys = ['dialect', 'deny_keys', 'tools_untyped', 'tools_allow', 'tools_deny', 'web_search'];
  const isPatternList = (v) => isStringList(v) && v.every((p) => !p.slice(0, -1).includes('*'));
  for (const [name, rule] of Object.entries(bodies)) {
    if (!isObject(rule)) bad(`bodies.${name} must be an object`);
    if (onlyKeys(rule, ruleKeys).length) bad(`bodies.${name}: unknown key ${onlyKeys(rule, ruleKeys)[0]}`);
    if (!Object.hasOwn(DIALECTS, rule.dialect)) bad(`bodies.${name}.dialect must be one of ${Object.keys(DIALECTS).join(', ')}`);
    if (!isStringList(rule.deny_keys)) bad(`bodies.${name}.deny_keys must be a list of strings`);
    if (typeof rule.tools_untyped !== 'boolean') bad(`bodies.${name}.tools_untyped must be true or false`);
    for (const key of ['tools_allow', 'tools_deny', 'web_search']) {
      if (!isPatternList(rule[key])) bad(`bodies.${name}.${key} must be a list of tool types (a * only at the end)`);
    }
    rules.set(name, { name, ...rule });
  }

  const routes = new Map();
  const routeKeys = ['method', 'path', 'body', 'model'];
  if (!Array.isArray(mode.routes) || mode.routes.length === 0) bad(`modes.${AUTH}.routes must list at least one route`);
  for (const route of mode.routes) {
    if (!isObject(route)) bad('a route must be an object');
    if (onlyKeys(route, routeKeys).length) bad(`route ${route.path}: unknown key ${onlyKeys(route, routeKeys)[0]}`);
    if (route.method !== 'GET' && route.method !== 'POST') bad(`route ${route.path}: method must be GET or POST`);
    if (typeof route.path !== 'string' || !/^\/[A-Za-z0-9._~/-]*$/.test(route.path)) bad('a route path must start with / and hold only plain path characters');
    if (route.body !== undefined && !rules.has(route.body)) bad(`route ${route.path}: no rule set "${route.body}" under "bodies"`);
    if (route.model !== undefined && typeof route.model !== 'boolean') bad(`route ${route.path}: "model" must be true or false`);
    if (route.model && route.body === undefined) bad(`route ${route.path}: a model route needs "body", so that it is checked`);
    routes.set(`${route.method} ${route.path}`, { rules: route.body ? rules.get(route.body) : null, model: route.model === true });
  }

  return {
    file,
    host: upstream.hostname,
    strip: new Set(mode.strip),
    inject: Object.entries(mode.inject),
    needsAccount: Object.values(mode.inject).some((template) => template.includes('{account_id}')),
    routes,
  };
}

function readBudget() {
  const raw = process.env.SANDBOX_BUDGET ?? '';
  if (!/^[0-9]{1,9}$/.test(raw)) die('SANDBOX_BUDGET must be a whole number of model requests');
  return Number(raw);
}

// Where requests go. In a session: through the Squid proxy, the only
// container with a route out. In tests: plain HTTP to a mock on this
// machine. The override is refused unless it points at loopback, so that
// even set by mistake it could not send the token anywhere.
function readWayOut() {
  const override = process.env.SANDBOX_UPSTREAM_OVERRIDE;
  if (override) {
    let url;
    try { url = new URL(override); } catch { die('SANDBOX_UPSTREAM_OVERRIDE is not a URL'); }
    const host = url.hostname.replace(/^\[|\]$/g, '');
    if (url.protocol !== 'http:' || !url.port || !['127.0.0.1', '::1', 'localhost'].includes(host)) {
      die('SANDBOX_UPSTREAM_OVERRIDE is for tests and must be http://127.0.0.1:<port>');
    }
    return { override: { host, port: Number(url.port) }, proxy: null };
  }
  let url;
  try { url = new URL(process.env.HTTPS_PROXY ?? ''); } catch { die('HTTPS_PROXY must be set to http://<proxy address>:<port>'); }
  if (url.protocol !== 'http:' || !url.port || url.username || url.password) die('HTTPS_PROXY must be http://<proxy address>:<port>');
  return { override: null, proxy: { host: url.hostname.replace(/^\[|\]$/g, ''), port: Number(url.port) } };
}

function readListen() {
  const raw = process.env.SANDBOX_SIDECAR_LISTEN || '0.0.0.0:8080';
  const colon = raw.lastIndexOf(':');
  const port = Number(raw.slice(colon + 1));
  if (colon < 1 || !Number.isInteger(port) || port < 0 || port > 65535) die('SANDBOX_SIDECAR_LISTEN must be <address>:<port>');
  return { host: raw.slice(0, colon), port };
}

// ---------------------------------------------------------------------------
// The credential  [logical B22]
// /run/sidecar is a memory-backed mount in this container only, created by
// Podman with mode 1777 and owned by root. This user makes a private
// directory in it (0700); sidecar-load writes the file (0600) and moves it
// into place in one step, so a reader never sees half a file. The file is
// looked at again on every request, which is how a fresh Codex token piped
// in mid-session takes effect without a restart.
//
// The token is also in this process's memory. Node cannot mark its process
// "not dumpable" (that needs prctl, which the standard library does not
// offer), so two things stand in for it: core dumps are off for the
// container (`--ulimit core=0:0` in topology.sh, physical B11), and no other
// user or process shares this container.
// ---------------------------------------------------------------------------
function ensurePrivateDir(dir) {
  try {
    fs.mkdirSync(dir, { mode: 0o700 });
  } catch (err) {
    if (err.code !== 'EEXIST') die(`cannot create ${dir}: ${err.message}`);
  }
  const st = fs.lstatSync(dir);
  if (!st.isDirectory() || st.uid !== process.getuid() || (st.mode & 0o077) !== 0) {
    die(`${dir} must be a directory owned by this user with mode 0700`);
  }
}

const credential = { stamp: '', value: null, problem: 'no credential has been loaded yet' };

function currentCredential() {
  let st;
  try {
    st = fs.lstatSync(CRED_FILE, { bigint: true });
  } catch {
    if (credential.stamp !== '') log({ event: 'credential', state: 'removed' });
    Object.assign(credential, { stamp: '', value: null, problem: 'no credential has been loaded yet' });
    return null;
  }
  const stamp = `${st.ino}:${st.mtimeNs}:${st.size}`;
  if (stamp === credential.stamp) return credential.value;

  let value = null;
  let problem = '';
  try {
    if (!st.isFile() || Number(st.uid) !== process.getuid() || (Number(st.mode) & 0o077) !== 0) {
      throw new Error('the credential file is not a private file of this user');
    }
    const doc = JSON.parse(fs.readFileSync(CRED_FILE, 'utf8'));
    if (!isObject(doc) || typeof doc.token !== 'string' || !TOKEN_RE.test(doc.token)) throw new Error('the stored credential has no usable token');
    if (doc.account_id !== undefined && (typeof doc.account_id !== 'string' || !ACCOUNT_RE.test(doc.account_id))) throw new Error('the stored account_id is not usable');
    if (routing.needsAccount && doc.account_id === undefined) throw new Error(`this agent needs an account_id with its token and none was loaded`);
    value = { token: doc.token, account_id: doc.account_id };
    if (!seenTokens.includes(doc.token)) seenTokens.push(doc.token);
  } catch (err) {
    problem = err instanceof SyntaxError ? 'the stored credential is not valid JSON' : err.message;
  }
  Object.assign(credential, { stamp, value, problem });
  log(value ? { event: 'credential', state: 'loaded', account_id: value.account_id !== undefined }
            : { event: 'credential', state: 'unusable', reason: clip(problem, 200) });
  return value;
}

// ---------------------------------------------------------------------------
// Body rules  [logical B23]
// A model request is parsed, checked against the agent's rule set, and then
// sent on RE-WRITTEN from the parsed form, never as the bytes that arrived.
// What the vendor reads is therefore exactly what was checked: a body with
// the same key twice, or bytes two parsers read differently, cannot show one
// thing to this check and another to the vendor. For a body written by a
// JavaScript client the re-written form is byte-for-byte the same.
// ---------------------------------------------------------------------------
const matches = (patterns, type) => patterns.some((p) => (p.endsWith('*') ? type.startsWith(p.slice(0, -1)) : type === p));

// Visit every object below `root` without recursion (a hostile body can be
// nested deeper than the call stack). Returns the first non-empty answer.
function findObject(root, test, skipKey) {
  const stack = [root];
  while (stack.length > 0) {
    const value = stack.pop();
    if (value === null || typeof value !== 'object') continue;
    if (Array.isArray(value)) {
      for (const item of value) stack.push(item);
      continue;
    }
    const hit = test(value);
    if (hit) return hit;
    for (const [key, item] of Object.entries(value)) {
      if (!skipKey(value, key)) stack.push(item);
    }
  }
  return null;
}

// Each dialect knows three things about one vendor format:
//   remoteContent(body)        a sentence if the body points the vendor at a
//                              URL to fetch (an image or document "by URL"),
//                              else null. That is a server-side fetch of an
//                              address the agent chose, the same channel as
//                              web_fetch, so it is refused.
//   requestSearches(body, all) web search queries visible in the request
//   replyScanner(note)         looks for web search queries in the reply
const DIALECTS = {
  // Anthropic Messages API: Claude Code, and OpenCode with an Anthropic key.
  'anthropic-messages': {
    remoteContent(body) {
      return findObject(
        [body.messages, body.system],
        (o) => (isObject(o.source) && o.source.type === 'url' ? 'a content block with a "url" source makes the vendor fetch that address' : null),
        // What a tool was called with is data, not an instruction to the vendor.
        (o, key) => key === 'input' && typeof o.type === 'string' && o.type.endsWith('tool_use'),
      );
    },
    // Claude Code's WebSearch is a request of its own whose only tool is the
    // vendor's web search and whose user text is "Perform a web search for
    // the query: <query>". Searches the model ran also come back in later
    // requests as server_tool_use blocks.
    requestSearches(body, onlyWebSearch) {
      const found = [];
      const messages = Array.isArray(body.messages) ? body.messages.filter(isObject) : [];
      if (onlyWebSearch) {
        const last = messages.filter((m) => m.role === 'user').pop();
        const text = typeof last?.content === 'string' ? last.content
          : Array.isArray(last?.content) ? last.content.filter((b) => b?.type === 'text' && typeof b.text === 'string').map((b) => b.text).join(' ')
          : '';
        if (text) found.push({ from: 'request', query: text.replace(/^Perform a web search for the query: /, '') });
      }
      for (const message of messages) {
        if (!Array.isArray(message.content)) continue;
        for (const block of message.content) {
          if (block?.type === 'server_tool_use' && typeof block.input?.query === 'string') {
            found.push({ from: 'request', kind: block.name, query: block.input.query });
          }
        }
      }
      return found;
    },
    // In a streamed reply the query arrives in pieces: a content block of
    // type server_tool_use opens, its input follows as input_json_delta
    // fragments, and the block closes. NOT yet proven against the real API.
    replyScanner(note) {
      const open = new Map();   // block index -> { name, input, json }
      const noteUse = (name, input) => {
        if (typeof input?.query === 'string') note({ from: 'response', kind: name, query: input.query });
      };
      return {
        sse(payload) {
          if (payload.includes('server_tool_use')) {
            const event = JSON.parse(payload);
            const block = event.content_block;
            if (event.type === 'content_block_start' && block?.type === 'server_tool_use') open.set(event.index, { name: block.name, input: block.input, json: '' });
          } else if (open.size > 0 && payload.includes('input_json_delta')) {
            const event = JSON.parse(payload);
            const entry = open.get(event.index);
            if (entry && typeof event.delta?.partial_json === 'string' && entry.json.length < 8192) entry.json += event.delta.partial_json;
          } else if (open.size > 0 && payload.includes('content_block_stop')) {
            const event = JSON.parse(payload);
            const entry = open.get(event.index);
            if (!entry) return;
            open.delete(event.index);
            noteUse(entry.name, entry.json ? JSON.parse(entry.json) : entry.input);
          }
        },
        json(reply) {
          for (const block of Array.isArray(reply.content) ? reply.content : []) {
            if (block?.type === 'server_tool_use') noteUse(block.name, block.input);
          }
        },
      };
    },
  },

  // OpenAI Responses API: Codex (both modes).
  'openai-responses': {
    remoteContent: openaiRemoteContent,
    requestSearches: () => [],
    // UNPROVEN against the real API. The request only switches web search
    // on; the query the model chose comes back in the reply as an output
    // item {type: "web_search_call", action: {type: "search", query}} (or
    // action.type "open_page" with a url). This reads the items as they
    // pass. Until it has been seen working against the vendor, B25 is not
    // claimed for Codex.
    replyScanner(note) {
      const seen = new Set();
      const noteItem = (item) => {
        if (item?.type !== 'web_search_call' || !isObject(item.action)) return;
        const { type, query, queries, url, pattern } = item.action;
        const found = { from: 'response', kind: type };
        if (typeof query === 'string') found.query = query;
        else if (isStringList(queries)) found.query = queries.join(' | ');
        if (typeof url === 'string') found.url = url;
        if (typeof pattern === 'string') found.pattern = pattern;
        const key = typeof item.id === 'string' ? item.id : JSON.stringify(found);
        if (seen.has(key)) return;   // the final event repeats every item
        seen.add(key);
        note(found);
      };
      const noteAll = (reply) => { for (const item of Array.isArray(reply?.output) ? reply.output : []) noteItem(item); };
      return {
        sse(payload) {
          if (!payload.includes('web_search_call')) return;
          const event = JSON.parse(payload);
          if (event.type === 'response.output_item.done') noteItem(event.item);
          else if (event.type === 'response.completed') noteAll(event.response);
        },
        json: noteAll,
      };
    },
  },

  // OpenAI Chat Completions. Its tools are functions the client runs. Web
  // search there is a property of the model chosen (a "-search" model), and
  // the query is never shown to the caller; the model name is in the log.
  'openai-chat': {
    remoteContent: openaiRemoteContent,
    requestSearches: () => [],
    replyScanner: null,
  },
};

// Both OpenAI formats carry images as "image_url" and files as "file_url".
// Inline data (data:...) is content; anything else is an address the vendor
// would fetch. Tool definitions are skipped: a parameter may be named so.
function openaiRemoteContent(body) {
  return findObject(
    body,
    (o) => {
      for (const key of ['image_url', 'file_url']) {
        const value = typeof o[key] === 'string' ? o[key] : isObject(o[key]) && typeof o[key].url === 'string' ? o[key].url : null;
        if (value !== null && !/^data:/i.test(value)) return `"${key}" with a web address makes the vendor fetch that address`;
      }
      return null;
    },
    (o, key) => o === body && key === 'tools',
  );
}

// Check one "tools" list. Returns a refusal or null, and fills `seen` for
// the log. OpenAI "namespace" entries hold a "tools" list of their own.
function checkTools(tools, rules, seen, depth) {
  if (!Array.isArray(tools)) return { reason: 'tools_malformed', message: '"tools" must be a list' };
  if (depth > 4) return { reason: 'tools_malformed', message: '"tools" is nested too deeply' };
  for (const tool of tools) {
    if (!isObject(tool)) return { reason: 'tools_malformed', message: 'every entry of "tools" must be an object' };
    const name = typeof tool.name === 'string' ? tool.name : typeof tool.function?.name === 'string' ? tool.function.name : '';
    let type;
    if (tool.type === undefined) {
      if (!rules.tools_untyped) return { reason: 'tool_type_unknown', message: `a tool entry with no "type" (name "${clip(name, 64)}") is not allowed for this agent` };
      type = 'custom';
    } else if (typeof tool.type !== 'string') {
      return { reason: 'tools_malformed', message: 'a tool "type" must be a string' };
    } else {
      type = tool.type;
      const shown = `tool type "${clip(type, 64)}" (name "${clip(name, 64)}")`;
      if (matches(rules.tools_deny, type)) {
        return { reason: 'tool_type_denied', message: `${shown} runs on the vendor's servers and can contact other hosts; the sandbox refuses it` };
      }
      if (!matches(rules.tools_allow, type)) {
        return { reason: 'tool_type_unknown', message: `${shown} is not on the allow list; if the CLI needs it, add it to tools_allow in ${routing.file}` };
      }
    }
    seen.total += 1;
    if (!matches(rules.web_search, type)) seen.onlyWebSearch = false;
    if (seen.names.length < LOG_LIST_MAX && name) seen.names.push(clip(name, 64));
    if (seen.types.length < LOG_LIST_MAX && !seen.types.includes(type)) seen.types.push(clip(type, 64));
    if (tool.tools !== undefined) {
      const nested = checkTools(tool.tools, rules, seen, depth + 1);
      if (nested) return nested;
    }
  }
  return null;
}

// Returns { refusal } or { summary } for one parsed body.
function inspectBody(body, rules) {
  if (!isObject(body)) return { refusal: { reason: 'body_malformed', message: 'the request body must be a JSON object' } };
  for (const key of rules.deny_keys) {
    if (Object.hasOwn(body, key)) {
      return { refusal: { reason: 'feature_denied', message: `"${key}" makes the vendor's servers contact other hosts for the agent; the sandbox refuses it` } };
    }
  }
  const seen = { names: [], types: [], total: 0, onlyWebSearch: true };
  if (body.tools !== undefined && body.tools !== null) {
    const refusal = checkTools(body.tools, rules, seen, 0);
    if (refusal) return { refusal };
  }
  const dialect = DIALECTS[rules.dialect];
  const remote = dialect.remoteContent(body);
  if (remote) return { refusal: { reason: 'remote_content_denied', message: `${remote}; the sandbox refuses it. Send the content itself instead` } };
  return {
    summary: {
      model: typeof body.model === 'string' ? clip(body.model, 100) : undefined,
      stream: body.stream === true,
      tools: seen.names,
      tool_types: seen.types,
      tools_total: seen.total,
      searches: dialect.requestSearches(body, seen.total > 0 && seen.onlyWebSearch),
    },
  };
}

// ---------------------------------------------------------------------------
// Looking for web search queries in a reply  [logical B25]
// The reply is passed to the agent as it arrives; this only looks at a copy
// of each piece on its way through. It keeps at most one line of a streamed
// reply (or SCAN_JSON_MAX bytes of a non-streamed one) and never delays or
// changes what the agent receives. A mistake in here loses a log field, not
// a reply: every call is wrapped.
// ---------------------------------------------------------------------------
function replyWatcher(rules, contentType, note) {
  const scanner = DIALECTS[rules.dialect].replyScanner?.(note);
  if (!scanner) return null;
  const quietly = (fn) => (...args) => { try { fn(...args); } catch { /* not valid JSON, or a shape we do not know */ } };

  if (String(contentType).toLowerCase().startsWith('text/event-stream')) {
    // Server-sent events: lines of "data: <JSON>". A line can be split
    // anywhere between two pieces, so the unfinished end is kept until its
    // line break arrives. A line longer than SCAN_LINE_MAX is skipped.
    let parts = [];
    let size = 0;
    let skipping = false;
    const onLine = quietly((line) => { if (line.startsWith('data:')) scanner.sse(line.slice(5).trim()); });
    const take = (piece, endOfLine) => {
      if (!skipping) {
        if (size + piece.length > SCAN_LINE_MAX) {
          skipping = true;
          parts = [];
        } else {
          parts.push(piece);
          size += piece.length;
        }
      }
      if (endOfLine) {
        if (!skipping) onLine(Buffer.concat(parts, size).toString('utf8'));
        parts = [];
        size = 0;
        skipping = false;
      }
    };
    return {
      push(chunk) {
        let start = 0;
        for (let end = chunk.indexOf(0x0a, start); end !== -1; end = chunk.indexOf(0x0a, start)) {
          take(chunk.subarray(start, end), true);
          start = end + 1;
        }
        if (start < chunk.length) take(chunk.subarray(start), false);
      },
      end() {},
    };
  }

  // A reply in one piece: keep a copy up to the limit and read it at the end.
  let parts = [];
  let size = 0;
  return {
    push(chunk) {
      if (parts === null) return;
      size += chunk.length;
      if (size > SCAN_JSON_MAX) parts = null; else parts.push(chunk);
    },
    end: quietly(() => { if (parts !== null) scanner.json(JSON.parse(Buffer.concat(parts, size).toString('utf8'))); }),
  };
}

// ---------------------------------------------------------------------------
// Reaching the vendor  [logical B21, B22]
// The only way out of this container is the Squid proxy, and Squid lets the
// vendor's host through from this container's address only. So: ask the
// proxy for a tunnel (HTTP CONNECT) to <upstream host>:443, then speak TLS
// through it, checking the vendor's certificate against the system's trust
// store and the host name, exactly as any HTTPS client would. The proxy
// sees the host name and nothing else. One tunnel per request, closed after
// it: simple, and nothing stale is ever reused.
// ---------------------------------------------------------------------------
function openTunnel() {
  return new Promise((resolve, reject) => {
    const target = `${routing.host}:443`;
    const connect = http.request({
      host: wayOut.proxy.host, port: wayOut.proxy.port, method: 'CONNECT', path: target,
      headers: { host: target }, agent: false, timeout: TUNNEL_TIMEOUT_MS,
    });
    connect.once('timeout', () => connect.destroy(new Error('the egress proxy did not answer in time')));
    connect.once('error', (err) => reject(new Error(`cannot reach the egress proxy: ${err.message}`)));
    connect.once('connect', (res, socket) => {
      socket.setTimeout(0);
      if (res.statusCode !== 200) {
        socket.destroy();
        reject(new Error(`the egress proxy refused the tunnel to ${target} (status ${res.statusCode}); is the host on the sidecar's allowlist?`));
        return;
      }
      const secure = tls.connect({ socket, servername: routing.host, ALPNProtocols: ['http/1.1'] });
      secure.setTimeout(TUNNEL_TIMEOUT_MS, () => secure.destroy(new Error('the TLS handshake did not finish in time')));
      secure.once('error', (err) => reject(new Error(`TLS to ${routing.host} failed: ${err.message}`)));
      secure.once('secureConnect', () => {
        secure.setTimeout(0);
        resolve(secure);
      });
    });
    connect.end();
  });
}

// ---------------------------------------------------------------------------
// Answering
// Every error this server writes itself has the same shape, which both
// vendors' clients can read: {"type":"error","error":{"type","message"}}.
// It never answers 401: a CLI that sees 401 tries to refresh its login or
// ends the turn.
// ---------------------------------------------------------------------------
function answer(ctx, status, type, message, extraHeaders = {}) {
  const { res } = ctx;
  if (res.headersSent || res.destroyed) return;
  const body = Buffer.from(JSON.stringify({ type: 'error', error: { type, message } }));
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': body.length, ...extraHeaders });
  res.end(body);
}

function refuse(ctx, status, type, message, extraHeaders) {
  ctx.entry.refused = type;
  ctx.entry.detail = clip(message, 300);
  answer(ctx, status, type, message, extraHeaders);
}

// Read the request body into memory, up to the limits.  [logical B24]
// On overflow the rest is read and thrown away, so that the client gets the
// answer instead of a broken connection.
function readBody(ctx) {
  const { req } = ctx;
  return new Promise((resolve) => {
    let chunks = [];
    let size = 0;
    const stop = (problem) => {
      chunks = null;
      req.off('data', onData);
      req.resume();
      resolve({ problem });
    };
    const onData = (chunk) => {
      size += chunk.length;
      ctx.held += chunk.length;
      heldBytes += chunk.length;
      if (size > BODY_MAX) stop('too_large');
      else if (heldBytes > HELD_MAX) stop('busy');
      else chunks.push(chunk);
    };
    req.on('data', onData);
    req.once('end', () => { if (chunks) resolve({ raw: Buffer.concat(chunks, size) }); });
    req.once('error', () => resolve({ problem: 'aborted' }));
    req.once('close', () => resolve({ problem: 'aborted' }));   // no effect once resolved
  });
}

// ---------------------------------------------------------------------------
// One request
// ---------------------------------------------------------------------------
let budgetLeft = 0;
let inFlight = 0;
let heldBytes = 0;

async function handle(req, res) {
  const started = Date.now();
  const mark = req.url.indexOf('?');
  const pathOnly = mark === -1 ? req.url : req.url.slice(0, mark);

  // For sidecar-healthcheck and the launcher. Not logged, so it cannot be
  // used to fill the log.
  if (req.method === 'GET' && pathOnly === '/healthz') {
    const body = JSON.stringify({ status: 'ok', credential_loaded: currentCredential() !== null });
    res.writeHead(200, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) });
    res.end(body);
    return;
  }

  const entry = { event: 'request', method: clip(req.method, 16), path: clip(pathOnly, 200) };
  const ctx = { req, res, entry, held: 0, searches: [], upstream: null, counted: false };
  res.once('close', () => {
    heldBytes -= ctx.held;
    if (ctx.upstream && !res.writableFinished) ctx.upstream.destroy();   // the client went away: stop the vendor request too
    if (ctx.searches.length > 0) {
      entry.web_search = ctx.searches.slice(0, LOG_SEARCH_MAX).map((s) => {
        const out = { from: s.from };
        if (s.kind !== undefined) out.kind = clip(s.kind, 32);
        if (s.query !== undefined) out.query = clip(s.query, 400);
        if (s.url !== undefined) out.url = clip(s.url, 400);
        if (s.pattern !== undefined) out.pattern = clip(s.pattern, 200);
        return out;
      });
      if (ctx.searches.length > LOG_SEARCH_MAX) entry.web_search_more = ctx.searches.length - LOG_SEARCH_MAX;
    }
    entry.status = res.headersSent ? res.statusCode : 0;   // 0: the client left before any answer
    if (!res.writableFinished) entry.cut_short = true;
    entry.ms = Date.now() - started;
    entry.budget_left = budgetLeft;
    // [logical B25] A forwarded model request is always logged; the budget
    // bounds how many there can be. Everything else shares the capped lane.
    if (ctx.counted) log(entry); else logCapped(entry);
  });

  // [logical B23] Only the routes this agent's CLI needs. The path must
  // match a listed one exactly; nothing is normalised, so there is no
  // second spelling to slip through.
  const route = routing.routes.get(`${req.method} ${pathOnly}`);
  if (!route) return refuse(ctx, 404, 'sandbox_route_not_forwarded', `the sandbox does not forward ${clip(req.method, 16)} ${clip(pathOnly, 200)}`);

  // [logical B24] At most MAX_IN_FLIGHT at once. "Try again in a second" is
  // the right answer here: the CLIs retry a 503.
  if (inFlight >= MAX_IN_FLIGHT) return refuse(ctx, 503, 'sandbox_busy', 'the sandbox is already serving its limit of requests; try again shortly', { 'retry-after': '1' });
  inFlight += 1;
  res.once('close', () => { inFlight -= 1; });

  // [logical B22] No credential yet: "not ready", never "unauthorised".
  const cred = currentCredential();
  if (!cred) return refuse(ctx, 503, 'sandbox_credential_not_loaded', `the sandbox cannot make model requests: ${credential.problem}. The operator can load one with ./sandbox login`, { 'retry-after': '2' });

  // [logical B23, B24] The body.
  let body = null;
  if (route.rules) {
    if (req.headers['content-encoding'] && req.headers['content-encoding'].toLowerCase() !== 'identity') {
      return refuse(ctx, 400, 'sandbox_body_unreadable', `the sandbox has to read the request body and cannot read content-encoding "${clip(req.headers['content-encoding'], 32)}"; send it uncompressed`);
    }
    if (Number(req.headers['content-length']) > BODY_MAX) return refuse(ctx, 413, 'sandbox_body_too_large', `the request body is larger than the sandbox's limit of ${BODY_MAX} bytes`);
    const read = await readBody(ctx);
    if (read.problem === 'aborted') return res.destroy();
    if (read.problem === 'too_large') return refuse(ctx, 413, 'sandbox_body_too_large', `the request body is larger than the sandbox's limit of ${BODY_MAX} bytes`);
    if (read.problem === 'busy') return refuse(ctx, 503, 'sandbox_busy', 'the sandbox is holding its limit of request data; try again shortly', { 'retry-after': '1' });
    let inspected;
    try {
      const parsed = JSON.parse(read.raw.toString('utf8'));
      inspected = inspectBody(parsed, route.rules);
      if (!inspected.refusal) {
        body = Buffer.from(JSON.stringify(parsed));
        if (!body.equals(read.raw)) entry.rewritten = true;   // the vendor gets the checked form, which differed in its bytes
      }
    } catch {
      return refuse(ctx, 400, 'sandbox_body_unreadable', 'the request body is not JSON the sandbox can read, so it cannot be checked');
    }
    if (inspected.refusal) return refuse(ctx, 400, `sandbox_${inspected.refusal.reason}`, inspected.refusal.message);
    const { searches, ...summary } = inspected.summary;
    Object.assign(entry, summary);
    ctx.searches.push(...searches);
  } else if (Number(req.headers['content-length']) > 0 || req.headers['transfer-encoding'] !== undefined) {
    return refuse(ctx, 400, 'sandbox_body_not_expected', 'the sandbox forwards no request body on this route');
  }

  // [logical B24] The budget. Checked and taken in one step, after every
  // refusal above and before anything is sent, so a request the vendor
  // never saw costs nothing and a request past the budget never leaves.
  if (route.model) {
    if (budgetLeft <= 0) return refuse(ctx, 403, 'sandbox_budget_exhausted', 'this sandbox session has used its whole budget of model requests. The operator sets it with ./sandbox run --budget N; a new session starts a new count');
    budgetLeft -= 1;
    ctx.counted = true;
  }

  // [logical B22] The headers that go to the vendor: everything the CLI
  // sent (anthropic-beta, anthropic-version, user-agent, x-app,
  // x-stainless-*, ...) except what describes the connection, what the
  // agent offered as a credential, and anything the Connection header
  // names. Then the real credential.
  const headers = {};
  const named = String(req.headers.connection ?? '').toLowerCase().split(',').map((s) => s.trim());
  for (const [name, value] of Object.entries(req.headers)) {
    if (HOP_BY_HOP.has(name) || routing.strip.has(name) || named.includes(name)) continue;
    headers[name] = value;
  }
  for (const [name, template] of routing.inject) {
    headers[name] = template.replace('{token}', () => cred.token).replace('{account_id}', () => cred.account_id);
  }
  headers.host = routing.host;
  if (body) {
    headers['content-type'] = 'application/json';
    headers['content-length'] = body.length;
    headers['accept-encoding'] = 'identity';   // so the reply can be read for web search queries as it passes
  }

  const options = { method: req.method, path: req.url, headers, setHost: false };
  if (wayOut.override) {
    Object.assign(options, { host: wayOut.override.host, port: wayOut.override.port, agent: false });
  } else {
    let socket;
    try {
      socket = await openTunnel();
    } catch (err) {
      entry.error = clip(err.message, 200);
      return answer(ctx, 502, 'sandbox_upstream_unreachable', `the sandbox could not reach the model vendor: ${clip(err.message, 200)}`);
    }
    if (res.destroyed) return socket.destroy();
    options.createConnection = () => socket;
  }

  const upstream = http.request(options);
  ctx.upstream = upstream;
  upstream.setTimeout(UPSTREAM_IDLE_MS, () => upstream.destroy(new Error('the vendor sent nothing for ten minutes')));
  upstream.once('error', (err) => {
    entry.error = clip(err.message, 200);
    if (res.writableEnded) return;        // the reply was already complete
    if (res.headersSent) res.destroy();   // mid-reply: the agent sees the reply cut short
    else answer(ctx, 502, 'sandbox_upstream_failed', `the request to the model vendor failed: ${clip(err.message, 200)}`);
  });
  upstream.once('response', (reply) => {
    // The vendor rejected the credential. Passing 401 on would make the CLI
    // try to refresh a login it does not have; say what happened instead.
    // The vendor's own error body is not passed on.
    if (reply.statusCode === 401) {
      entry.upstream_status = 401;
      reply.resume();
      return answer(ctx, 403, 'sandbox_credential_rejected', 'the model vendor rejected the sandbox\'s credential (it may have expired or been revoked). The agent cannot fix this; the operator can, with ./sandbox login');
    }
    const replyHeaders = [];
    for (let i = 0; i < reply.rawHeaders.length; i += 2) {
      if (!REPLY_DROP.has(reply.rawHeaders[i].toLowerCase())) replyHeaders.push(reply.rawHeaders[i], reply.rawHeaders[i + 1]);
    }
    try {
      res.writeHead(reply.statusCode, replyHeaders);
    } catch (err) {
      reply.destroy();
      return answer(ctx, 502, 'sandbox_upstream_failed', `the model vendor's reply could not be passed on: ${clip(err.message, 200)}`);
    }
    res.flushHeaders();
    // [logical B25] Look at a copy of the reply as it passes.
    const watcher = reply.statusCode === 200 && route.rules
      ? replyWatcher(route.rules, reply.headers['content-type'], (found) => { if (ctx.searches.length < 1000) ctx.searches.push(found); })
      : null;
    if (watcher) {
      reply.on('data', watcher.push);
      reply.once('end', watcher.end);
    }
    // The reply itself goes through unchanged, piece by piece as it comes.
    pipeline(reply, res, () => {});
  });
  upstream.end(body ?? undefined);
}

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------
process.umask(0o077);
process.stdout.on('error', () => {});   // a closed log pipe must not stop requests
const routing = readRouting();
const wayOut = readWayOut();
const listen = readListen();
budgetLeft = readBudget();
ensurePrivateDir(CRED_DIR);

const server = http.createServer((req, res) => {
  handle(req, res).catch((err) => {
    log({ event: 'error', message: clip(err?.message ?? err, 300) });
    if (res.headersSent) res.destroy();
    else answer({ res }, 500, 'sandbox_internal_error', 'the sandbox sidecar hit an internal error; see its log');
  });
});
server.maxConnections = MAX_CONNECTIONS;
server.on('error', (err) => die(`cannot listen on ${listen.host}:${listen.port}: ${err.message}`));
server.listen(listen.port, listen.host, () => {
  log({
    event: 'start', agent: AGENT, auth: AUTH, upstream: routing.host, routes: [...routing.routes.keys()], budget: budgetLeft,
    listen: `${listen.host}:${server.address().port}`,
    ...(wayOut.override ? { test_upstream_override: `http://${wayOut.override.host}:${wayOut.override.port}` } : {}),
  });
  currentCredential();
});

setInterval(() => { if (Date.now() - capped.windowStart >= 60_000) flushSuppressed(); }, 60_000).unref();

// Podman stops a container with SIGTERM. Stop taking requests, give the
// ones in flight a moment, and go. Node is the container's first process,
// and a first process ignores a signal it has no handler for.
function shutdown(signal) {
  flushSuppressed();
  log({ event: 'stop', signal, budget_left: budgetLeft });
  server.close(() => process.exit(0));
  server.closeIdleConnections();
  setTimeout(() => process.exit(0), SHUTDOWN_GRACE_MS).unref();
}
process.once('SIGTERM', () => shutdown('SIGTERM'));
process.once('SIGINT', () => shutdown('SIGINT'));
