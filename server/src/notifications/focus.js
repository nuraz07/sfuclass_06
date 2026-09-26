// classroom-app/server/src/notifications/focus.js
/**
 * Focus during lessons  (Settings, Phase B)
 *
 * While someone is in a live lesson, private messages and mentions from
 * outside it do not notify them. They are held here and, once the person has
 * left the lesson, delivered as one summary ("While you were in your lesson:
 * 4 new messages from Anna and Ben").
 *
 * State, on the state cluster, all with a TTL:
 *
 *   focus:{<user>}:held        the held items, newest last, capped at 200
 *   focus:{<user>}:scheduled   a summary check is already queued
 *
 * Whether someone is in a lesson is realtime/liveState.js, written by the
 * presence gateway. The summary is a queued job (notification.focus.flush)
 * rather than a timer, so it survives a restart and runs in the worker like
 * every other notification.
 */

import { stateRedis as redis } from '../db/redis.js';
import { logger } from '../observability/logger.js';
import * as LiveState from '../realtime/liveState.js';

export { summarizeHeld } from './focusSummary.js';

const log = logger.child({ component: 'focus' });

const HELD_TTL_SEC = 24 * 3_600;
const MAX_HELD = 200;
/** How often a waiting summary looks again while the lesson is still running. */
const RECHECK_MS = 60_000;
/** After leaving: long enough for a network blip to reconnect, short enough to feel immediate. */
const AFTER_LEAVE_MS = 5_000;

const keys = {
  held: (userId) => `focus:{${userId}}:held`,
  scheduled: (userId) => `focus:{${userId}}:scheduled`,
};

export const isInLesson = async (userId) => {
  try {
    return await LiveState.isInLesson(userId);
  } catch {
    return false;
  }
};

/**
 * Queues a summary check. At most one waits per person unless `force`, which
 * a departure uses to jump ahead of a check that is still a minute out.
 */
export const scheduleFlush = async (userId, { delayMs = RECHECK_MS, force = false } = {}) => {
  const ttl = delayMs + 30_000;
  const fresh = (await redis.set(keys.scheduled(userId), '1', 'PX', ttl, 'NX')) === 'OK';
  if (!fresh && !force) return false;
  if (!fresh) await redis.set(keys.scheduled(userId), '1', 'PX', ttl);

  const { enqueue, QUEUE_NAMES } = await import('../queues/queues.js');
  await enqueue(
    QUEUE_NAMES.NOTIFY,
    'notification.focus.flush',
    { userId },
    // Unique per attempt: BullMQ keeps completed job ids for a while and would
    // silently drop a second job with the same id.
    { jobId: `focus-flush.${userId}.${Date.now()}`, delay: delayMs },
  );
  return true;
};

export const clearSchedule = (userId) => redis.del(keys.scheduled(userId));

/** Called by the presence gateway when someone's last lesson connection closes. */
export const leftLesson = async (userId) => {
  if ((await redis.llen(keys.held(userId))) > 0) {
    await scheduleFlush(userId, { delayMs: AFTER_LEAVE_MS, force: true });
  }
};

/** Holds one item and makes sure a summary will follow. */
export const hold = async (userId, item) => {
  const entry = JSON.stringify({ ...item, at: item.at ?? new Date().toISOString() });
  await redis
    .multi()
    .rpush(keys.held(userId), entry)
    .ltrim(keys.held(userId), -MAX_HELD, -1)
    .expire(keys.held(userId), HELD_TTL_SEC)
    .exec();
  await scheduleFlush(userId).catch((cause) => log.warn({ err: cause, userId }, 'focus summary not scheduled'));
};

/** Everything held, removed in the same step, so two checks cannot both send it. */
export const takeHeld = async (userId) => {
  const results = await redis.multi().lrange(keys.held(userId), 0, -1).del(keys.held(userId)).exec();
  const raw = results?.[0]?.[1] ?? [];
  return raw
    .map((entry) => {
      try {
        return JSON.parse(entry);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
};

export default { isInLesson, leftLesson, hold, takeHeld, scheduleFlush, clearSchedule };
