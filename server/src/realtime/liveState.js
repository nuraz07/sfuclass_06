// classroom-app/server/src/realtime/liveState.js
/**
 * Is this person looking at the app, or in a lesson?  (Settings, Phase B)
 *
 * Written by the presence gateway while a person has open sockets, refreshed
 * every 25 seconds and gone 60 seconds after the last one closes:
 *
 *   live:{<user>}:app      an open /chat connection (every tab has one)
 *   live:{<user>}:lesson   an open /classroom connection
 *
 * (The braces keep both keys in one cluster slot, so they are read together.)
 *
 * Read by the notification rules: no push to someone looking at the app, and
 * — with focus on — no chat notifications during a lesson. On the state
 * cluster, so every task and the worker see the same answer. The v6 presence
 * keys (presenceCompat.js) are written as well; these two are what the
 * notification rules rely on.
 */

import { stateRedis as redis } from '../db/redis.js';

const TTL_SEC = 60;

const keys = {
  app: (userId) => `live:{${userId}}:app`,
  lesson: (userId) => `live:{${userId}}:lesson`,
};

export const markApp = (userId) => redis.set(keys.app(userId), '1', 'EX', TTL_SEC);
export const markLesson = (userId) => redis.set(keys.lesson(userId), '1', 'EX', TTL_SEC);
export const clearApp = (userId) => redis.del(keys.app(userId));
export const clearLesson = (userId) => redis.del(keys.lesson(userId));

export const isInLesson = async (userId) => (await redis.exists(keys.lesson(userId))) === 1;

/** 'in-class' · 'online' · 'offline'. A Redis problem reads as offline: notify rather than stay silent. */
export const stateOf = async (userId) => {
  try {
    const [[, lesson], [, app]] = await redis.multi().exists(keys.lesson(userId)).exists(keys.app(userId)).exec();
    if (lesson === 1) return 'in-class';
    if (app === 1) return 'online';
    return 'offline';
  } catch {
    return 'offline';
  }
};

export default { markApp, markLesson, clearApp, clearLesson, isInLesson, stateOf };
