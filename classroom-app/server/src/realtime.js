// server/src/realtime.js
//
// Entrypoint of the realtime service (ECS Fargate, infra/core/ecs-realtime.tf, deployed by
// .github/workflows/deploy-realtime.yml). One process serves every long-lived client connection:
//
//   /socket.io  namespace /classroom   signalling: join, transports, produce/consume, restartIce (F1, F8)
//               namespace /chat        direct messages, public channels, typing, read state (F6)
//               namespace /presence    online · away · in-class (F1, F2, F6)
//   /collab     Yjs websocket for the course builder and the whiteboard (F3, F1)
//   /healthz · /readyz · /startupz     ECS container check · ALB target group · ECS startup grace (F7)
//
// This is the only service allowed to reach SFU control ports (security group + mTLS). The SFU itself is
// never exposed to clients except on its media ports. ICE configuration (TURN addresses + temporary
// credentials) is issued here, inside the room.join acknowledgement, by server/src/rtc/.
//
// Start command (Dockerfile.api image, ECS task definition of the realtime service):
//   node --import ./src/observability/tracing.js ./src/realtime.js
// Tracing is loaded with --import so OpenTelemetry instruments modules before they are imported.
//
// Module contracts this composition root relies on (implemented by the files named):
//   config/env.js                 loadEnv(role) → validated, frozen env for 'realtime' (includes iceEnvSchema);
//                                 fields used here: PORT, RELEASE_SHA, LOG_LEVEL, ALLOWED_ORIGINS (string[]),
//                                 JWT_PUBLIC_KEY, SFU_CONTROL_TLS_CERT/_KEY, SFU_CONTROL_CA,
//                                 REALTIME_DRAIN_WINDOW_MS (default 60000)
//   config/rateLimit.config.js    socketBudgets → per-event budgets for socketRateLimit
//   observability/logger.js       createLogger({ service, release, level }) → pino logger
//   observability/metrics.js      createMetrics({ service, logger }) → { increment, gauge, histogram, flush }
//   db/pool.js                    createPool(env) → pg Pool (primary)
//   db/redis.js                   createRedisClients(env) → { state, cache } ioredis clients, both with quit()
//   lifecycle/readiness.js        createReadiness({ checks, timeoutMs }) → { check(), setDraining(), isDraining() }
//   lifecycle/gracefulShutdown.js createGracefulShutdown({ logger, timeoutMs }) → { register(name, fn), install() }
//   identity/SessionStore.js      new SessionStore({ redis }) — revocation list
//   security/auditLog.js          createAuditLog({ db, logger }) → { record(entry) }
//   signaling/authSocket.js       createSocketAuth({ jwtPublicKey, sessionStore, logger }) → Socket.IO middleware
//                                 with .verifyUpgrade(req) → Promise<user> for the /collab upgrade
//   realtime/redisAdapter.js      createSocketAdapter({ redis }) → adapter for io.adapter()
//   realtime/socketRateLimit.js   createSocketRateLimit({ redis, budgets, metrics }) → (socket) => packet middleware
//   realtime/PresenceService.js   new PresenceService({ redis })
//   realtime/presenceGateway.js   registerPresenceGateway(namespace, { presence, logger, metrics })
//   realtime/collabServer.js      attachCollabServer({ server, path, authenticate, redis, db, logger }) → { close() }
//   messaging/chatGateway.js      registerChatGateway(namespace, { db, redisState, redisCache, presence, audit, logger, metrics })
//   classroom/RoomRegistry.js     new RoomRegistry({ redis }) → { get(), claim(), compareAndSet() } (see RoomPlacementService.js)
//   classroom/RoomPlacementService.js new RoomPlacementService({ redis, roomRegistry, regionHint, regions, policy, logger, metrics })
//   signaling/sfuControlClient.js new SfuControlClient({ tls: { cert, key, ca }, deadlineMs, logger, metrics })
//                                 → { call(), subscribe(), pipeProducer(), close() }
//   signaling/socketHandlers.js   registerSignalingHandlers(namespace, { roomRegistry, placement, sfuControl,
//                                   iceServerService, presence, audit, db, redisState, logger, metrics })
//
// Owner: F1 Live Classrooms + F7 Production and Operations.

import http from 'node:http';
import { Server } from 'socket.io';

import { loadEnv } from './config/env.js';
import { loadIceConfig } from './config/ice.config.js';
import { socketBudgets } from './config/rateLimit.config.js';
import { createLogger } from './observability/logger.js';
import { createMetrics } from './observability/metrics.js';
import { createPool } from './db/pool.js';
import { createRedisClients } from './db/redis.js';
import { createReadiness } from './lifecycle/readiness.js';
import { createGracefulShutdown } from './lifecycle/gracefulShutdown.js';
import { SessionStore } from './identity/SessionStore.js';
import { createAuditLog } from './security/auditLog.js';
import { createSocketAuth } from './signaling/authSocket.js';
import { createSocketAdapter } from './realtime/redisAdapter.js';
import { createSocketRateLimit } from './realtime/socketRateLimit.js';
import { PresenceService } from './realtime/PresenceService.js';
import { registerPresenceGateway } from './realtime/presenceGateway.js';
import { attachCollabServer } from './realtime/collabServer.js';
import { registerChatGateway } from './messaging/chatGateway.js';
import { RoomRegistry } from './classroom/RoomRegistry.js';
import { RoomPlacementService } from './classroom/RoomPlacementService.js';
import { SfuControlClient } from './signaling/sfuControlClient.js';
import { registerSignalingHandlers } from './signaling/socketHandlers.js';

import { TurnSecretRing } from './rtc/TurnSecretRing.js';
import { TurnCredentialIssuer } from './rtc/TurnCredentialIssuer.js';
import { TurnPoolRegistry } from './rtc/TurnPoolRegistry.js';
import { TurnPoolSelector } from './rtc/TurnPoolSelector.js';
import { IcePolicy } from './rtc/IcePolicy.js';
import { RegionHint } from './rtc/RegionHint.js';
import { OpaqueUserId } from './rtc/OpaqueUserId.js';
import { IceServerService } from './rtc/IceServerService.js';

const SERVICE = 'realtime';
const NAMESPACES = Object.freeze({ classroom: '/classroom', chat: '/chat', presence: '/presence' });
const COLLAB_PATH = '/collab';
const SOCKET_PATH = '/socket.io';

async function main() {
  const env = loadEnv(SERVICE);
  const logger = createLogger({ service: SERVICE, release: env.RELEASE_SHA, level: env.LOG_LEVEL });
  const metrics = createMetrics({ service: SERVICE, logger });
  let started = false;

  process.on('unhandledRejection', (reason) => {
    logger.fatal({ err: reason }, 'unhandled promise rejection');
    process.exit(1);
  });
  process.on('uncaughtException', (err) => {
    logger.fatal({ err }, 'uncaught exception');
    process.exit(1);
  });

  // ---------------------------------------------------------------- infrastructure clients
  const pool = createPool(env);
  const { state: redisState, cache: redisCache } = createRedisClients(env);

  // ---------------------------------------------------------------- connectivity domain (F8)
  const iceConfig = loadIceConfig(env);
  const secretRing = await new TurnSecretRing({ ...iceConfig.secretRing, logger }).start();
  const turnRegistry = new TurnPoolRegistry({
    redis: redisState,
    staleAfterMs: iceConfig.registry.staleAfterMs,
    logger,
  });
  const regionHint = new RegionHint({ registry: turnRegistry, enabledRegions: iceConfig.regions });
  const audit = createAuditLog({ db: pool, logger });
  // One policy instance: ICE issuance and room placement must see the same tenant residency rules.
  const icePolicy = new IcePolicy({ db: pool, defaults: iceConfig.policyDefaults, logger });
  const iceServerService = new IceServerService({
    config: iceConfig,
    policy: icePolicy,
    regionHint,
    selector: new TurnPoolSelector({
      registry: turnRegistry,
      fallbacks: iceConfig.fallbacks,
      saturation: iceConfig.selector.saturation,
      spread: iceConfig.selector.spread,
    }),
    issuer: new TurnCredentialIssuer({
      secretRing,
      maxTtlSeconds: iceConfig.policyDefaults.maxTtlSeconds,
      refreshRatio: iceConfig.refreshRatio,
    }),
    opaqueUserId: new OpaqueUserId({ getPepper: iceConfig.getPepper }),
    audit,
    metrics,
    logger,
  });

  // ---------------------------------------------------------------- classroom control plane (F1)
  const roomRegistry = new RoomRegistry({ redis: redisState });
  const placement = new RoomPlacementService({
    redis: redisState,
    roomRegistry,
    regionHint,
    regions: iceConfig.regions,
    policy: icePolicy,
    logger,
    metrics,
  });
  const sfuControl = new SfuControlClient({
    tls: { cert: env.SFU_CONTROL_TLS_CERT, key: env.SFU_CONTROL_TLS_KEY, ca: env.SFU_CONTROL_CA },
    deadlineMs: 2_000,
    logger,
    metrics,
  });
  const presence = new PresenceService({ redis: redisCache });
  const sessionStore = new SessionStore({ redis: redisState });

  // ---------------------------------------------------------------- health
  const readiness = createReadiness({
    timeoutMs: 2_000,
    checks: {
      postgres: () => pool.query('SELECT 1'),
      redisState: () => redisState.ping(),
      redisCache: () => redisCache.ping(),
      turnSecret: () => {
        if (!secretRing.isHealthy()) throw new Error('TURN secret ring stale');
      },
    },
  });

  const httpServer = http.createServer((req, res) => {
    handleHealth(req, res, { readiness, env, isStarted: () => started, logger });
  });
  httpServer.keepAliveTimeout = 75_000; // longer than the ALB idle timeout, so the ALB closes idle connections first
  httpServer.headersTimeout = 76_000;

  // ---------------------------------------------------------------- Socket.IO
  const allowedOrigins = new Set(env.ALLOWED_ORIGINS);
  const io = new Server(httpServer, {
    path: SOCKET_PATH,
    transports: ['websocket'], // no long-polling: sticky sessions are an optimisation, not a requirement
    serveClient: false,
    pingInterval: 25_000,
    pingTimeout: 20_000,
    maxHttpBufferSize: 1_000_000,
    destroyUpgrade: false, // let /collab upgrades reach the Yjs server
    // Cross-site WebSocket hijacking guard. Native apps send no Origin; browsers always do.
    allowRequest: (req, callback) => {
      const origin = req.headers.origin;
      callback(null, !origin || allowedOrigins.has(origin));
    },
  });
  io.adapter(await createSocketAdapter({ redis: redisCache }));

  const authenticate = createSocketAuth({ jwtPublicKey: env.JWT_PUBLIC_KEY, sessionStore, logger });
  const rateLimitFor = createSocketRateLimit({ redis: redisState, budgets: socketBudgets, metrics });

  for (const path of Object.values(NAMESPACES)) {
    const nsp = io.of(path);
    nsp.use(authenticate);
    nsp.on('connection', (socket) => {
      socket.use(rateLimitFor(socket));
      metrics.increment('realtime.connections.opened', { namespace: path });
      socket.once('disconnect', (reason) => {
        metrics.increment('realtime.connections.closed', { namespace: path, reason });
      });
    });
  }

  registerSignalingHandlers(io.of(NAMESPACES.classroom), {
    roomRegistry, placement, sfuControl, iceServerService, presence, audit,
    db: pool, redisState, logger, metrics,
  });
  registerChatGateway(io.of(NAMESPACES.chat), {
    db: pool, redisState, redisCache, presence, audit, logger, metrics,
  });
  registerPresenceGateway(io.of(NAMESPACES.presence), { presence, logger, metrics });

  const collab = attachCollabServer({
    server: httpServer,
    path: COLLAB_PATH,
    authenticate: (req) => authenticate.verifyUpgrade(req),
    redis: redisCache,
    db: pool,
    logger,
  });

  const gaugeTimer = setInterval(() => {
    for (const path of Object.values(NAMESPACES)) {
      metrics.gauge('realtime.connections.active', io.of(path).sockets.size, { namespace: path });
    }
  }, 15_000);
  gaugeTimer.unref();

  // ---------------------------------------------------------------- shutdown
  // ECS sends SIGTERM and allows stopTimeout (max 120 s on Fargate). The ALB deregistration delay runs in
  // parallel, so: fail readiness, spread client reconnects over the window, then close everything.
  const shutdown = createGracefulShutdown({ logger, timeoutMs: 110_000 });
  shutdown.register('readiness', () => readiness.setDraining());
  shutdown.register('sockets', () => disconnectGradually(io, Object.values(NAMESPACES), env.REALTIME_DRAIN_WINDOW_MS ?? 60_000, logger));
  shutdown.register('collab', () => collab.close());
  shutdown.register('socket.io', () => new Promise((resolve) => io.close(() => resolve())));
  shutdown.register('timers', () => clearInterval(gaugeTimer));
  shutdown.register('sfu-control', () => sfuControl.close());
  shutdown.register('turn-secret-ring', () => secretRing.stop());
  shutdown.register('redis', () => Promise.allSettled([redisState.quit(), redisCache.quit()]));
  shutdown.register('postgres', () => pool.end());
  shutdown.register('metrics', () => metrics.flush?.());
  shutdown.install();

  // ---------------------------------------------------------------- listen
  await new Promise((resolve, reject) => {
    httpServer.once('error', reject);
    httpServer.listen(env.PORT, '0.0.0.0', resolve);
  });
  started = true;
  logger.info(
    { port: env.PORT, namespaces: Object.values(NAMESPACES), collab: COLLAB_PATH, regions: iceConfig.regions },
    'realtime service started',
  );
}

/**
 * /healthz  liveness: process up, event loop responsive. No dependency calls.
 * /readyz   readiness: dependencies answer and the service is not draining (ALB target group).
 * /startupz startup: composition finished (ECS startup grace).
 * Every payload carries the release so deploy-realtime.yml can verify a rollout through the ALB.
 */
async function handleHealth(req, res, { readiness, env, isStarted, logger }) {
  const url = req.url?.split('?')[0];
  const base = { service: SERVICE, release: env.RELEASE_SHA };
  const send = (status, body) => {
    res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    res.end(JSON.stringify({ ...base, ...body }));
  };
  if (req.method !== 'GET') return send(405, { status: 'method_not_allowed' });

  switch (url) {
    case '/healthz':
      return send(200, { status: 'ok', uptimeS: Math.round(process.uptime()) });
    case '/startupz':
      return isStarted() ? send(200, { status: 'started' }) : send(503, { status: 'starting' });
    case '/readyz': {
      if (!isStarted()) return send(503, { status: 'starting' });
      if (readiness.isDraining()) return send(503, { status: 'draining' });
      try {
        const result = await readiness.check();
        return send(result.ok ? 200 : 503, { status: result.ok ? 'ready' : 'degraded', checks: result.checks });
      } catch (err) {
        logger.warn({ err }, 'readiness check failed');
        return send(503, { status: 'degraded' });
      }
    }
    default:
      return send(404, { status: 'not_found' });
  }
}

/**
 * Disconnects this task's sockets in batches across `windowMs`, so tens of thousands of clients do not
 * reconnect to the remaining tasks in the same second. Clients receive 'server:draining' first; their
 * socketClient reconnects with backoff and the outbox replays unsent messages.
 */
async function disconnectGradually(io, namespaces, windowMs, logger) {
  const sockets = namespaces.flatMap((path) => [...io.of(path).sockets.values()]);
  if (sockets.length === 0) return;
  for (const socket of sockets) socket.emit('server:draining', { reconnectWithinMs: windowMs });

  const batches = Math.max(1, Math.min(20, sockets.length));
  const batchSize = Math.ceil(sockets.length / batches);
  const pause = Math.floor(windowMs / batches);
  logger.info({ sockets: sockets.length, batches, windowMs }, 'draining realtime connections');

  for (let i = 0; i < sockets.length; i += batchSize) {
    for (const socket of sockets.slice(i, i + batchSize)) socket.disconnect(true);
    if (i + batchSize < sockets.length) await new Promise((resolve) => setTimeout(resolve, pause));
  }
}

main().catch((err) => {
  // Logger may not exist yet: config errors must still be visible in CloudWatch.
  console.error(JSON.stringify({ level: 'fatal', service: SERVICE, msg: 'realtime failed to start', err: String(err?.stack ?? err) }));
  process.exit(1);
});