// server/src/sfu.js
//
// Entrypoint of one SFU node (ECS on EC2, host networking, one task per instance, public media subnet;
// infra/modules/sfu-node-pool, deployed per media region by .github/workflows/deploy-sfu.yml).
//
// What this process knows about the network — and nothing more:
//   - its own public address (Elastic IP via IMDSv2, config/publicAddress.js), announced in ICE candidates;
//   - one UDP + one TCP port per mediasoup worker (WebRtcServer, MEDIASOUP_RTC_PORT_BASE + index);
//   - a private control port (mTLS) that only the realtime service can reach;
//   - a private pipe-transport port range for cascading rooms across nodes of the same region.
// The SFU is ICE-lite. It never contacts STUN or TURN and holds no TURN configuration or secret:
// clients receive TURN addresses and credentials from the API (server/src/rtc/). A relayed client simply
// appears as a remote candidate with a TURN node's IP.
//
// Lifecycle:
//   boot       resolve public address → start workers + WebRtcServers → start control server →
//              register in the SFU node registry (heartbeat 5 s, TTL 15 s) → ready.
//   drain      the node-lifecycle Lambda (ASG terminate hook) or an operator sets media:drain:<nodeId>;
//              lifecycle/drainSfu.js stops new room placement, waits until rooms are empty (or the drain
//              timeout), then completes the lifecycle hook so the instance terminates.
//   SIGTERM    last resort (drain already done, or forced): leave the registry, close rooms so clients'
//              IceRecovery rejoins elsewhere, close workers, exit within the ECS stop timeout.
//
// Start command (Dockerfile.sfu):
//   node --import ./src/observability/tracing.js ./src/sfu.js
//
// Module contracts this composition root relies on:
//   config/env.js                  loadEnv('sfu') — fields used: RELEASE_SHA, LOG_LEVEL, MEDIA_REGION,
//                                  MEDIASOUP_WORKERS, MEDIASOUP_RTC_PORT_BASE, MEDIASOUP_PIPE_PORT_MIN/_MAX,
//                                  MEDIA_PUBLIC_ADDRESS_SOURCE, MEDIA_PUBLIC_IPV4 (dev), SFU_CONTROL_PORT,
//                                  SFU_CONTROL_TLS_CERT/_KEY, SFU_CONTROL_CA, SFU_MAX_LOAD_SCORE,
//                                  SFU_DRAIN_TIMEOUT_MS, SFU_SIGTERM_GRACE_MS
//   config/publicAddress.js        resolvePublicAddress({ source, staticIpv4, logger })
//                                  → { instanceId, availabilityZone, privateIp, publicIpv4, publicIpv6? }
//   config/mediasoup.config.js     buildMediasoupConfig(env) → { workerSettings, routerMediaCodecs, webRtcTransport }
//   mediasoup/WebRtcServerFactory.js new WebRtcServerFactory({ listenIp, announcedIpv4, announcedIpv6, portBase, logger })
//                                  → { create(worker, index) → Promise<WebRtcServer>, portsFor(index) }
//   mediasoup/WorkerManager.js     new WorkerManager({ count, workerSettings, createWebRtcServer, logger, metrics })
//                                  → EventEmitter { start(), workers() → [{ index, worker, webRtcServer }],
//                                    events 'workerStarted' ({ index, worker }) and 'fatal', close() }
//   mediasoup/health.js            createSfuHealth({ workerManager, publicAddress, loadReporter, maxLoadScore })
//                                  → { check() → { ok, details } }
//   mediasoup/pipe/pipeTransportFactory.js new PipeTransportFactory({ listenIp, portMin, portMax })
//   mediasoup/pipe/RouterPipeManager.js    new RouterPipeManager({ pipeTransportFactory, logger })
//   classroom/RoomManager.js       new RoomManager({ workerManager, mediasoupConfig, pipeManager, logger, metrics })
//                                  → { getRoom(), getOrCreateRoom(), closeRoom(), roomCount(), closeAll({ reason }) }
//                                  (full contract: header of sfu-node/rpcHandlers.js)
//   sfu-node/loadReporter.js       new LoadReporter({ workerManager, roomManager, metrics }) → { snapshot() }
//   sfu-node/NodeRegistrar.js      new NodeRegistrar({ redis, node, loadReporter, intervalMs, logger })
//                                  → { start(), setDraining(bool), stop() }
//   sfu-node/rpcHandlers.js        createRpcHandlers({ roomManager, pipeManager, isAccepting, webRtcTransportOptions,
//                                  logger, metrics }) → { methods, events }
//   sfu-node/controlServer.js      createControlServer({ host, port, tls, handlers, healthCheck, logger })
//                                  → { listen(), close() }   (/healthz/sfu is served on the same port)
//   lifecycle/drainSfu.js          startDrainWatcher({ redis, nodeId, instanceId, registrar, roomManager,
//                                  timeoutMs, logger }) → { stop() }
//   lifecycle/gracefulShutdown.js  createGracefulShutdown({ logger, timeoutMs }) → { register(), install() }
//   db/redis.js                    createRedisClients(env) → { state } (the sfu role has no cache cluster)
//
// Owner: F1 Live Classrooms (+ F8 for addressing).

import { loadEnv } from './config/env.js';
import { resolvePublicAddress } from './config/publicAddress.js';
import { buildMediasoupConfig } from './config/mediasoup.config.js';
import { createLogger } from './observability/logger.js';
import { createMetrics } from './observability/metrics.js';
import { createRedisClients } from './db/redis.js';
import { createGracefulShutdown } from './lifecycle/gracefulShutdown.js';
import { startDrainWatcher } from './lifecycle/drainSfu.js';
import { WorkerManager } from './mediasoup/WorkerManager.js';
import { WebRtcServerFactory } from './mediasoup/WebRtcServerFactory.js';
import { createSfuHealth } from './mediasoup/health.js';
import { PipeTransportFactory } from './mediasoup/pipe/pipeTransportFactory.js';
import { RouterPipeManager } from './mediasoup/pipe/RouterPipeManager.js';
import { RoomManager } from './classroom/RoomManager.js';
import { LoadReporter } from './sfu-node/loadReporter.js';
import { NodeRegistrar } from './sfu-node/NodeRegistrar.js';
import { createRpcHandlers } from './sfu-node/rpcHandlers.js';
import { createControlServer } from './sfu-node/controlServer.js';

const SERVICE = 'sfu';

async function main() {
  const env = loadEnv(SERVICE);
  const logger = createLogger({ service: SERVICE, release: env.RELEASE_SHA, level: env.LOG_LEVEL });
  const metrics = createMetrics({ service: SERVICE, logger });

  process.on('unhandledRejection', (reason) => {
    logger.fatal({ err: reason }, 'unhandled promise rejection');
    process.exit(1);
  });
  process.on('uncaughtException', (err) => {
    logger.fatal({ err }, 'uncaught exception');
    process.exit(1);
  });

  // ---------------------------------------------------------------- network identity
  // Fails fast: an SFU that cannot announce a reachable address must never register.
  const address = await resolvePublicAddress({
    source: env.MEDIA_PUBLIC_ADDRESS_SOURCE, // 'imds' in AWS, 'static' in docker-compose.dev.yml
    staticIpv4: env.MEDIA_PUBLIC_IPV4,
    logger,
  });
  const nodeId = `sfu-${env.MEDIA_REGION}-${address.instanceId}`;
  const log = logger.child({ nodeId, region: env.MEDIA_REGION, az: address.availabilityZone });
  log.info(
    { privateIp: address.privateIp, publicIpv4: address.publicIpv4, publicIpv6: address.publicIpv6 ?? null },
    'resolved node addresses',
  );

  // ---------------------------------------------------------------- media engine
  const mediasoupConfig = buildMediasoupConfig(env);
  const webRtcServers = new WebRtcServerFactory({
    listenIp: address.privateIp, // host networking; AWS maps the EIP 1:1 onto this address
    announcedIpv4: address.publicIpv4,
    announcedIpv6: address.publicIpv6,
    portBase: env.MEDIASOUP_RTC_PORT_BASE,
    logger: log,
  });
  const workerManager = new WorkerManager({
    count: env.MEDIASOUP_WORKERS,
    workerSettings: mediasoupConfig.workerSettings,
    createWebRtcServer: (worker, index) => webRtcServers.create(worker, index),
    logger: log,
    metrics,
  });
  workerManager.on('fatal', (err) => {
    // Repeated worker crashes: let ECS replace the whole task rather than limp along.
    log.fatal({ err }, 'mediasoup worker manager gave up');
    process.exit(1);
  });
  await workerManager.start();

  const pipeManager = new RouterPipeManager({
    pipeTransportFactory: new PipeTransportFactory({
      listenIp: address.privateIp, // cascading stays on private IPs inside the region
      portMin: env.MEDIASOUP_PIPE_PORT_MIN,
      portMax: env.MEDIASOUP_PIPE_PORT_MAX,
    }),
    logger: log,
  });
  const roomManager = new RoomManager({ workerManager, mediasoupConfig, pipeManager, logger: log, metrics });
  const loadReporter = new LoadReporter({ workerManager, roomManager, metrics });

  // ---------------------------------------------------------------- control plane
  const { state: redisState } = createRedisClients(env);

  const registrar = new NodeRegistrar({
    redis: redisState,
    node: {
      nodeId,
      region: env.MEDIA_REGION,
      az: address.availabilityZone,
      publicIpv4: address.publicIpv4,
      publicIpv6: address.publicIpv6,
      rtcPorts: Array.from({ length: env.MEDIASOUP_WORKERS }, (_, i) => webRtcServers.portsFor(i)),
      controlAddress: `${address.privateIp}:${env.SFU_CONTROL_PORT}`,
      release: env.RELEASE_SHA,
    },
    loadReporter,
    intervalMs: 5_000,
    logger: log,
  });

  let accepting = true;
  const health = createSfuHealth({
    workerManager,
    publicAddress: address,
    loadReporter,
    maxLoadScore: env.SFU_MAX_LOAD_SCORE,
  });
  const controlServer = createControlServer({
    host: address.privateIp,
    port: env.SFU_CONTROL_PORT,
    tls: { cert: env.SFU_CONTROL_TLS_CERT, key: env.SFU_CONTROL_TLS_KEY, ca: env.SFU_CONTROL_CA },
    handlers: createRpcHandlers({
      roomManager,
      pipeManager,
      isAccepting: () => accepting,
      webRtcTransportOptions: mediasoupConfig.webRtcTransport,
      logger: log,
      metrics,
    }),
    healthCheck: () => health.check(),
    logger: log,
  });
  await controlServer.listen();

  // Register only after the control server answers: placement may send a room here immediately.
  await registrar.start();

  const drainWatcher = startDrainWatcher({
    redis: redisState,
    nodeId,
    instanceId: address.instanceId,
    registrar,
    roomManager,
    timeoutMs: env.SFU_DRAIN_TIMEOUT_MS,
    logger: log,
  });

  // ---------------------------------------------------------------- shutdown (last resort)
  const graceMs = env.SFU_SIGTERM_GRACE_MS ?? 25_000;
  const shutdown = createGracefulShutdown({ logger: log, timeoutMs: graceMs + 20_000 });
  shutdown.register('stop-accepting', async () => {
    accepting = false;
    await registrar.setDraining(true);
  });
  shutdown.register('drain-watcher', () => drainWatcher.stop());
  shutdown.register('rooms', async () => {
    const deadline = Date.now() + graceMs;
    while (roomManager.roomCount() > 0 && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 1_000));
    }
    if (roomManager.roomCount() > 0) {
      log.warn({ rooms: roomManager.roomCount() }, 'closing remaining rooms on shutdown; clients will rejoin');
      await roomManager.closeAll({ reason: 'node-shutdown' });
    }
  });
  shutdown.register('registry', () => registrar.stop());
  shutdown.register('control-server', () => controlServer.close());
  shutdown.register('workers', () => workerManager.close());
  shutdown.register('redis', () => redisState.quit());
  shutdown.register('metrics', () => metrics.flush?.());
  shutdown.install();

  log.info(
    {
      workers: env.MEDIASOUP_WORKERS,
      rtcPorts: `${env.MEDIASOUP_RTC_PORT_BASE}-${env.MEDIASOUP_RTC_PORT_BASE + env.MEDIASOUP_WORKERS - 1} udp+tcp`,
      controlPort: env.SFU_CONTROL_PORT,
    },
    'sfu node started',
  );
}

main().catch((err) => {
  console.error(JSON.stringify({ level: 'fatal', service: SERVICE, msg: 'sfu failed to start', err: String(err?.stack ?? err) }));
  process.exit(1);
});