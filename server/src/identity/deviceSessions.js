// classroom-app/server/src/identity/deviceSessions.js
/**
 * Signed-in devices  (Settings, Phase B)
 *
 * The sign-in sessions of one person, as Settings → Sign-in & devices shows
 * them, and signing them out from another device.
 *
 * Sessions live in SessionStore (Redis). This module does not change their
 * format; it reads them with listSessions, adds what security/sessionActivity
 * saw (browser, IP, last activity) and, to sign one out:
 *
 *   1. marks it revoked, so its access token is refused on the next request
 *   2. revokes it in SessionStore, so its refresh token is refused
 *   3. removes the browser push registrations it made
 *   4. tells its open tabs (session:revoked), which sign themselves out
 */

import * as Sessions from './SessionStore.js';
import * as Activity from '../security/sessionActivity.js';
import * as Subscriptions from '../notifications/webPushSubscriptions.js';
import { publishSessionRevoked } from '../realtime/userEvents.js';
import { describeUserAgent } from '../security/userAgent.js';
import { logger } from '../observability/logger.js';

const log = logger.child({ component: 'device-sessions' });

const iso = (value) => {
  if (!value) return null;
  const date = new Date(typeof value === 'number' && value < 1e12 ? value * 1000 : value);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
};

/** SessionStore's records, whatever shape listSessions returns them in; null when unknown. */
const readSessions = async (userId) => {
  if (typeof Sessions.listSessions !== 'function') return null;
  const asList = (raw) => (Array.isArray(raw) ? raw : Array.isArray(raw?.items) ? raw.items : null);
  let list;
  try {
    list = asList(await Sessions.listSessions(userId));
    // Some versions take an options object instead of the id.
    if (!list || list.length === 0) list = asList(await Promise.resolve().then(() => Sessions.listSessions({ userId })).catch(() => null)) ?? list;
  } catch (cause) {
    log.warn({ err: cause }, 'sessions could not be listed');
    return null;
  }
  if (!list) return null;
  return list
    .map((session) => ({
      sessionId: session.sessionId ?? session.id ?? null,
      userId: session.userId ?? userId,
      device: session.device ?? {},
      createdAt: iso(session.createdAt ?? session.created_at),
      lastUsedAt: iso(session.lastUsedAt ?? session.last_used_at ?? session.updatedAt),
    }))
    .filter((session) => session.sessionId && (!session.userId || session.userId === userId));
};

/**
 * @returns {Promise<Array<{ sessionId, label, platform, ip, createdAt, lastActiveAt }>>}
 */
export const list = async (userId) => {
  const sessions = (await readSessions(userId)) ?? [];
  const seen = await Activity.seenFor(sessions.map((session) => session.sessionId));

  return sessions
    .filter((session) => !seen.get(session.sessionId)?.revoked)
    .map((session) => {
      const activity = seen.get(session.sessionId) ?? {};
      const userAgent = activity.userAgent || session.device.userAgent || '';
      const lastActiveAt = [activity.lastSeenAt, session.lastUsedAt]
        .filter(Boolean)
        .sort()
        .at(-1) ?? session.createdAt;
      return {
        sessionId: session.sessionId,
        label: describeUserAgent(userAgent, session.device.platform),
        platform: session.device.platform ?? null,
        ip: activity.ip || session.device.ip || null,
        createdAt: session.createdAt ?? activity.firstSeenAt ?? null,
        lastActiveAt: lastActiveAt ?? null,
      };
    })
    .sort((a, b) => String(b.lastActiveAt ?? '').localeCompare(String(a.lastActiveAt ?? '')));
};

/** Ids of the sessions still signed in, or null when SessionStore cannot say. */
export const liveSessionIds = async (userId) => {
  const sessions = await readSessions(userId);
  if (!sessions) return null;
  const seen = await Activity.seenFor(sessions.map((session) => session.sessionId));
  return new Set(sessions.filter((s) => !seen.get(s.sessionId)?.revoked).map((s) => s.sessionId));
};

/**
 * Signs one of this person's sessions out.
 * @returns {Promise<null | { sessionId: string, label: string }>} null when it is not theirs
 */
export const revoke = async ({ userId, sessionId, reason = 'signed-out-remotely' }) => {
  const own = (await list(userId)).find((session) => session.sessionId === sessionId);
  if (!own) return null;

  await Activity.markRevoked(sessionId);
  try {
    await Sessions.revokeSession({ sessionId, reason });
  } catch (cause) {
    // The mark above already refuses its tokens; the refresh token expires on its own.
    log.warn({ err: cause, sessionId }, 'session store did not revoke the session');
  }
  await Subscriptions.removeForSession({ userId, sessionId }).catch(() => undefined);
  await publishSessionRevoked({ userId, sessionId, reason });

  log.info({ userId, reason }, 'session signed out from another device');
  return { sessionId, label: own.label };
};

/** Every session except the one asking. */
export const revokeOthers = async ({ userId, currentSessionId }) => {
  const others = (await list(userId)).filter((session) => session.sessionId !== currentSessionId);
  let revoked = 0;
  for (const session of others) {
    if (await revoke({ userId, sessionId: session.sessionId, reason: 'signed-out-everywhere-else' })) revoked += 1;
  }
  return { revoked };
};

export default { list, liveSessionIds, revoke, revokeOthers };
