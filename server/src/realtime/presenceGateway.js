// classroom-app/server/src/realtime/presenceGateway.js
/**
 * Presence and per-person delivery  (F2, F6, Settings Phase B)
 *
 * Registered by realtime/index.js (attachPresenceGateway) in every process that
 * holds sockets. Two jobs:
 *
 *   Presence. Whoever has an open /chat connection is looking at the app;
 *   whoever has an open /classroom connection is in a lesson. The
 *   notification rules depend on it: no push to someone looking at the app,
 *   and — with focus on — no chat notifications during a lesson, but a
 *   summary afterwards. Written to realtime/liveState.js (and the v6 presence
 *   keys), refreshed every 25 seconds.
 *
 *   Delivery. Other processes publish events for one person
 *   (realtime/userEvents.js); every realtime task delivers them to the
 *   sockets it holds, in /chat and the root namespace (clients dedupe). Emits are local on purpose: each task receives the
 *   publication itself, so going through the Socket.IO Redis adapter as well
 *   would deliver everything once per task.
 *
 * A sign-in session that was ended elsewhere gets `session:revoked` on its own
 * sockets and is then disconnected; the web client signs out on that event.
 */

import { stateRedis } from '../db/redis.js';
import { logger } from '../observability/logger.js';
import * as Presence from './presenceCompat.js';
import * as LiveState from './liveState.js';
import * as Focus from '../notifications/focus.js';
import { USER_EVENTS_CHANNEL, pushToUser, publishSessionRevoked } from './userEvents.js';

export { pushToUser, publishSessionRevoked };

const log = logger.child({ component: 'presence-gateway' });

const HEARTBEAT_MS = 25_000;

/** Joined by every /chat socket here, so delivery does not depend on another gateway's room names. */
const personalRoom = (userId) => `user-events:${userId}`;
const NAMESPACES = ['/', '/chat', '/classroom', '/community'];

export const attachPresenceGateway = (io) => {
  /** userId → { app: open /chat sockets, lesson: open /classroom sockets } on this task */
  const counts = new Map();

  const bump = (userId, kind, delta) => {
    const entry = counts.get(userId) ?? { app: 0, lesson: 0 };
    entry[kind] = Math.max(0, entry[kind] + delta);
    if (entry.app === 0 && entry.lesson === 0) counts.delete(userId);
    else counts.set(userId, entry);
  };

  const refresh = async (userId, { leftLesson = false } = {}) => {
    const entry = counts.get(userId);
    try {
      if (entry?.lesson > 0) {
        await LiveState.markLesson(userId);
      } else if (leftLesson) {
        // Another task with a lesson socket marks it again within one heartbeat.
        await LiveState.clearLesson(userId);
        await Focus.leftLesson(userId);
      }
      if (entry?.app > 0) await LiveState.markApp(userId);
      else if (!entry) await LiveState.clearApp(userId);
    } catch (cause) {
      log.warn({ err: cause, userId }, 'live state not updated');
    }

    // The v6 presence keys, for everything that still reads them. Best effort.
    try {
      if (!entry) {
        await Presence.clear({ userId });
      } else {
        const inLesson = entry.lesson > 0 || (await LiveState.isInLesson(userId).catch(() => false));
        await Presence.heartbeat({ userId, state: inLesson ? 'in-class' : 'online' });
      }
    } catch {
      // presenceCompat is optional for Phase B.
    }
  };

  for (const [name, kind] of [
    ['/chat', 'app'],
    ['/classroom', 'lesson'],
  ]) {
    io.of(name).on('connection', (socket) => {
      const userId = socket.data?.userId ?? socket.data?.auth?.userId;
      if (!userId) return;
      // Personal room for per-person events (see deliver below).
      if (kind === 'app') socket.join(personalRoom(userId));
      bump(userId, kind, 1);
      void refresh(userId);
      socket.on('disconnect', () => {
        bump(userId, kind, -1);
        void refresh(userId, { leftLesson: kind === 'lesson' && !(counts.get(userId)?.lesson > 0) });
      });
    });
  }

  // The root namespace joins the personal room too: some clients listen there.
  io.of('/').on('connection', (socket) => {
    const userId = socket.data?.userId ?? socket.data?.auth?.userId;
    if (userId) socket.join(personalRoom(userId));
  });

  const timer = setInterval(() => {
    for (const userId of counts.keys()) void refresh(userId);
  }, HEARTBEAT_MS);
  timer.unref?.();

  // -------------------------------------------------------------------------
  // Events for one person, from any process
  // -------------------------------------------------------------------------

  const deliver = (message) => {
    if (message?.type === 'session-revoked') {
      for (const name of NAMESPACES) {
        for (const socket of io.of(name).sockets.values()) {
          const sessionId = socket.data?.sessionId ?? socket.data?.auth?.sessionId ?? null;
          if (sessionId !== message.sessionId) continue;
          socket.emit('session:revoked', { reason: message.reason ?? 'signed-out' });
          // Give the event a moment to leave before the connection closes.
          setTimeout(() => socket.disconnect(true), 250).unref?.();
        }
      }
      return;
    }

    if (message?.type === 'event' && message.userId && message.event) {
      for (const name of ['/chat', '/']) {
        io.of(name).local.to(personalRoom(message.userId)).emit(message.event, message.payload ?? {});
      }
    }
  };

  let subscriber = null;
  try {
    subscriber = stateRedis.duplicate();
    subscriber.on('message', (channel, raw) => {
      if (channel !== USER_EVENTS_CHANNEL) return;
      try {
        deliver(JSON.parse(raw));
      } catch (cause) {
        log.warn({ err: cause }, 'malformed user event');
      }
    });
    subscriber.subscribe(USER_EVENTS_CHANNEL).catch((cause) => {
      log.error({ err: cause }, 'user events not subscribed; live updates will not arrive');
    });
  } catch (cause) {
    log.error({ err: cause }, 'user events subscriber could not be created');
  }

  log.info('presence and per-person delivery attached');

  return {
    close: async () => {
      clearInterval(timer);
      await subscriber?.quit().catch(() => undefined);
    },
  };
};

export default attachPresenceGateway;

/** Other names a realtime entrypoint may call it by. */
export const attach = attachPresenceGateway;
export const registerPresenceGateway = attachPresenceGateway;
