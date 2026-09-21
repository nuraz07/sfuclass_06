// server/src/jobs/_runJob.js
/**
 * Shared runner for scheduled jobs  (F7)
 *
 * Every file in jobs/ is an entrypoint. EventBridge Scheduler starts a one-off
 * ECS task with `node src/jobs/<name>.js`, and each file ends with
 *
 *   if (isMain(import.meta.url)) {
 *     await runJob('<name>', fn, { timeBudgetMs, lockTtlMs });
 *   }
 *
 * so the same file can be imported by tests or ops scripts without running.
 *
 * runJob gives every job the same frame:
 *
 *   single runner  A lock on the state Redis cluster (SET NX PX) with a random
 *                  token, released only by its owner. A duplicate EventBridge
 *                  delivery or an overlapping retry logs "skipped" and exits 0.
 *   time budget    ctx.clock.expired() turns true and ctx.signal aborts when the
 *                  budget is used up; jobs stop at their next batch boundary.
 *                  A job that ignores both is killed after a grace period, well
 *                  before its lock can expire under it.
 *   shutdown       SIGTERM (ECS stopping the task) aborts the signal the same way.
 *   exit code      0 on success or skip, 1 on failure, which is what the
 *                  scheduler's retry policy and the alarms read.
 *   cleanup        lock released, then Redis and Postgres closed.
 *
 * The job function receives one context object and may return a summary,
 * which is logged:
 *
 *   { name, log, clock: { deadline, expired(), remainingMs() }, signal, startedAt }
 *
 * Configuration and secrets are already loaded when this runs: the job file's
 * static imports evaluate config/env.js, and in AWS the task definition injects
 * secrets as Secrets Manager references.
 */

import path from 'node:path';
import { realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

import { env } from '../config/env.js';
import { stateRedis, closeRedis } from '../db/redis.js';
import { pool } from '../db/pool.js';
import { logger } from '../observability/logger.js';

/** How long a job may overrun its budget before the process is killed. */
const KILL_GRACE_MS = 60_000;

/** Last resort if a queue or client keeps the event loop alive after cleanup. */
const EXIT_FALLBACK_MS = 5_000;

// Delete the lock only if it is still ours. A plain DEL after an overrun could
// remove the lock of the next run that legitimately took over.
const RELEASE_SCRIPT = `
if redis.call('GET', KEYS[1]) == ARGV[1] then
  return redis.call('DEL', KEYS[1])
end
return 0
`;

/**
 * True when the module at `moduleUrl` is the process entrypoint
 * (`node src/jobs/x.js`), false when it was imported.
 * @param {string} moduleUrl  import.meta.url of the calling module
 */
export function isMain(moduleUrl) {
  const entry = process.argv[1];
  if (!entry) return false;
  try {
    return realpathSync(path.resolve(entry)) === realpathSync(fileURLToPath(moduleUrl));
  } catch {
    return false;
  }
}

/**
 * @param {string} name  job name; also the lock key and the log field
 * @param {(ctx: object) => Promise<unknown>} fn
 * @param {{ timeBudgetMs?: number, lockTtlMs?: number }} [options]
 */
export async function runJob(name, fn, { timeBudgetMs = 5 * 60_000, lockTtlMs } = {}) {
  const lockTtl = lockTtlMs ?? timeBudgetMs + 2 * KILL_GRACE_MS;
  if (lockTtl <= timeBudgetMs + KILL_GRACE_MS) {
    throw new RangeError(
      `runJob(${name}): lockTtlMs (${lockTtl}) must exceed timeBudgetMs + ${KILL_GRACE_MS} ms, ` +
        'or the lock could expire while the job is still running',
    );
  }

  const log = logger.child({ component: 'job', job: name });
  const lockKey = `${env.REDIS_PREFIX}:job-lock:${name}`;
  const token = randomUUID();
  const startedAt = Date.now();
  const deadline = startedAt + timeBudgetMs;
  const controller = new AbortController();

  const clock = Object.freeze({
    deadline,
    expired: () => Date.now() >= deadline,
    remainingMs: () => Math.max(0, deadline - Date.now()),
  });

  const budgetTimer = setTimeout(() => {
    log.warn({ timeBudgetMs }, 'time budget reached, asking the job to stop');
    controller.abort(new Error('time budget exceeded'));
  }, timeBudgetMs);
  budgetTimer.unref();

  const killTimer = setTimeout(() => {
    log.error({ timeBudgetMs, graceMs: KILL_GRACE_MS }, 'job ignored its time budget, exiting');
    process.exit(1);
  }, timeBudgetMs + KILL_GRACE_MS);
  killTimer.unref();

  const onSigterm = () => {
    log.warn('SIGTERM received, asking the job to stop');
    controller.abort(new Error('SIGTERM'));
  };
  process.once('SIGTERM', onSigterm);

  let acquired = false;
  let exitCode = 0;
  let summary;

  try {
    acquired = (await stateRedis.set(lockKey, token, 'PX', lockTtl, 'NX')) === 'OK';

    if (!acquired) {
      log.info('another run holds the lock, skipping');
      summary = { skipped: true };
    } else {
      log.info({ timeBudgetMs, lockTtlMs: lockTtl }, 'job started');
      summary = await fn({ name, log, clock, signal: controller.signal, startedAt });
      log.info({ durationMs: Date.now() - startedAt, summary }, 'job finished');
    }
  } catch (err) {
    exitCode = 1;
    log.error({ err, durationMs: Date.now() - startedAt }, 'job failed');
  } finally {
    clearTimeout(budgetTimer);
    clearTimeout(killTimer);
    process.off('SIGTERM', onSigterm);

    if (acquired) {
      await stateRedis
        .eval(RELEASE_SCRIPT, 1, lockKey, token)
        .catch((err) => log.warn({ err }, 'lock release failed; it expires on its own'));
    }

    await closeRedis().catch((err) => log.warn({ err }, 'closing redis failed'));
    await pool.end().catch((err) => log.warn({ err }, 'closing postgres failed'));

    process.exitCode = exitCode;
    setTimeout(() => process.exit(exitCode), EXIT_FALLBACK_MS).unref();
  }

  return summary;
}

export default runJob;