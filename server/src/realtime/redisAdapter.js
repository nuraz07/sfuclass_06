/**
 * server/src/realtime/redisAdapter.js
 *
 * Socket.IO adapter for cluster-mode ElastiCache.  (F2, F6, F7)
 *
 * v6 -> v7 correction: v6 used the classic @socket.io/redis-adapter on a
 * cluster-mode cluster. That adapter broadcasts over a handful of fixed
 * channels with PUBLISH/SUBSCRIBE; in cluster mode every such message is
 * fanned out to *every* shard, so throughput does not scale with the cluster
 * and cross-slot behaviour is undefined for some commands.
 *
 * v7 uses the sharded adapter (SPUBLISH/SSUBSCRIBE, Redis >= 7): each room
 * gets its own shard channel, hashed to one slot, so a message only touches
 * the shard that owns that room.
 *
 * Which cluster: the *cache* cluster (volatile-lru). Pub/Sub carries no
 * durable state — a lost message is a missed live event, not a lost job. The
 * state cluster (noeviction) stays reserved for BullMQ, seat reservations,
 * registries, rate limits and session revocation.
 *
 * Used by realtime.js only.
 *
 * Node.js 22, ESM.
 */

import { createShardedAdapter } from '@socket.io/redis-adapter';

import { env } from '../config/env.js';
import { cacheRedis } from '../db/redis.js';
import { logger } from '../observability/logger.js';
import { metrics } from '../observability/metrics.js';

const log = logger.child({ component: 'redis-adapter' });

/**
 * Sharded Pub/Sub needs its own connections: a connection in subscriber mode
 * cannot run normal commands. We duplicate the configured cache client so TLS,
 * auth, cluster topology and retry strategy are inherited rather than
 * re-declared.
 */
let pubClient = null;
let subClient = null;

/**
 * @param {object} [opts]
 * @param {string} [opts.prefix] channel prefix; keep stable across a release
 *   or in-flight messages are dropped during a rolling deploy.
 * @returns {import('socket.io').AdapterConstructor}
 */
export function createSocketAdapter({ prefix = channelPrefix() } = {}) {
  if (!pubClient) {
    pubClient = cacheRedis.duplicate({ lazyConnect: false });
    subClient = cacheRedis.duplicate({ lazyConnect: false });
    instrument('pub', pubClient);
    instrument('sub', subClient);
  }

  log.info(
    { prefix, clusterMode: env.REDIS_CLUSTER_MODE !== false },
    'socket.io sharded adapter created',
  );

  return createShardedAdapter(pubClient, subClient, {
    /**
     * 'dynamic-private' subscribes to a room's channel only while this task
     * actually holds a member of that room, and never for private (socket id)
     * channels. With one channel per space, per conversation and per
     * classroom, a static mode would have every task subscribed to everything
     * — exactly the fan-out we are removing.
     */
    subscriptionMode: 'dynamic-private',
    channelPrefix: prefix,
  });
}

/**
 * Readiness probe input for /readyz on the realtime service: a broadcast path
 * that cannot publish is worse than a task that reports itself unhealthy.
 */
export async function ping() {
  if (!pubClient) return false;
  try {
    const started = process.hrtime.bigint();
    await pubClient.ping();
    metrics.gauge(
      'realtime.adapter.ping_ms',
      Number(process.hrtime.bigint() - started) / 1e6,
    );
    return true;
  } catch (err) {
    log.error({ err }, 'adapter ping failed');
    return false;
  }
}

/** Called from realtime.js during graceful shutdown, after io.close(). */
export async function closeAdapter() {
  const clients = [pubClient, subClient].filter(Boolean);
  pubClient = null;
  subClient = null;
  await Promise.allSettled(clients.map((c) => c.quit()));
  log.info('adapter connections closed');
}

/* -------------------------------------------------------------------------- */

/**
 * Prefix is environment- and *contract*-scoped, not release-scoped: two
 * releases running side by side during a rolling deploy must still see each
 * other's broadcasts, otherwise half the users in a room stop receiving
 * messages for the duration of the deploy.
 */
function channelPrefix() {
  const base = env.REDIS_PREFIX ? `${env.REDIS_PREFIX}:` : '';
  return `${base}socket.io`;
}

function instrument(role, client) {
  client.on('error', (err) => {
    // ioredis retries on its own; log at warn so a brief failover does not
    // page anyone, and let the ping() probe decide readiness.
    log.warn({ err, role }, 'adapter redis error');
    metrics.increment('realtime.adapter.error', { role });
  });
  client.on('reconnecting', () => metrics.increment('realtime.adapter.reconnect', { role }));
  client.on('end', () => log.info({ role }, 'adapter connection ended'));
}

export default createSocketAdapter;