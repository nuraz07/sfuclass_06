// classroom-app/server/src/security/sessionActivity.js
/**
 * What each sign-in session is doing  (Settings, Phase B)
 *
 * Kept next to the sessions in SessionStore rather than inside them, so the
 * session format itself does not change:
 *
 *   device-session:{<id>}:revoked   signed out from another device. Checked on
 *                                   every request (middleware/authenticate.js):
 *                                   its access token stops working at once
 *                                   instead of when it expires.
 *   device-session:{<id>}:seen      browser, IP, first and last activity. The
 *                                   device list reads it; the first request of
 *                                   a session is its sign-in, recorded for the
 *                                   sign-in history.
 *   device-session:{<id>}:touch     at most one write per minute per session
 *
 * Failed sign-in attempts are recorded when POST /auth/login answers 401 or
 * 429, against the account whose address was typed in, so its owner sees
 * them.
 *
 * Every Redis failure is fail-open: an outage must not sign everyone out.
 */

import { stateRedis as redis } from '../db/redis.js';
import { pool } from '../db/pool.js';
import { logger } from '../observability/logger.js';

const log = logger.child({ component: 'session-activity' });

const KEEP_SEC = 31 * 24 * 3_600;
const TOUCH_SEC = 60;

const keys = {
  revoked: (sessionId) => `device-session:{${sessionId}}:revoked`,
  seen: (sessionId) => `device-session:{${sessionId}}:seen`,
  touch: (sessionId) => `device-session:{${sessionId}}:touch`,
};

export const SIGN_IN_SUCCEEDED = 'auth.login.succeeded';
export const SIGN_IN_FAILED = 'auth.login.failed';

const audit = async (req, event) => {
  try {
    const { auditFromRequest } = await import('./auditLog.js');
    await auditFromRequest(req, event);
  } catch (cause) {
    log.warn({ err: cause, action: event.action }, 'sign-in not recorded');
  }
};

const userAgentOf = (req) => String(req.get?.('user-agent') ?? '').slice(0, 300) || null;

// ---------------------------------------------------------------------------
// Revocation
// ---------------------------------------------------------------------------

export const markRevoked = async (sessionId) => {
  await redis.set(keys.revoked(sessionId), '1', 'EX', KEEP_SEC);
};

export const isRevoked = async (sessionId) => {
  if (!sessionId) return false;
  try {
    return (await redis.exists(keys.revoked(sessionId))) === 1;
  } catch (cause) {
    log.error({ err: cause }, 'session revocation check unavailable; allowing the request');
    return false;
  }
};

// ---------------------------------------------------------------------------
// Activity
// ---------------------------------------------------------------------------

/**
 * After a request authenticated: remembers browser, IP and time for its
 * session, at most once a minute, and records the sign-in the first time a
 * session is seen. Never awaited by the request.
 */
export const touch = async (req) => {
  const sessionId = req.user?.sessionId;
  if (!sessionId) return;
  try {
    const fresh = (await redis.set(keys.touch(sessionId), '1', 'EX', TOUCH_SEC, 'NX')) === 'OK';
    if (!fresh) return;

    const now = new Date().toISOString();
    const results = await redis
      .multi()
      .hsetnx(keys.seen(sessionId), 'firstSeenAt', now)
      .hset(keys.seen(sessionId), 'lastSeenAt', now, 'ip', String(req.ip ?? ''), 'userAgent', userAgentOf(req) ?? '')
      .expire(keys.seen(sessionId), KEEP_SEC)
      .exec();

    if (results?.[0]?.[1] === 1) {
      await audit(req, {
        action: SIGN_IN_SUCCEEDED,
        targetType: 'user',
        targetId: req.user.id,
        metadata: { platform: req.get?.('x-client-platform') ?? 'web' },
      });
    }
  } catch (cause) {
    log.debug({ err: cause }, 'session activity not written');
  }
};

/** Browser, IP and activity per session id; missing ones are left out. */
export const seenFor = async (sessionIds) => {
  const result = new Map();
  await Promise.all(
    sessionIds.map(async (sessionId) => {
      try {
        const [seen, revoked] = await Promise.all([
          redis.hgetall(keys.seen(sessionId)),
          redis.exists(keys.revoked(sessionId)),
        ]);
        result.set(sessionId, { ...(seen ?? {}), revoked: revoked === 1 });
      } catch {
        // Listed without the extra detail.
      }
    }),
  );
  return result;
};

// ---------------------------------------------------------------------------
// Failed sign-ins
// ---------------------------------------------------------------------------

const LOGIN_PATH = /\/auth\/login\/?$/;

/**
 * Watches POST /auth/login. A rejected attempt for an address that belongs to
 * an account is recorded on that account; attempts for unknown addresses are
 * not recorded anywhere a person could read them.
 */
export const observeSignInAttempt = (req, res) => {
  if (req.method !== 'POST' || !LOGIN_PATH.test(req.path ?? '')) return;
  res.on('finish', () => {
    if (res.statusCode !== 401 && res.statusCode !== 429) return;
    const email = typeof req.body?.email === 'string' ? req.body.email.trim() : '';
    if (!email) return;
    void (async () => {
      try {
        const { rows } = await pool.query(
          `SELECT id, tenant_id, role FROM users WHERE lower(email) = lower($1) AND deleted_at IS NULL LIMIT 1`,
          [email],
        );
        const account = rows[0];
        if (!account) return;
        const asAccount = Object.create(req);
        asAccount.user = { id: account.id, userId: account.id, tenantId: account.tenant_id, role: account.role };
        await audit(asAccount, {
          action: SIGN_IN_FAILED,
          targetType: 'user',
          targetId: account.id,
          metadata: { reason: res.statusCode === 429 ? 'too-many-attempts' : 'wrong-password' },
        });
      } catch (cause) {
        log.debug({ err: cause }, 'failed sign-in not recorded');
      }
    })();
  });
};

export default { markRevoked, isRevoked, touch, seenFor, observeSignInAttempt, SIGN_IN_SUCCEEDED, SIGN_IN_FAILED };
