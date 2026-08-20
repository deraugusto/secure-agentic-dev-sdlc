'use strict';

// The lifecycle proof (ADR-0001).
//
// Node standard library only, no dependencies, two routes. Everything this
// service does beyond existing would be surface area distracting from the thing
// being demonstrated -- which is the pipeline around it, not the service.
//
// The listen address comes from the environment and defaults to loopback. No
// deployment address appears in this file, or in any file except inventory.yaml.

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

const HOST = process.env.HOST || '127.0.0.1';
const PORT = Number.parseInt(process.env.PORT || '3000', 10);
const SERVICE = 'hello-world';

function readVersion() {
  try {
    const raw = fs.readFileSync(path.join(__dirname, 'package.json'), 'utf8');
    return JSON.parse(raw).version || '0.0.0';
  } catch {
    return '0.0.0';
  }
}

const VERSION = readVersion();
const STARTED_AT = new Date().toISOString();

function json(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(payload),
    'cache-control': 'no-store',
  });
  res.end(payload);
}

function text(res, status, body) {
  res.writeHead(status, {
    'content-type': 'text/plain; charset=utf-8',
    'content-length': Buffer.byteLength(body),
  });
  res.end(body);
}

const server = http.createServer((req, res) => {
  const route = (req.url || '/').split('?')[0];

  if (req.method !== 'GET') {
    return json(res, 405, { error: 'method-not-allowed' });
  }

  // The smoke contract. The deploy sequence treats anything other than 200
  // with status "ok" as a failed deploy and rolls back.
  if (route === '/healthz') {
    return json(res, 200, {
      status: 'ok',
      service: SERVICE,
      version: VERSION,
      started_at: STARTED_AT,
    });
  }

  if (route === '/') {
    return text(res, 200,
      `Hello from the agentic SDLC baseline.\nservice=${SERVICE} version=${VERSION}\n`);
  }

  // Two declared routes and nothing else. An example that answers everything
  // teaches the wrong habit.
  return json(res, 404, { error: 'not-found', route });
});

server.listen(PORT, HOST, () => {
  process.stdout.write(`[${SERVICE}] listening on ${HOST}:${PORT} version=${VERSION}\n`);
});

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    server.close(() => process.exit(0));
    // A deploy that cannot stop the old process cannot roll back to it.
    setTimeout(() => process.exit(0), 2000).unref();
  });
}
