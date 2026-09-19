// turn/agent/src/main.js
//
// Entry point of the TURN agent sidecar (container "turn-agent" of the TURN task; started by
// bootstrap/entrypoint.sh agent, bundled to /opt/turn-agent/agent.mjs by `npm run build`).
// Wires the parts together:
//
//   selfProbe      proves STUN/TURN over UDP and TLS every 10 s            → health, registry gate
//   metricsBridge  allocations + relayed Mbit/s every 5 s, EMF every 60 s   → heartbeat load, drain, autoscaling
//   heartbeat      publishes the node in the TURN registry every 5 s       → server/src/rtc/TurnPoolRegistry.js
//   drain          flag / HTTP triggered, waits for allocations, completes the lifecycle hook
//   healthServer   /healthz, /drain, /drain/status
//
// Environment:
//   TURN_NODE_FILE            node.json written by the coturn container's bootstrap
//   TURN_PROBE_SECRET_FILE    current signing secret (runtime volume)
//   TURN_TLS_DIR              for the development CA (self-signed) only
//   TURN_ENV                  production | staging | development
//   REDIS_STATE_URL           rediss://… of the state cluster (via Transit Gateway from media regions)
//   REDIS_CLUSTER             true when the state cluster runs in cluster mode
//   TURN_AGENT_PORT           8080
//   TURN_PROBE_PEER_IP        public IPv4 used for the permission test (default 1.1.1.1; no traffic is sent)
//   TURN_DRAIN_TIMEOUT_MS     14400000 (4 h)
//   RELEASE_SHA               published as "version" in the registry
//
// Owner: F8 Real-Time Connectivity.

import { readFile } from 'node:fs/promises';
import { Redis, Cluster } from 'ioredis';
import { SelfProbe } from './selfProbe.js';
import { MetricsBridge } from './metricsBridge.js';
import { TurnHeartbeat } from './heartbeat.js';
import { DrainController } from './drain.js';
import { createHealthServer } from './healthServer.js';

const env = process.env;

function createLogger(base) {
  const write = (level) => (fields, msg) => {
    const entry = typeof fields === 'string' ? { msg: fields } : { ...fields, msg };
    process.stdout.write(`${JSON.stringify({ level, service: 'turn-agent', ...base, ...entry, time: new Date().toISOString() })}\n`);
  };
  return { info: write('info'), warn: write('warn'), error: write('error'), fatal: write('fatal') };
}

function createRedis(url, cluster) {
  const parsed = new URL(url);
  const tls = parsed.protocol === 'rediss:' ? {} : undefined;
  const auth = { username: decodeURIComponent(parsed.username) || undefined, password: decodeURIComponent(parsed.password) || undefined };
  if (cluster) {
    return new Cluster([{ host: parsed.hostname, port: Number(parsed.port || 6379) }], {
      dnsLookup: (address, callback) => callback(null, address), // required for ElastiCache TLS cluster endpoints
      redisOptions: { tls, ...auth },
      slotsRefreshTimeout: 2_000,
    });
  }
  return new Redis(url, { tls, maxRetriesPerRequest: 2, enableAutoPipelining: true });
}

async function main() {
  process.stdout.on('error', () => {});
  const node = JSON.parse(await readFile(env.TURN_NODE_FILE ?? '/run/turn/node.json', 'utf8'));
  const logger = createLogger({ node: node.node, region: node.region });

  if (!env.REDIS_STATE_URL) throw new Error('REDIS_STATE_URL is required');
  const redis = createRedis(env.REDIS_STATE_URL, env.REDIS_CLUSTER === 'true');
  redis.on('error', (err) => logger.warn({ err: { message: err.message } }, 'redis error'));

  const probe = new SelfProbe({
    node,
    secretFile: env.TURN_PROBE_SECRET_FILE ?? '/run/turn/secrets/current',
    peerIp: env.TURN_PROBE_PEER_IP ?? '1.1.1.1',
    caFile: env.TURN_ENV === 'development' ? `${env.TURN_TLS_DIR ?? '/run/turn/tls'}/fullchain.pem` : undefined,
    logger,
  });

  let drain;
  const metrics = new MetricsBridge({
    node,
    getStatus: () => ({
      probeOk: probe.isHealthy(),
      probeRttMs: probe.state.results.length ? Math.max(...probe.state.results.map((r) => r.rttMs)) : null,
      draining: drain?.isDraining() ?? false,
    }),
    logger,
  });

  const heartbeat = new TurnHeartbeat({
    redis,
    node,
    getLoad: () => metrics.latest(),
    isHealthy: () => probe.isHealthy() && metrics.latest().scrapedAt > 0,
    isDraining: () => drain.isDraining(),
    version: env.RELEASE_SHA,
    logger,
  });

  drain = new DrainController({
    redis,
    node,
    heartbeat,
    getAllocations: () => metrics.latest().allocations,
    timeoutMs: Number(env.TURN_DRAIN_TIMEOUT_MS ?? 4 * 3_600_000),
    logger,
  });

  const health = createHealthServer({
    port: Number(env.TURN_AGENT_PORT ?? 8080),
    drain,
    getHealth: () => ({
      healthy: probe.isHealthy(),
      details: {
        node: node.node,
        probe: { ok: probe.state.ok, at: probe.state.at, error: probe.state.error, failures: probe.state.consecutiveFailures },
        registry: { published: heartbeat.published, error: heartbeat.lastError },
        draining: drain.isDraining(),
        allocations: metrics.latest().allocations,
        release: env.RELEASE_SHA ?? null,
      },
    }),
    logger,
  });

  await health.listen();
  metrics.start();
  await metrics.scrapeOnce().catch(() => {});
  probe.start();
  heartbeat.start();
  drain.watchFlag();
  logger.info({ hostname: node.hostname, publicIpv4: node.publicIpv4 }, 'turn agent started');

  let stopping = false;
  const shutdown = async (signal) => {
    if (stopping) return;
    stopping = true;
    logger.info({ signal }, 'turn agent stopping');
    probe.stop();
    drain.stop();
    metrics.stop();
    await heartbeat.stop().catch(() => {}); // leave the registry before coturn goes away
    await health.close();
    await redis.quit().catch(() => {});
    process.exit(0);
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

main().catch((err) => {
  process.stdout.write(`${JSON.stringify({ level: 'fatal', service: 'turn-agent', msg: 'agent failed to start', err: String(err?.stack ?? err) })}\n`);
  process.exit(1);
});