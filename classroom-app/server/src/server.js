/**
 * server/src/server.js
 *
 * API entrypoint — SERVICE_ROLE=api.  (F7)
 *
 * Responsibilities:
 *   - boot order: tracing -> config -> secrets -> data clients -> HTTP listen
 *   - HTTP only. No Socket.IO, no mediasoup, no BullMQ workers in this process.
 *     Signalling/chat/presence/Yjs live in realtime.js, media in sfu.js,
 *     queue consumers in worker.js.
 *   - ALB-safe keep-alive timings.
 *   - deterministic shutdown hooks: stop taking traffic, drain in-flight
 *     requests, then close pools.
 *
 * Node.js 22, ESM ("type": "module").
 *
 * Expected interfaces from sibling modules:
 *   ./config/env.js          -> { env }                      (zod-validated, role aware)
 *   ./config/secrets.js      -> loadSecrets(role)             (Secrets Manager loader)
 *   ./app.js                 -> createApp()                   (Express app, no listen)
 *   ./lifecycle/readiness.js -> { readiness }                 (setStarted/setReady/setDraining/check)
 *   ./lifecycle/gracefulShutdown.js -> registerGracefulShutdown({...})
 */

import http from 'node:http';
import process from 'node:process';

import { env } from './config/env.js';
import { loadSecrets } from './config/secrets.js';
import { createApp } from './app.js';
import { pool } from './db/pool.js';
import { stateRedis, cacheRedis } from './db/redis.js';
import { readiness } from './lifecycle/readiness.js';
import { registerGracefulShutdown } from './lifecycle/gracefulShutdown.js';
import { logger } from './observability/logger.js';
import { startTracing, shutdownTracing } from './observability/tracing.js';

const log = logger.child({ component: 'server' });

/* -------------------------------------------------------------------------- */
/* Role guard                                                                  */
/* -------------------------------------------------------------------------- */

if (env.SERVICE_ROLE !== 'api') {
  log.fatal(
    { serviceRole: env.SERVICE_ROLE },
    'server.js is the api entrypoint; use realtime.js, sfu.js or worker.js for other roles',
  );
  process.exit(1);
}

/* -------------------------------------------------------------------------- */
/* Timings                                                                     */
/* -------------------------------------------------------------------------- */

/**
 * The ALB idle timeout is 60 s. Node must keep a connection alive *longer*
 * than the balancer does, otherwise the balancer can hand a request to a
 * socket the server is closing at that exact moment -> sporadic 502s.
 */
const KEEP_ALIVE_TIMEOUT_MS = 65_000;
const HEADERS_TIMEOUT_MS = 70_000; // must be > keepAliveTimeout
const REQUEST_TIMEOUT_MS = 30_000; // hard cap for a single request
const SHUTDOWN_TIMEOUT_MS = 25_000; // < ECS stopTimeout (30 s)

/* -------------------------------------------------------------------------- */
/* Boot                                                                        */
/* -------------------------------------------------------------------------- */

let server = /** @type {http.Server | undefined} */ (undefined);

async function main() {
  const startedAt = Date.now();

  // 1. Tracing first, so that boot itself is observable.
  await startTracing({
    serviceName: env.SERVICE_NAME,
    endpoint: env.OTEL_EXPORTER_OTLP_ENDPOINT,
    release: env.RELEASE_SHA,
  });

  log.info(
    {
      nodeVersion: process.version,
      release: env.RELEASE_SHA,
      nodeEnv: env.NODE_ENV,
      pid: process.pid,
    },
    'api boot',
  );

  // 2. Secrets. env.js has already validated every plain variable; this
  //    resolves the Secrets Manager references for the api role (JWT key pair,
  //    cookie secret, CDN signing key, Stripe, TURN secret ring, ICE pepper).
  await loadSecrets('api');

  // 3. Data clients. Connecting here (not lazily on first request) means a
  //    broken database or cache fails the startup probe instead of the first
  //    user request.
  await pool.connect().then((client) => client.release());
  await Promise.all([stateRedis.ping(), cacheRedis.ping()]);

  readiness.setStarted(); // GET /startupz turns green

  // 4. HTTP.
  const app = createApp();
  server = http.createServer(app);

  server.keepAliveTimeout = KEEP_ALIVE_TIMEOUT_MS;
  server.headersTimeout = HEADERS_TIMEOUT_MS;
  server.requestTimeout = REQUEST_TIMEOUT_MS;
  server.maxHeadersCount = 100;

  server.on('clientError', (err, socket) => {
    if (!socket.writable || socket.destroyed) return;
    log.debug({ err: err.code }, 'client error');
    socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
  });

  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(env.PORT, '0.0.0.0', () => {
      server.removeListener('error', reject);
      resolve();
    });
  });

  readiness.setReady(); // GET /readyz turns green -> ALB starts routing

  log.info(
    { port: env.PORT, bootMs: Date.now() - startedAt },
    'api listening',
  );
}

/* -------------------------------------------------------------------------- */
/* Shutdown hooks                                                              */
/* -------------------------------------------------------------------------- */

/**
 * SIGTERM arrives from ECS the moment the task is deregistered. The sequence
 * has to be: fail readiness first (so the ALB stops sending new requests),
 * wait one health-check interval, then close the listener and drain.
 */
registerGracefulShutdown({
  logger: log,
  timeoutMs: SHUTDOWN_TIMEOUT_MS,

  // Phase 1 — become unroutable while still serving in-flight traffic.
  beforeDrain: async () => {
    readiness.setDraining();
    await sleep(env.SHUTDOWN_PRE_DRAIN_MS ?? 5_000);
  },

  // Phase 2 — stop accepting, let open requests finish.
  drain: async () => {
    if (!server?.listening) return;
    await new Promise((resolve) => server.close(resolve));
    server.closeIdleConnections?.();
  },

  // Phase 3 — release resources. Order matters: queues/clients before the
  // exporter, so that shutdown itself is still traced.
  close: async () => {
    await Promise.allSettled([
      pool.end(),
      stateRedis.quit(),
      cacheRedis.quit(),
    ]);
    await shutdownTracing();
  },

  // Phase 4 — last resort if something refuses to settle.
  onTimeout: () => {
    log.error('graceful shutdown timed out, forcing exit');
    server?.closeAllConnections?.();
  },
});

/* -------------------------------------------------------------------------- */
/* Process-level safety net                                                    */
/* -------------------------------------------------------------------------- */

process.on('unhandledRejection', (reason) => {
  log.error({ err: reason }, 'unhandled rejection');
});

process.on('uncaughtException', (err) => {
  // An uncaught exception leaves the process in an undefined state. Log it,
  // fail readiness so the balancer drains us, and let ECS replace the task.
  log.fatal({ err }, 'uncaught exception, shutting down');
  readiness.setDraining();
  setTimeout(() => process.exit(1), 1_000).unref();
});

process.on('warning', (warning) => {
  log.warn({ name: warning.name, message: warning.message }, 'process warning');
});

/* -------------------------------------------------------------------------- */

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms).unref());
}

main().catch((err) => {
  log.fatal({ err }, 'api failed to start');
  process.exit(1);
});