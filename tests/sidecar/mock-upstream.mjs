#!/usr/bin/env node
// mock-upstream.mjs — a stand-in for the model vendors' APIs, for the tests.
//
// It answers the handful of paths the three CLIs call with canned replies
// shaped like the real ones, and it RECORDS every request it receives
// (method, path, headers, body) so that the test can check what the sidecar
// really sent: which credential, which headers, which body.
//
// It is not a judge of anything: it accepts any credential. The test reads
// the record and does the judging.
//
// Plain HTTP by default. With MOCK_TLS_KEY and MOCK_TLS_CERT (paths to PEM
// files) it serves the same thing over TLS, for the test of the sidecar's
// tunnel through a proxy.
//
// Control paths, used by the test only:
//   GET  /__mock/requests   everything recorded so far, as JSON
//   POST /__mock/reset      forget it
// Request headers that steer a reply:
//   x-mock-status: 401      answer 401 as a vendor does for a bad credential
//   x-mock-delay-ms: N      wait N milliseconds before answering
//
// When it is listening it prints one line: {"port": N}

import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';

// The queries "the model chose". The test looks for these in the sidecar's log.
export const CLAUDE_REPLY_QUERY = 'mock claude reply query: rootless podman cgroup';
export const CODEX_REPLY_QUERY = 'mock codex reply query: café ☃ seccomp';
export const CODEX_REPLY_URL = 'https://example.org/opened-by-the-vendor';
export const ACCOUNTS_CHECK = { accounts: { 'mock-account': { account: { plan_type: 'plus' } } }, account_ordering: ['mock-account'] };

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const sse = (event, data) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;

// A streamed Anthropic reply: numbered text pieces, so the test can check
// order, and (when the request enabled web search) a server_tool_use block
// whose input arrives in fragments, as the real API sends it.
export function claudeEvents(withSearch) {
  const events = [sse('message_start', { type: 'message_start', message: { id: 'msg_mock', role: 'assistant', content: [] } })];
  if (withSearch) {
    const input = JSON.stringify({ query: CLAUDE_REPLY_QUERY });
    events.push(sse('content_block_start', { type: 'content_block_start', index: 0, content_block: { type: 'server_tool_use', id: 'srvtoolu_mock', name: 'web_search', input: {} } }));
    for (const piece of [input.slice(0, 7), input.slice(7, 30), input.slice(30)]) {
      events.push(sse('content_block_delta', { type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta', partial_json: piece } }));
    }
    events.push(sse('content_block_stop', { type: 'content_block_stop', index: 0 }));
  }
  events.push(sse('content_block_start', { type: 'content_block_start', index: 1, content_block: { type: 'text', text: '' } }));
  for (let n = 0; n < 6; n += 1) {
    events.push(sse('content_block_delta', { type: 'content_block_delta', index: 1, delta: { type: 'text_delta', text: `piece-${n} ` } }));
  }
  events.push(sse('content_block_stop', { type: 'content_block_stop', index: 1 }));
  events.push(sse('message_stop', { type: 'message_stop' }));
  return events;
}

// A streamed Responses API reply holding two web_search_call items, the
// shape the Codex path of the sidecar looks for.
export function codexStream() {
  const search = { id: 'ws_mock_1', type: 'web_search_call', status: 'completed', action: { type: 'search', query: CODEX_REPLY_QUERY } };
  const open = { id: 'ws_mock_2', type: 'web_search_call', status: 'completed', action: { type: 'open_page', url: CODEX_REPLY_URL } };
  const message = { id: 'msg_mock', type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'hello from the mock' }] };
  return [
    sse('response.created', { type: 'response.created', response: { id: 'resp_mock', status: 'in_progress' } }),
    sse('response.output_item.added', { type: 'response.output_item.added', output_index: 0, item: { id: 'ws_mock_1', type: 'web_search_call', status: 'in_progress' } }),
    sse('response.output_item.done', { type: 'response.output_item.done', output_index: 0, item: search }),
    sse('response.output_item.done', { type: 'response.output_item.done', output_index: 1, item: open }),
    sse('response.output_text.delta', { type: 'response.output_text.delta', output_index: 2, delta: 'hello from the mock' }),
    sse('response.output_item.done', { type: 'response.output_item.done', output_index: 2, item: message }),
    sse('response.completed', { type: 'response.completed', response: { id: 'resp_mock', status: 'completed', output: [search, open, message] } }),
  ].join('');
}

const recorded = [];

function json(res, status, body, extra = {}) {
  const text = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json', 'content-length': Buffer.byteLength(text),
    'x-request-id': 'mock-request-id', 'set-cookie': 'mock_session=should-not-reach-the-agent', ...extra,
  });
  res.end(text);
}

async function handle(req, res) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const body = Buffer.concat(chunks).toString('utf8');
  const pathOnly = req.url.split('?')[0];

  if (pathOnly === '/__mock/requests') return json(res, 200, recorded);
  if (pathOnly === '/__mock/reset') { recorded.length = 0; return json(res, 200, { reset: true }); }

  recorded.push({ method: req.method, url: req.url, headers: req.headers, rawHeaders: req.rawHeaders, body });

  if (req.headers['x-mock-delay-ms']) await sleep(Number(req.headers['x-mock-delay-ms']));
  if (req.headers['x-mock-status'] === '401') {
    return json(res, 401, { type: 'error', error: { type: 'authentication_error', message: 'invalid bearer token' } }, { 'www-authenticate': 'Bearer' });
  }

  let parsed = {};
  try { parsed = body ? JSON.parse(body) : {}; } catch { /* the mock does not judge */ }
  const route = `${req.method} ${pathOnly}`;

  if (route === 'POST /v1/messages') {
    const withSearch = Array.isArray(parsed.tools) && parsed.tools.some((t) => String(t?.type).startsWith('web_search'));
    if (parsed.stream === true) {
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', 'x-request-id': 'mock-request-id' });
      // One event at a time with a pause between, as a model produces them.
      for (const event of claudeEvents(withSearch)) {
        res.write(event);
        await sleep(40);
      }
      return res.end();
    }
    const content = [{ type: 'text', text: 'hello from the mock' }];
    if (withSearch) content.unshift({ type: 'server_tool_use', id: 'srvtoolu_mock', name: 'web_search', input: { query: CLAUDE_REPLY_QUERY } });
    return json(res, 200, { id: 'msg_mock', type: 'message', role: 'assistant', content });
  }
  if (route === 'POST /v1/messages/count_tokens') return json(res, 200, { input_tokens: 42 });

  if (route === 'POST /backend-api/codex/responses' || route === 'POST /v1/responses') {
    res.writeHead(200, { 'content-type': 'text/event-stream', 'x-request-id': 'mock-request-id' });
    // Written in small slices that ignore line and character boundaries, to
    // exercise a reader that has to put lines back together.
    const stream = Buffer.from(codexStream());
    for (let at = 0; at < stream.length; at += 37) {
      res.write(stream.subarray(at, at + 37));
      await sleep(1);
    }
    return res.end();
  }
  if (route === 'POST /v1/chat/completions') {
    return json(res, 200, { id: 'chatcmpl_mock', object: 'chat.completion', choices: [{ index: 0, message: { role: 'assistant', content: 'hello from the mock' } }] });
  }
  if (route === 'GET /backend-api/wham/accounts/check') return json(res, 200, ACCOUNTS_CHECK);
  if (['GET /backend-api/codex/models', 'GET /backend-api/wham/usage', 'GET /backend-api/wham/rate-limit-reset-credits', 'GET /v1/models'].includes(route)) {
    return json(res, 200, { mock: true, path: pathOnly });
  }
  return json(res, 404, { error: { message: 'mock: no such path' } });
}

// Run as a program (the test starts it as its own process); the constants
// above can also be imported.
if (process.argv[1] && fs.realpathSync(process.argv[1]) === fs.realpathSync(new URL(import.meta.url).pathname)) {
  const onRequest = (req, res) => { handle(req, res).catch(() => res.destroy()); };
  const server = process.env.MOCK_TLS_KEY
    ? https.createServer({ key: fs.readFileSync(process.env.MOCK_TLS_KEY), cert: fs.readFileSync(process.env.MOCK_TLS_CERT) }, onRequest)
    : http.createServer(onRequest);
  server.listen(0, '127.0.0.1', () => process.stdout.write(`${JSON.stringify({ port: server.address().port })}\n`));
  process.once('SIGTERM', () => process.exit(0));
}
