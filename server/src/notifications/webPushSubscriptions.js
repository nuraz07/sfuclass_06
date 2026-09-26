// classroom-app/server/src/notifications/webPushSubscriptions.js
/**
 * Browsers that receive push  (Settings, Phase B)
 *
 * One row per browser. The endpoint is unique: the same browser registering
 * again after a change of account moves to the new account instead of
 * delivering one person's messages to another.
 *
 * A subscription belongs to the sign-in session that created it. Signing that
 * device out — here, or from another device in Settings — removes it.
 */

import { pool } from '../db/pool.js';

export const listForUser = async (userId) => {
  const { rows } = await pool.query(
    `SELECT id, endpoint, p256dh, auth, session_id, user_agent, created_at, last_success_at
       FROM web_push_subscriptions WHERE user_id = $1 ORDER BY created_at DESC`,
    [userId],
  );
  return rows;
};

export const countForUser = async (userId) => {
  const { rows } = await pool.query(
    `SELECT count(*)::int AS n FROM web_push_subscriptions WHERE user_id = $1`,
    [userId],
  );
  return rows[0]?.n ?? 0;
};

export const upsert = async ({ userId, sessionId = null, endpoint, p256dh, auth, userAgent = null }) => {
  await pool.query(
    `INSERT INTO web_push_subscriptions (user_id, session_id, endpoint, p256dh, auth, user_agent)
     VALUES ($1, $2, $3, $4, $5, $6)
     ON CONFLICT (endpoint) DO UPDATE
        SET user_id = EXCLUDED.user_id,
            session_id = EXCLUDED.session_id,
            p256dh = EXCLUDED.p256dh,
            auth = EXCLUDED.auth,
            user_agent = EXCLUDED.user_agent,
            failures = 0`,
    [userId, sessionId, endpoint, p256dh, auth, userAgent ? String(userAgent).slice(0, 300) : null],
  );
};

export const removeByEndpoint = async ({ userId, endpoint }) => {
  const { rowCount } = await pool.query(
    `DELETE FROM web_push_subscriptions WHERE user_id = $1 AND endpoint = $2`,
    [userId, endpoint],
  );
  return rowCount;
};

export const removeForSession = async ({ userId, sessionId }) => {
  if (!sessionId) return 0;
  const { rowCount } = await pool.query(
    `DELETE FROM web_push_subscriptions WHERE user_id = $1 AND session_id = $2`,
    [userId, sessionId],
  );
  return rowCount;
};

export const removeForUser = async (userId) => {
  const { rowCount } = await pool.query(`DELETE FROM web_push_subscriptions WHERE user_id = $1`, [userId]);
  return rowCount;
};

export const removeById = async (id) => {
  await pool.query(`DELETE FROM web_push_subscriptions WHERE id = $1`, [id]);
};

export const recordSuccess = async (id) => {
  await pool.query(
    `UPDATE web_push_subscriptions SET failures = 0, last_success_at = now() WHERE id = $1`,
    [id],
  );
};

/** Five failures in a row and a subscription is dead weight. */
export const recordFailure = async (id) => {
  const { rows } = await pool.query(
    `UPDATE web_push_subscriptions SET failures = failures + 1 WHERE id = $1 RETURNING failures`,
    [id],
  );
  if ((rows[0]?.failures ?? 0) >= 5) await removeById(id);
};

export default {
  listForUser,
  countForUser,
  upsert,
  removeByEndpoint,
  removeForSession,
  removeForUser,
  removeById,
  recordSuccess,
  recordFailure,
};
