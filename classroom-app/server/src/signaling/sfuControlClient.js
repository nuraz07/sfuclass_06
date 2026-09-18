// server/src/signaling/sfuControlClient.js
//
// Client of the SFU control plane, used by the realtime service only (signaling/socketHandlers.js).
// Talks HTTP/2 over mutual TLS to the private control address of the node that owns a room
// (RoomRegistry → controlAddress, e.g. 10.20.3.17:7443; cross-region via Transit Gateway).
//
//   call(address, method, params, options)   one RPC with deadline and safe retries
//   subscribe(address, listener)             node event stream (NDJSON), shared per node, auto-reconnect
//   pipeProducer({ roomId, producerId, origin, edge })   node-to-node cascading handshake
//   close()
//
// Deadlines: every call has one (default 2 s). It bounds the whole call including retries and is sent
// to the node as x-deadline so late work is skipped there too.
//
// Retries: only for transport failures (connection refused/reset, GOAWAY, stream reset) and 503/504 that
// are not NODE_DRAINING — at most `retries` times with jittered backoff inside the deadline. Every attempt
// carries the same x-request-id, and the node deduplicates by it, so a retry never creates a second
// transport, producer or consumer. Application errors (4xx) and NODE_DRAINING are returned immediately:
// the caller must re-place instead of retrying the same node.
//
// Identity: presents the realtime client certificate (CN=realtime) and verifies the node's certificate
// against the control-plane CA with the fixed name sfu.control.internal (nodes are addressed by IP).
//
// Owner: F1 Live Classrooms.

import http2 from 'node:http2';
import tls from 'node:tls';
import { randomUUID } from 'node:crypto';
import { setTimeout as sleep } from 'node:timers/promises';

const SERVER_NAME = 'sfu.control.internal';
const ADDRESS_PATTERN = /^(\d{1,3}(\.\d{1,3}){3}):(\d{2,5})$/;
const RETRYABLE_NET = new Set(['ECONNREFUSED', 'ECONNRESET', 'EPIPE', 'ETIMEDOUT', 'EHOSTUNREACH', 'ERR_HTTP2_GOAWAY_SESSION',
  'ERR_HTTP2_STREAM_ERROR', 'ERR_HTTP2_SESSION_ERROR', 'ERR_HTTP2_STREAM_CANCEL', 'ERR_HTTP2_INVALID_SESSION']);

export class SfuControlError extends Error {
  constructor(code, message, { status, retryable = false, address, method } = {}) {
    super(message);
    this.name = 'SfuControlError';
    this.code = code;
    this.status = status ?? 502;
    this.retryable = retryable;
    this.address = address;
    this.method = method;
  }
}

export class SfuControlClient {
  /**
   * @param {object} options
   * @param {{ cert: string, key: string, ca: string }} options.tls   realtime client certificate + control CA (PEM)
   * @param {number} [options.deadlineMs=2000]
   * @param {number} [options.retries=2]
   * @param {number} [options.idleSessionMs=300000]  close sessions to nodes that were not used for 5 min
   * @param {{ info: Function, warn: Function }} [options.logger]
   * @param {{ increment: Function, histogram?: Function }} [options.metrics]
   */
  constructor({ tls: tlsOptions, deadlineMs = 2_000, retries = 2, idleSessionMs = 300_000, logger = console, metrics }) {
    if (!tlsOptions?.cert || !tlsOptions?.key || !tlsOptions?.ca) {
      throw new TypeError('SfuControlClient: tls.cert, tls.key and tls.ca are required');
    }
    this.#tls = tlsOptions;
    this.#deadlineMs = deadlineMs;
    this.#retries = retries;
    this.#idleSessionMs = idleSessionMs;
    this.#logger = logger;
    this.#metrics = metrics ?? { increment: () => {} };
  }

  #tls;
  #deadlineMs;
  #retries;
  #idleSessionMs;
  #logger;
  #metrics;
  /** @type {Map<string, { session: import('node:http2').ClientHttp2Session, lastUsed: number, idleTimer: any }>} */
  #sessions = new Map();
  /** @type {Map<string, { listeners: Set<Function>, stop: () => void }>} */
  #subscriptions = new Map();
  #closed = false;

  /**
   * @param {string} address   "ip:port" from the registry
   * @param {string} method    e.g. 'transport.create'
   * @param {object} params
   * @param {{ deadlineMs?: number, requestId?: string }} [options]
   */
  async call(address, method, params = {}, { deadlineMs = this.#deadlineMs, requestId = randomUUID() } = {}) {
    parseAddress(address);
    const deadline = Date.now() + deadlineMs;
    const started = performance.now();
    let attempt = 0;
    for (;;) {
      try {
        const result = await this.#attempt(address, method, params, requestId, deadline);
        this.#metrics.histogram?.('sfu_control.latency_ms', performance.now() - started, { method });
        return result;
      } catch (err) {
        const error = normalise(err, address, method);
        const remaining = deadline - Date.now();
        if (!error.retryable || attempt >= this.#retries || remaining < 50) {
          this.#metrics.increment('sfu_control.failed', { method, code: error.code });
          throw error;
        }
        attempt += 1;
        this.#metrics.increment('sfu_control.retried', { method, code: error.code });
        this.#dropSession(address);
        await sleep(Math.min(remaining - 25, 50 * 2 ** attempt + Math.random() * 50));
      }
    }
  }

  /**
   * Subscribes to a node's event stream. All subscribers of one node share one HTTP/2 stream.
   * @param {string} address
   * @param {(event: object) => void} listener
   * @returns {() => void} unsubscribe
   */
  subscribe(address, listener) {
    parseAddress(address);
    let sub = this.#subscriptions.get(address);
    if (!sub) {
      sub = { listeners: new Set(), stop: () => {} };
      this.#subscriptions.set(address, sub);
      sub.stop = this.#runEventStream(address, sub);
    }
    sub.listeners.add(listener);
    return () => {
      sub.listeners.delete(listener);
      if (sub.listeners.size === 0) {
        sub.stop();
        this.#subscriptions.delete(address);
      }
    };
  }

  /**
   * Makes `producerId` of the room available on the edge node (architecture doc, section 4.8).
   * Pipes are reused per (room, node pair); the edge producer keeps the origin producer id.
   * @param {{ roomId: string, producerId: string, origin: { nodeId: string, address: string },
   *           edge: { nodeId: string, address: string }, deadlineMs?: number }} args
   */
  async pipeProducer({ roomId, producerId, origin, edge, deadlineMs = 5_000 }) {
    const opts = { deadlineMs };
    const [o, e] = await Promise.all([
      this.call(origin.address, 'pipe.open', { roomId, peerNode: edge.nodeId }, opts),
      this.call(edge.address, 'pipe.open', { roomId, peerNode: origin.nodeId }, opts),
    ]);
    await Promise.all([
      this.call(origin.address, 'pipe.connect', { pipeId: o.pipeId, ip: e.ip, port: e.port, srtpParameters: e.srtpParameters }, opts),
      this.call(edge.address, 'pipe.connect', { pipeId: e.pipeId, ip: o.ip, port: o.port, srtpParameters: o.srtpParameters }, opts),
    ]);
    const piped = await this.call(origin.address, 'pipe.consume', { pipeId: o.pipeId, producerId }, opts);
    return this.call(edge.address, 'pipe.produce', {
      roomId, pipeId: e.pipeId, producerId,
      kind: piped.kind, rtpParameters: piped.rtpParameters, paused: piped.paused, appData: piped.appData ?? {},
    }, opts);
  }

  async close() {
    this.#closed = true;
    for (const sub of this.#subscriptions.values()) sub.stop();
    this.#subscriptions.clear();
    await Promise.all([...this.#sessions.keys()].map((address) => this.#dropSession(address, true)));
  }

  // ------------------------------------------------------------------ internals

  #session(address) {
    if (this.#closed) throw new SfuControlError('CLIENT_CLOSED', 'control client closed', { status: 503 });
    const existing = this.#sessions.get(address);
    if (existing && !existing.session.closed && !existing.session.destroyed) {
      existing.lastUsed = Date.now();
      return existing.session;
    }
    const [host, port] = parseAddress(address);
    const session = http2.connect(`https://${host}:${port}`, {
      cert: this.#tls.cert,
      key: this.#tls.key,
      ca: this.#tls.ca,
      servername: SERVER_NAME,
      minVersion: 'TLSv1.3',
      checkServerIdentity: (_host, cert) => tls.checkServerIdentity(SERVER_NAME, cert),
    });
    session.on('error', (err) => this.#logger.warn({ address, err: { message: err.message, code: err.code } }, 'sfu control session error'));
    session.on('close', () => {
      const entry = this.#sessions.get(address);
      if (entry?.session === session) {
        clearInterval(entry.idleTimer);
        this.#sessions.delete(address);
      }
    });
    const entry = { session, lastUsed: Date.now(), idleTimer: null };
    entry.idleTimer = setInterval(() => {
      if (Date.now() - entry.lastUsed > this.#idleSessionMs && !this.#subscriptions.has(address)) this.#dropSession(address);
    }, 60_000);
    entry.idleTimer.unref();
    this.#sessions.set(address, entry);
    return session;
  }

  #dropSession(address, graceful = false) {
    const entry = this.#sessions.get(address);
    if (!entry) return Promise.resolve();
    this.#sessions.delete(address);
    clearInterval(entry.idleTimer);
    return new Promise((resolve) => {
      if (entry.session.closed || entry.session.destroyed) return resolve();
      entry.session.once('close', resolve);
      if (graceful) entry.session.close();
      else entry.session.destroy();
    });
  }

  #attempt(address, method, params, requestId, deadline) {
    return new Promise((resolve, reject) => {
      const remaining = deadline - Date.now();
      if (remaining <= 0) {
        reject(new SfuControlError('DEADLINE_EXCEEDED', `${method} deadline exceeded`, { status: 504, address, method }));
        return;
      }
      const session = this.#session(address);
      const body = Buffer.from(JSON.stringify(params));
      const stream = session.request({
        ':method': 'POST',
        ':path': `/rpc/${method}`,
        'content-type': 'application/json',
        'content-length': body.length,
        'x-request-id': requestId,
        'x-deadline': String(deadline),
      });
      const timer = setTimeout(() => {
        stream.close(http2.constants.NGHTTP2_CANCEL);
        reject(new SfuControlError('DEADLINE_EXCEEDED', `${method} deadline exceeded`, { status: 504, address, method }));
      }, remaining);

      let status = 0;
      const chunks = [];
      stream.on('response', (headers) => { status = Number(headers[':status']); });
      stream.on('data', (chunk) => chunks.push(chunk));
      stream.on('error', (err) => {
        clearTimeout(timer);
        reject(err);
      });
      stream.on('end', () => {
        clearTimeout(timer);
        let payload;
        try {
          payload = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        } catch {
          reject(new SfuControlError('BAD_RESPONSE', `unparseable response (${status})`, { status: 502, retryable: status >= 500, address, method }));
          return;
        }
        if (payload.ok) {
          resolve(payload.result);
          return;
        }
        const code = payload.error?.code ?? 'UNKNOWN';
        const retryable = (status === 503 || status === 504) && code !== 'NODE_DRAINING' && code !== 'DEADLINE_EXCEEDED';
        reject(new SfuControlError(code, payload.error?.message ?? 'rpc failed', { status, retryable, address, method }));
      });
      stream.end(body);
    });
  }

  #runEventStream(address, sub) {
    let stopped = false;
    let stream = null;
    let backoff = 250;

    const open = () => {
      if (stopped || this.#closed) return;
      let buffer = '';
      try {
        stream = this.#session(address).request({ ':method': 'GET', ':path': '/events' });
      } catch (err) {
        schedule(err);
        return;
      }
      stream.setEncoding('utf8');
      stream.on('response', (headers) => {
        if (Number(headers[':status']) === 200) backoff = 250;
      });
      stream.on('data', (chunk) => {
        buffer += chunk;
        let newline;
        while ((newline = buffer.indexOf('\n')) >= 0) {
          const line = buffer.slice(0, newline);
          buffer = buffer.slice(newline + 1);
          if (!line) continue;
          let event;
          try {
            event = JSON.parse(line);
          } catch {
            continue;
          }
          if (event.type === 'ping' || event.type === 'hello') continue;
          for (const listener of sub.listeners) {
            try {
              listener({ ...event, nodeAddress: address });
            } catch (err) {
              this.#logger.warn({ err: { message: err.message } }, 'sfu event listener threw');
            }
          }
        }
      });
      stream.on('error', (err) => schedule(err));
      stream.on('close', () => schedule());
    };

    const schedule = (err) => {
      if (stopped || this.#closed) return;
      stream = null;
      if (err) this.#logger.warn({ address, err: { message: err.message } }, 'sfu event stream interrupted');
      const wait = backoff + Math.random() * backoff;
      backoff = Math.min(backoff * 2, 10_000);
      setTimeout(open, wait).unref();
    };

    open();
    return () => {
      stopped = true;
      stream?.close(http2.constants.NGHTTP2_CANCEL);
    };
  }
}

function parseAddress(address) {
  const match = ADDRESS_PATTERN.exec(address ?? '');
  if (!match) throw new SfuControlError('BAD_ADDRESS', `invalid control address '${address}'`, { status: 500 });
  return [match[1], Number(match[3])];
}

const UNREACHABLE = new Set(['ECONNREFUSED', 'EHOSTUNREACH', 'ETIMEDOUT', 'ENETUNREACH']);

function normalise(err, address, method) {
  if (err instanceof SfuControlError) return err;
  // HTTP/2 reports a failed connect as a cancelled stream; the socket error is in err.cause.
  const rootCode = err?.cause?.code ?? err?.code ?? 'NETWORK';
  const code = UNREACHABLE.has(rootCode) ? 'NODE_UNREACHABLE' : rootCode;
  return new SfuControlError(code, err?.cause?.message ?? err?.message ?? 'network error', {
    status: 503,
    retryable: RETRYABLE_NET.has(rootCode) || RETRYABLE_NET.has(err?.code) || rootCode === 'NETWORK',
    address,
    method,
  });
}