// server/src/sfu-node/controlServer.js
//
// Internal control interface of one SFU node: HTTP/2 over mutual TLS on the node's PRIVATE IP.
//
//   POST /rpc/<method>   JSON body → { ok: true, result } | { ok: false, error: { code, message } }
//   GET  /events         NDJSON stream of node events (producer closed, ICE state, …) + ping every 15 s
//   GET  /healthz/sfu    node health for the ECS container check and the node-lifecycle Lambda
//
// Who may call:
//   network   security group: control port only from the realtime service's security group;
//   identity  client certificate signed by the control-plane CA (Secrets Manager, infra/core/secrets.tf)
//             whose subject CN is in allowedClients (default: "realtime"). /healthz/sfu needs no client
//             certificate so the container health check can run without one; it reveals only health.
//
// Reliability:
//   - x-request-id: a retried call with the same id returns the first call's result (dedupe window 60 s),
//     so sfuControlClient can retry transport failures without creating a second transport or producer;
//   - x-deadline: absolute epoch ms; calls that arrive after their deadline are rejected with 504 instead of
//     doing work nobody waits for;
//   - bodies are capped at 256 KiB.
//
// Owner: F1 Live Classrooms. Handlers: sfu-node/rpcHandlers.js. Client: signaling/sfuControlClient.js.

import http2 from 'node:http2';

const MAX_BODY_BYTES = 256 * 1024;
const DEDUPE_TTL_MS = 60_000;
const DEDUPE_MAX = 20_000;
const EVENT_PING_MS = 15_000;
const METHOD_PATTERN = /^\/rpc\/([a-zA-Z]+(\.[a-zA-Z]+)?)$/;
const REQUEST_ID_PATTERN = /^[A-Za-z0-9-]{8,64}$/;

/**
 * @param {object} options
 * @param {string} options.host                  private IPv4 of the node
 * @param {number} options.port                  SFU_CONTROL_PORT (7443)
 * @param {{ cert: string, key: string, ca: string }} options.tls  PEM; server cert SAN: sfu.control.internal
 * @param {{ methods: Record<string, (params: any) => Promise<any>>, events: import('node:events').EventEmitter }} options.handlers
 * @param {() => Promise<{ ok: boolean, details?: object }>} options.healthCheck
 * @param {string[]} [options.allowedClients=['realtime']]   accepted client certificate CNs
 * @param {{ info: Function, warn: Function, error: Function }} [options.logger]
 */
export function createControlServer({ host, port, tls, handlers, healthCheck, allowedClients = ['realtime'], logger = console }) {
  if (!tls?.cert || !tls?.key || !tls?.ca) throw new TypeError('createControlServer: tls.cert, tls.key and tls.ca are required');
  if (!handlers?.methods || !handlers?.events) throw new TypeError('createControlServer: handlers must be { methods, events }');

  const allowed = new Set(allowedClients);
  /** @type {Map<string, { promise: Promise<any>, expires: number }>} */
  const dedupe = new Map();
  const eventStreams = new Set();

  const server = http2.createSecureServer({
    cert: tls.cert,
    key: tls.key,
    ca: tls.ca,
    requestCert: true,
    rejectUnauthorized: false, // decided per route: /healthz/sfu is open, everything else needs a valid client cert
    minVersion: 'TLSv1.3',
    allowHTTP1: false,
    settings: { maxConcurrentStreams: 1_000 },
  });

  server.on('sessionError', (err) => logger.warn({ err: { message: err.message } }, 'control session error'));
  server.on('tlsClientError', (err) => logger.warn({ err: { message: err.message } }, 'control tls handshake failed'));

  server.on('request', (req, res) => {
    handle(req, res).catch((err) => {
      logger.error({ err: { message: err.message, stack: err.stack } }, 'control request crashed');
      if (!res.headersSent) sendJson(res, 500, { ok: false, error: { code: 'INTERNAL', message: 'internal error' } });
    });
  });

  async function handle(req, res) {
    const path = req.url.split('?')[0];

    if (req.method === 'GET' && path === '/healthz/sfu') {
      let result;
      try {
        result = await healthCheck();
      } catch (err) {
        result = { ok: false, details: { error: err.message } };
      }
      return sendJson(res, result.ok ? 200 : 503, { status: result.ok ? 'ok' : 'unhealthy', ...result.details });
    }

    const caller = authorisedCaller(req);
    if (!caller) return sendJson(res, 403, { ok: false, error: { code: 'FORBIDDEN', message: 'client certificate required' } });

    if (req.method === 'GET' && path === '/events') return streamEvents(req, res);

    const match = req.method === 'POST' ? METHOD_PATTERN.exec(path) : null;
    const method = match?.[1];
    const fn = method ? handlers.methods[method] : undefined;
    if (!fn) return sendJson(res, 404, { ok: false, error: { code: 'UNKNOWN_METHOD', message: `unknown method ${path}` } });

    const deadline = Number(req.headers['x-deadline'] ?? 0);
    if (deadline && Date.now() > deadline) {
      return sendJson(res, 504, { ok: false, error: { code: 'DEADLINE_EXCEEDED', message: 'deadline passed before execution' } });
    }

    let params;
    try {
      params = JSON.parse((await readBody(req)) || '{}');
    } catch (err) {
      const tooLarge = err.code === 'BODY_TOO_LARGE';
      return sendJson(res, tooLarge ? 413 : 400, { ok: false, error: { code: tooLarge ? 'BODY_TOO_LARGE' : 'BAD_JSON', message: err.message } });
    }

    const requestId = String(req.headers['x-request-id'] ?? '');
    const run = () => fn(params);
    const promise = REQUEST_ID_PATTERN.test(requestId) ? deduped(`${method}:${requestId}`, run) : run();

    try {
      const result = await promise;
      return sendJson(res, 200, { ok: true, result: result ?? {} });
    } catch (err) {
      const status = Number.isInteger(err.status) ? err.status : 500;
      if (status >= 500 && err.code !== 'NODE_DRAINING') {
        logger.error({ method, requestId, err: { message: err.message, code: err.code } }, 'control rpc failed');
      }
      const expose = err.expose || status < 500 || err.code === 'NODE_DRAINING';
      return sendJson(res, status, {
        ok: false,
        error: { code: err.code ?? 'INTERNAL', message: expose ? err.message : 'internal error' },
      });
    }
  }

  function authorisedCaller(req) {
    const socket = req.stream?.session?.socket;
    if (!socket?.authorized) return null;
    const cn = socket.getPeerCertificate()?.subject?.CN;
    return allowed.has(cn) ? cn : null;
  }

  function deduped(key, run) {
    const now = Date.now();
    const hit = dedupe.get(key);
    if (hit && hit.expires > now) return hit.promise;
    const promise = run();
    dedupe.set(key, { promise, expires: now + DEDUPE_TTL_MS });
    // Failed calls are not cached: a retry after an error must be allowed to try again.
    promise.catch(() => dedupe.delete(key));
    if (dedupe.size > DEDUPE_MAX) {
      for (const [k, v] of dedupe) {
        if (v.expires <= now || dedupe.size > DEDUPE_MAX) dedupe.delete(k);
        if (dedupe.size <= DEDUPE_MAX * 0.9) break;
      }
    }
    return promise;
  }

  function streamEvents(req, res) {
    res.writeHead(200, { 'content-type': 'application/x-ndjson', 'cache-control': 'no-store' });
    const write = (event) => {
      if (!res.writableEnded) res.write(`${JSON.stringify(event)}\n`);
    };
    const ping = setInterval(() => write({ type: 'ping', at: Date.now() }), EVENT_PING_MS);
    handlers.events.on('event', write);
    const entry = { res, close: () => res.end() };
    eventStreams.add(entry);
    write({ type: 'hello', at: Date.now() });
    const cleanup = () => {
      clearInterval(ping);
      handlers.events.off('event', write);
      eventStreams.delete(entry);
    };
    req.on('close', cleanup);
    res.on('close', cleanup);
  }

  return {
    listen() {
      return new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(port, host, () => {
          server.off('error', reject);
          logger.info({ host, port }, 'sfu control server listening (mTLS)');
          resolve();
        });
      });
    },
    close() {
      for (const stream of eventStreams) stream.close();
      return new Promise((resolve) => server.close(() => resolve()));
    },
  };
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        const err = new Error('request body exceeds 256 KiB');
        err.code = 'BODY_TOO_LARGE';
        req.destroy();
        reject(err);
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function sendJson(res, status, body) {
  if (res.headersSent) return;
  const payload = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  res.end(payload);
}