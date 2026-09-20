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
 * BullMQ accepts an existing ioredis instance. Reusing the shared state client
 * keeps one connection pool, one TLS config and one retry strategy — and, more
 * importantly, one place where `maxRetriesPerRequest: null` is set, which
 * BullMQ requires for its blocking commands.
 *
 * BullMQ duplicates this connection internally for blocking reads, so a worker
 * never starves the rest of the process.
 */
export const connection = stateRedis;

/**
 * Key prefix. Must stay identical across api, worker and sfu, and stable
 * across releases: changing it orphans every queued job.
 *
 * Note this is BullMQ's own prefix and is applied *in addition* to the
 * ioredis keyPrefix configured in db/redis.js, so queue keys end up under
 * "<REDIS_PREFIX>:state:bull:<queue>:...".
 */
export const prefix = 'bull';

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
    await connection.ping();
    return true;
  } catch (err) {
    log.error({ err }, 'queue connection ping failed');
    return false;
  }
}

/**
 * The connection is owned by db/redis.js, so nothing here closes it.
 * Queues and workers close themselves in lifecycle/gracefulShutdown.js, then
 * closeRedis() ends the connection once.
 */
export default { connection, prefix, queueOptions, workerOptions, defaultJobOptions, ping };