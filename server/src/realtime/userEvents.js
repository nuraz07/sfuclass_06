// classroom-app/server/src/realtime/userEvents.js
/**
 * Events addressed to one person, from any process  (Settings, Phase B)
 *
 * The API, the worker and the SFU all need to tell a person something live —
 * "a notification arrived", "your settings changed on another device", "this
 * session was signed out" — but only the realtime process holds sockets. So
 * every process publishes here, on the state Redis cluster, and each realtime
 * task delivers to the sockets it holds (realtime/presenceGateway.js).
 *
 * Publishing never throws: a live update that does not arrive is a missed
 * refresh, not a failed action.
 */

import { env } from '../config/env.js';
import { stateRedis } from '../db/redis.js';
import { logger } from '../observability/logger.js';

const log = logger.child({ component: 'user-events' });

/** Channel names are not keys, so they carry the prefix explicitly. */
export const USER_EVENTS_CHANNEL = `${env.REDIS_PREFIX}:user-events`;

const publish = async (message) => {
  try {
    await stateRedis.publish(USER_EVENTS_CHANNEL, JSON.stringify(message));
    return true;
  } catch (cause) {
    log.warn({ err: cause, type: message.type }, 'user event not published');
    return false;
  }
};

/** An event on every socket of this person, in the /chat namespace (every tab has one). */
export const pushToUser = (userId, event, payload = {}) =>
  userId && event ? publish({ type: 'event', userId, event, payload }) : Promise.resolve(false);

/** Tells the sockets of one sign-in session that it ended, then closes them. */
export const publishSessionRevoked = ({ userId, sessionId, reason = 'signed-out' }) =>
  sessionId ? publish({ type: 'session-revoked', userId, sessionId, reason }) : Promise.resolve(false);

export default { USER_EVENTS_CHANNEL, pushToUser, publishSessionRevoked };
