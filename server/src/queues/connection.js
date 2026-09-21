/**
 * server/src/queues/connection.js
 *
 * The one Redis connection BullMQ is allowed to use.  (F7)
 *
 * v6 -> v7 correction: BullMQ shared a cluster with the caches. It cannot.
 * Every job, every delayed set, every lock lives in ordinary Redis keys with
 * no TTL; on an evicting cluster a job can be thrown away between "queued" and
 * "processed" and nothing in the system would notice. This module binds BullMQ
 * to the state cluster (noeviction) and makes it impossible to point it
 * anywhere else.
 *
 * Imported by queues/queues.js, every worker in queues/workers/, and by
 * mediasoup/recording/recordingPipeline.js on the SFU node (which receives
 * REDIS_STATE_URL and nothing else).
 *
 * Node.js 22, ESM.
 */

import { randomUUID } from 'node:crypto';

import { env } from '../config/env.js';
import { stateRedis } from '../db/redis.js';
import { logger } from '../observability/logger.js';

const log = logger.child({ component: 'queue-connection' });

/* -------------------------------------------------------------------------- */
/* Guards                                                                      */
/* -------------------------------------------------------------------------- */

if (!env.REDIS_STATE_URL) {
  throw new Error('queues require REDIS_STATE_URL (the noeviction cluster)');
}

if (env.REDIS_CACHE_URL && env.REDIS_STATE_URL === env.REDIS_CACHE_URL) {
  throw new Error(
    'REDIS_STATE_URL and REDIS_CACHE_URL point at the same cluster; ' +
      'BullMQ must not share a cluster that evicts',
  );
}

/* -------------------------------------------------------------------------- */
/* Connection                                                                  */
/* -------------------------------------------------------------------------- */

/**
 * What BullMQ connects with.
 *
 * BullMQ refuses an ioredis client that has a `keyPrefix` ("ioredis does not
 * support ioredis prefixes, use the prefix option instead") and its workers
 * need `maxRetriesPerRequest: null` for their blocking reads. The shared state
 * client in db/redis.js may carry both a keyPrefix and a finite retry count,
 * because every other caller wants them.
 *
 * So for a single-node client BullMQ gets connection *options* derived from
 * the state client — same host, port, db, credentials and TLS — without the
 * keyPrefix and with the retry setting BullMQ needs. The keyPrefix moves into
 * BullMQ's own `prefix`, so queue keys stay under the same namespace as before
 * ("<keyPrefix>bull:<queue>:..."). Every Queue and Worker then owns its
 * connections and closes them itself.
 *
 * A cluster client (production) is passed through as is: cluster mode needs a
 * hash-tagged prefix and is configured in db/redis.js for that purpose.
 */
const stateOptions = stateRedis.isCluster ? null : { ...(stateRedis.options ?? {}) };
const clientKeyPrefix = stateRedis.isCluster
  ? stateRedis.options?.redisOptions?.keyPrefix ?? ''
  : stateOptions.keyPrefix ?? '';

export const connection = stateRedis.isCluster
  ? stateRedis
  : { ...stateOptions, keyPrefix: '', maxRetriesPerRequest: null, enableReadyCheck: false, lazyConnect: false };

/**
 * Key prefix. Must stay identical across api, worker and sfu, and stable
 * across releases: changing it orphans every queued job.
 *
 * For a single-node client this includes the ioredis keyPrefix of the state
 * client (moved here, see above), so queue keys end up under
 * "<REDIS_PREFIX>:state:bull:<queue>:..." when db/redis.js sets that prefix.
 */
export const prefix = stateRedis.isCluster ? 'bull' : `${clientKeyPrefix}bull`;

/**
 * Defaults every queue inherits unless it overrides them in queues.js.
 * Retained history is deliberately asymmetric: successes are pruned, failures
 * are kept so maintenanceWorker and the on-call runbook can inspect them.
 */
export const defaultJobOptions = {
  attempts: 5,
  backoff: { type: 'exponential', delay: 5_000 },
  removeOnComplete: { age: 24 * 3_600, count: 1_000 },
  removeOnFail: { age: 14 * 24 * 3_600 },
};

/** Shared worker settings. */
export const workerOptions = {
  connection,
  prefix,
  // Lock must exceed the longest plausible single job step, or a slow
  // MediaConvert poll gets its job stolen and processed twice.
  lockDuration: 60_000,
  stalledInterval: 30_000,
  maxStalledCount: 2,
  removeOnComplete: defaultJobOptions.removeOnComplete,
  removeOnFail: defaultJobOptions.removeOnFail,
};

/** Shared queue settings. */
export const queueOptions = {
  connection,
  prefix,
  defaultJobOptions,
};

/* -------------------------------------------------------------------------- */
/* Health                                                                      */
/* -------------------------------------------------------------------------- */

/** Used by readiness.js in the worker role. */
export async function ping() {
  try {
    await stateRedis.ping();
    return true;
  } catch (err) {
    log.error({ err }, 'queue connection ping failed');
    return false;
  }
}

/* -------------------------------------------------------------------------- */
/* Helpers for workers (v6 API)                                                */
/* -------------------------------------------------------------------------- */

/**
 * The Redis client a worker uses for its own bookkeeping (dedupe markers,
 * counters) — not for BullMQ. It is the shared state client: those keys must
 * not be evicted either. The name only labels log lines.
 *
 * @param {string} [name]
 */
export function utilityConnection(name = 'worker') {
  log.debug({ name }, 'utility connection handed out (shared state client)');
  return stateRedis;
}

// Delete the lock only if it is still ours: after an overrun, a plain DEL
// could remove the lock of the next run that legitimately took over.
const RELEASE_LOCK = `
if redis.call('GET', KEYS[1]) == ARGV[1] then
  return redis.call('DEL', KEYS[1])
end
return 0
`;

/**
 * Single-runner lock on the state cluster.
 *
 *   const release = await acquireLock('maintenance:quotaDrift', 10 * 60_000);
 *   if (!release) return { skipped: 'locked' };
 *   try { ... } finally { await release(); }
 *
 * @param {string} name
 * @param {number} ttlMs   upper bound for the work; the lock expires on its own after it
 * @returns {Promise<(() => Promise<boolean>) | null>}  release function, or null if held elsewhere
 */
export async function acquireLock(name, ttlMs = 60_000) {
  const key = `${env.REDIS_PREFIX}:lock:${name}`;
  const token = randomUUID();
  const acquired = (await stateRedis.set(key, token, 'PX', ttlMs, 'NX')) === 'OK';
  if (!acquired) return null;

  let released = false;
  return async () => {
    if (released) return false;
    released = true;
    try {
      return (await stateRedis.eval(RELEASE_LOCK, 1, key, token)) === 1;
    } catch (err) {
      log.warn({ err, name }, 'lock release failed; it expires on its own');
      return false;
    }
  };
}

/**
 * The state client is owned by db/redis.js, so nothing here closes it.
 * Queues and workers close their own connections (they are created from
 * options, see above) in lifecycle/gracefulShutdown.js; closeRedis() then ends
 * the shared client once.
 */
export default {
  connection, prefix, queueOptions, workerOptions, defaultJobOptions, ping, utilityConnection, acquireLock,
};