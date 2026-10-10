// A stand-in for a git host, for the relay's end-to-end test: real
// repositories served by git's own `git http-backend` (a CGI program that
// ships with git), behind a few lines of node that
//   * demand one exact Authorization header, answering 401 like a real host
//     when it is missing or wrong, and
//   * RECORD the headers of every request, so the test can check what the
//     relay sent.
// Test code only; nothing here is part of the sandbox.

import http from 'node:http';
import https from 'node:https';
import { spawn } from 'node:child_process';

// root: directory holding the bare repositories. authorization: the header
// value to demand. tlsOptions: { key, cert } to serve HTTPS instead of HTTP.
export function startMockUpstream({ root, authorization, tlsOptions = null }) {
  const seen = [];
  const handler = (request, response) => {
    const url = new URL(request.url, 'http://mock.invalid');
    seen.push({
      method: request.method,
      path: url.pathname,
      query: url.search,
      authorization: request.headers.authorization || '',
      contentEncoding: request.headers['content-encoding'] || '',
      transferEncoding: request.headers['transfer-encoding'] || '',
      gitProtocol: request.headers['git-protocol'] || '',
    });
    if (request.headers.authorization !== authorization) {
      request.resume();
      response.writeHead(401, { 'WWW-Authenticate': 'Basic realm="mock git host"', 'Content-Type': 'text/plain' });
      response.end('Bad credentials\n');
      return;
    }

    // The CGI interface: the request is described in environment variables,
    // the body arrives on stdin, and the answer (headers, blank line, body)
    // comes back on stdout.
    const env = {
      PATH: process.env.PATH,
      GIT_CONFIG_NOSYSTEM: '1',
      GIT_CONFIG_GLOBAL: '/dev/null',
      GIT_PROJECT_ROOT: root,
      GIT_HTTP_EXPORT_ALL: '1',
      REQUEST_METHOD: request.method,
      PATH_INFO: url.pathname,
      QUERY_STRING: url.search.slice(1),
      CONTENT_TYPE: request.headers['content-type'] || '',
      REMOTE_USER: 'relay',          // http-backend allows pushes only from a named user
      REMOTE_ADDR: '127.0.0.1',
    };
    if (request.headers['content-length'] !== undefined) env.CONTENT_LENGTH = request.headers['content-length'];
    if (request.headers['content-encoding'] !== undefined) env.HTTP_CONTENT_ENCODING = request.headers['content-encoding'];
    if (request.headers['git-protocol'] !== undefined) {
      env.GIT_PROTOCOL = request.headers['git-protocol'];
      env.HTTP_GIT_PROTOCOL = request.headers['git-protocol'];
    }
    const backend = spawn('git', ['http-backend'], { env, stdio: ['pipe', 'pipe', 'inherit'] });
    backend.stdin.on('error', () => {});
    request.pipe(backend.stdin);

    let pending = Buffer.alloc(0);
    let headersSent = false;
    backend.stdout.on('data', (chunk) => {
      if (headersSent) {
        response.write(chunk);
        return;
      }
      pending = Buffer.concat([pending, chunk]);
      const end = pending.indexOf('\r\n\r\n');
      if (end === -1) return;
      let status = 200;
      const headers = {};
      for (const line of pending.subarray(0, end).toString('latin1').split('\r\n')) {
        const colon = line.indexOf(':');
        const name = line.slice(0, colon);
        const value = line.slice(colon + 1).trim();
        if (name.toLowerCase() === 'status') status = Number.parseInt(value, 10);
        else headers[name] = value;
      }
      response.writeHead(status, headers);
      response.write(pending.subarray(end + 4));
      headersSent = true;
    });
    backend.stdout.on('end', () => {
      if (!headersSent) response.writeHead(500);
      response.end();
    });
  };

  const server = tlsOptions ? https.createServer(tlsOptions, handler) : http.createServer(handler);
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve({ server, port: server.address().port, seen }));
  });
}
