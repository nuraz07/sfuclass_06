/**
 * server/src/db/redis.js
 *
 * Two Redis clients, two purposes, two eviction policies.  (F7)
 *
 * v6 -> v7 correction: v6 had one cluster for BullMQ, the seat-reservation Lua
 * script and every cache, with an eviction alarm on top. BullMQ jobs and seat
 * reservations are state: if the cluster evicts, a job or a paid seat silently
 * disappears. Caches, on the other hand, *must* be allowed to evict or they
 * fill up and take the cluster down.
 *
 *   state (maxmemory-policy=noeviction)
 *     BullMQ, capacity/reserveSeat.lua, room registry, SFU + TURN node
 *     registries, drain flags, rate limits, session revocation list,
 *     recording session state.
 *
 *   cache (maxmemory-policy=volatile-lru)
 *     entitlements, presence, unread counters, Socket.IO sharded Pub/Sub,
 *     short-lived lookups. Every key written here gets a TTL — under
 *     volatile-lru a key without one is never evictable, which recreates the
 *     v6 problem inside the cache cluster.
 *
 * Both clusters run with TLS and automatic failover (data.tf).
 *
 * Node.js 22, ESM.
 */

import Redis, { Cluster } from 'ioredis';

import { env } from '../config/env.js';
import { logger } from '../observability/logger.js';
import { metrics } from '../observability/metrics.js';

const log = logger.child({ component: 'redis' });

/* -------------------------------------------------------------------------- */
/* Factory                                                                     */
/* -------------------------------------------------------------------------- */

/**
 * @param {object} args
 * @param {'state'|'cache'} args.role
 * @param {string} args.url
 * @param {boolean} [args.enableReadyCheck]
 * @returns {Redis|Cluster}
 */
function createClient({ role, url }) {
  const tls = env.REDIS_TLS ? { tls: {} } : {};

  const common = {
    ...tls,
    keyPrefix: env.REDIS_PREFIX ? `${env.REDIS_PREFIX}:${role}:` : `${role}:`,
    // BullMQ requires this to be null: it uses blocking commands (BRPOPLPUSH)
    // whose duration must not count as a failed request.
    maxRetriesPerRequest: role === 'state' ? null : 3,
    enableReadyCheck: true,
    enableOfflineQueue: role === 'state', // state: queue and retry; cache: fail fast
    connectTimeout: 10_000,
    commandTimeout: role === 'cache' ? 1_000 : undefined,
    retryStrategy: (attempt) => Math.min(attempt * 200, 5_000),
    reconnectOnError(err) {
      // ElastiCache failover surfaces as READONLY on the old primary.
      return err.message.includes('READONLY');
    },
  };

  const client = env.REDIS_CLUSTER_MODE
    ? new Cluster([parseNode(url)], {
        redisOptions: common,
        // Reads go to the primary: a replica lagging behind on a seat
        // reservation or a drain flag is a correctness bug, not a latency win.
        scaleReads: 'master',
        slotsRefreshTimeout: 5_000,
        clusterRetryStrategy: (attempt) => Math.min(attempt * 200, 5_000),
        enableOfflineQueue: common.enableOfflineQueue,
      })
    : new Redis(url, common);

  instrument(role, client);
  return client;
}

function parseNode(url) {
  const parsed = new URL(url);
  return { host: parsed.hostname, port: Number(parsed.port || 6379) };
}

function instrument(role, client) {
  client.on('connect', () => log.info({ role }, 'redis connecting'));
  client.on('ready', () => log.info({ role }, 'redis ready'));
  client.on('error', (err) => {
    log.warn({ err, role }, 'redis error');
    metrics.increment('redis.error', { role });
  });
  client.on('reconnecting', (delay) => {
    log.warn({ role, delay }, 'redis reconnecting');
    metrics.increment('redis.reconnect', { role });
  });
  client.on('end', () => log.info({ role }, 'redis connection closed'));
  if (client instanceof Cluster) {
    client.on('node error', (err, address) =>
      log.warn({ err, role, address }, 'redis cluster node error'),
    );
  }
}

/* -------------------------------------------------------------------------- */
/* Clients                                                                     */
/* -------------------------------------------------------------------------- */

/** Durable, must never evict. */
export const stateRedis = createClient({ role: 'state', url: env.REDIS_STATE_URL });

/**
 * The sfu role receives REDIS_STATE_URL only (registries, drain flags,
 * recording session state) and has no cache client — see §9 of the
 * architecture. Guard against importing it there by accident.
 */
export const cacheRedis = env.REDIS_CACHE_URL
  ? createClient({ role: 'cache', url: env.REDIS_CACHE_URL })
  : new Proxy(
      {},
      {
        get(_t, prop) {
          throw new Error(
            `cacheRedis is not configured for SERVICE_ROLE=${env.SERVICE_ROLE} ` +
              `(attempted "${String(prop)}"); use stateRedis or add REDIS_CACHE_URL`,
          );
        },
      },
    );

/* -------------------------------------------------------------------------- */
/* Policy assertion                                                            */
/* -------------------------------------------------------------------------- */

/**
 * Verify at boot that each cluster actually runs the policy this design
 * depends on. A parameter group edited by hand is the kind of drift that only
 * shows up as "a few jobs vanished last Tuesday".
 *
 * Called from readiness.js / startup. Logs loudly, and in production refuses
 * to start the process when the state cluster can evict.
 */
export async function assertEvictionPolicies() {
  const checks = [
    { role: 'state', client: stateRedis, expected: 'noeviction', fatal: true },
    {
      role: 'cache',
      client: env.REDIS_CACHE_URL ? cacheRedis : null,
      expected: 'volatile-lru',
      fatal: false,
    },
  ];

  for (const { role, client, expected, fatal } of checks) {
    if (!client) continue;
    const policy = await readMaxmemoryPolicy(client);

    if (policy === null) {
      // Managed clusters can refuse CONFIG GET. Not an error — the parameter
      // group is asserted in Terraform (data.tf) as well.
      log.info({ role }, 'maxmemory-policy not readable, relying on the parameter group');
      continue;
    }

    if (policy !== expected) {
      const message = `redis ${role} cluster runs maxmemory-policy=${policy}, expected ${expected}`;
      if (fatal && env.NODE_ENV === 'production') throw new Error(message);
      log.error({ role, policy, expected }, message);
    } else {
      log.info({ role, policy }, 'eviction policy verified');
    }
  }
}

async function readMaxmemoryPolicy(client) {
  try {
    const target = client instanceof Cluster ? client.nodes('master')[0] : client;
    const result = await target.config('GET', 'maxmemory-policy');
    // ioredis returns ['maxmemory-policy', 'noeviction'] or an object on RESP3.
    if (Array.isArray(result)) return result[1] ?? null;
    return result?.['maxmemory-policy'] ?? null;
  } catch {
    return null;
  }
}

/* -------------------------------------------------------------------------- */
/* Health and shutdown                                                         */
/* -------------------------------------------------------------------------- */

/** Input for GET /readyz. */
export async function pingAll() {
  const out = { state: false, cache: null };
  out.state = await stateRedis.ping().then(() => true).catch(() => false);
  if (env.REDIS_CACHE_URL) {
    out.cache = await cacheRedis.ping().then(() => true).catch(() => false);
  }
  return out;
}

export async function closeRedis() {
  await Promise.allSettled([
    stateRedis.quit(),
    env.REDIS_CACHE_URL ? cacheRedis.quit() : Promise.resolve(),
  ]);
}

export default { stateRedis, cacheRedis, pingAll, closeRedis, assertEvictionPolicies };