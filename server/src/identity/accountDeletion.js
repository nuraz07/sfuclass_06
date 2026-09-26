// classroom-app/server/src/identity/accountDeletion.js
/**
 * Deleting an account  (Settings, Phase C)
 *
 * Two steps, fourteen days apart:
 *
 *   request    every other device is signed out, an email confirms it, and
 *              the account keeps working — signing in and pressing Cancel in
 *              the banner stops the deletion. Nothing is removed yet.
 *
 *   run        after the grace period (notificationWorker, 'account.deletion'):
 *              the account is anonymised, not dropped. Messages, posts,
 *              grades and attendance belong to the courses and chats they
 *              were part of, so they stay, attributed to "Deleted user".
 *              Everything personal goes: email, password, name, profile,
 *              settings, notifications, push registrations, two-step
 *              sign-in, passkeys, blocks, memberships of chats; every
 *              session ends.
 *
 * Every run re-checks the database, so a job that fires twice, or for a
 * request that was cancelled, does nothing.
 */

import { pool } from '../db/pool.js';
import { logger } from '../observability/logger.js';

const log = logger.child({ component: 'account-deletion' });

export const GRACE_DAYS = 14;

const iso = (value) => (value ? new Date(value).toISOString() : null);

export const status = async (userId) => {
  const { rows } = await pool.query(
    `SELECT requested_at, scheduled_for FROM account_deletion_requests
      WHERE user_id = $1 AND completed_at IS NULL`,
    [userId],
  );
  return rows[0] ? { requestedAt: iso(rows[0].requested_at), scheduledFor: iso(rows[0].scheduled_for) } : null;
};

const schedule = async ({ userId, scheduledFor }) => {
  try {
    const { enqueue, QUEUE_NAMES } = await import('../queues/queues.js');
    const at = new Date(scheduledFor).getTime();
    await enqueue(
      QUEUE_NAMES.NOTIFY,
      'account.deletion',
      { userId },
      { jobId: `account-deletion.${userId}.${at}`, delay: Math.max(0, at - Date.now()), attempts: 5 },
    );
  } catch (cause) {
    // The row is the truth; every run of the job also sweeps whatever is due.
    log.error({ err: cause, userId }, 'deletion job not queued');
  }
};

/** Starts the grace period. A second request keeps the first date. */
export const request = async ({ userId, graceDays = GRACE_DAYS }) => {
  const { rows } = await pool.query(
    `INSERT INTO account_deletion_requests (user_id, requested_at, scheduled_for)
     VALUES ($1, now(), now() + ($2 || ' days')::interval)
     ON CONFLICT (user_id) DO UPDATE
        SET requested_at = CASE WHEN account_deletion_requests.completed_at IS NULL
                                 THEN account_deletion_requests.requested_at ELSE now() END,
            scheduled_for = CASE WHEN account_deletion_requests.completed_at IS NULL
                                 THEN account_deletion_requests.scheduled_for
                                 ELSE now() + ($2 || ' days')::interval END,
            completed_at = NULL
     RETURNING requested_at, scheduled_for`,
    [userId, String(graceDays)],
  );
  const result = { requestedAt: iso(rows[0].requested_at), scheduledFor: iso(rows[0].scheduled_for) };
  await schedule({ userId, scheduledFor: result.scheduledFor });
  log.warn({ userId, scheduledFor: result.scheduledFor }, 'account deletion requested');
  return result;
};

export const cancel = async ({ userId }) => {
  const { rowCount } = await pool.query(
    `DELETE FROM account_deletion_requests WHERE user_id = $1 AND completed_at IS NULL`,
    [userId],
  );
  if (rowCount > 0) log.warn({ userId }, 'account deletion cancelled');
  return rowCount > 0;
};

/** Runs a statement; a table or column this database does not have is skipped. */
const optional = async (client, sql, params) => {
  await client.query('SAVEPOINT optional_step');
  try {
    await client.query(sql, params);
    await client.query('RELEASE SAVEPOINT optional_step');
  } catch (cause) {
    await client.query('ROLLBACK TO SAVEPOINT optional_step');
    log.warn({ err: cause.message, sql: sql.split('\n')[0] }, 'deletion step skipped');
  }
};

const anonymise = async (userId) => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const { rows } = await client.query(
      `SELECT 1 FROM account_deletion_requests
        WHERE user_id = $1 AND completed_at IS NULL AND scheduled_for <= now()
        FOR UPDATE`,
      [userId],
    );
    if (!rows[0]) {
      await client.query('ROLLBACK');
      return false;
    }

    await client.query(
      `UPDATE users
          SET email = 'deleted+' || id || '@invalid',
              password_hash = NULL,
              display_name = 'Deleted user',
              status = 'deleted',
              email_verified_at = NULL,
              deleted_at = now(),
              updated_at = now()
        WHERE id = $1`,
      [userId],
    );
    await optional(
      client,
      `UPDATE profiles
          SET handle = 'deleted_' || substr(replace(user_id::text, '-', ''), 1, 12),
              headline = NULL, bio = NULL, links = '[]'::jsonb, avatar_asset_id = NULL,
              preferences = '{}'::jsonb, visibility = 'private', dm_policy = 'nobody',
              show_presence = false, updated_at = now()
        WHERE user_id = $1`,
      [userId],
    );
    for (const sql of [
      `DELETE FROM notification_preferences WHERE user_id = $1`,
      `DELETE FROM notifications WHERE user_id = $1`,
      `DELETE FROM web_push_subscriptions WHERE user_id = $1`,
      `DELETE FROM user_totp WHERE user_id = $1`,
      `DELETE FROM user_recovery_codes WHERE user_id = $1`,
      `DELETE FROM user_passkeys WHERE user_id = $1`,
      `DELETE FROM blocks WHERE user_id = $1 OR blocked_id = $1`,
      `DELETE FROM chat_mutes WHERE user_id = $1`,
      `DELETE FROM devices WHERE user_id = $1`,
      `DELETE FROM calendar_feed_tokens WHERE user_id = $1`,
      `UPDATE conversation_participants SET left_at = coalesce(left_at, now()) WHERE user_id = $1`,
      `DELETE FROM space_memberships WHERE user_id = $1`,
    ]) {
      await optional(client, sql, [userId]);
    }
    await client.query(
      `UPDATE account_deletion_requests SET completed_at = now() WHERE user_id = $1`,
      [userId],
    );
    await client.query('COMMIT');
  } catch (cause) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw cause;
  } finally {
    client.release();
  }

  // Sessions live in Redis: end them after the database agrees.
  try {
    const Sessions = await import('./SessionStore.js');
    await Sessions.revokeAllForUser({ userId, reason: 'account-deleted' });
  } catch (cause) {
    log.warn({ err: cause, userId }, 'sessions not revoked after deletion');
  }
  log.warn({ userId }, 'account anonymised');
  return true;
};

/**
 * Anonymises every account whose grace period is over. Called by the worker
 * for each scheduled job, and it sweeps all due requests, so a job lost in a
 * Redis flush is caught by the next one.
 */
export const runDue = async ({ limit = 50 } = {}) => {
  const { rows } = await pool.query(
    `SELECT user_id FROM account_deletion_requests
      WHERE completed_at IS NULL AND scheduled_for <= now()
      ORDER BY scheduled_for LIMIT $1`,
    [limit],
  );
  let deleted = 0;
  for (const row of rows) {
    try {
      if (await anonymise(row.user_id)) deleted += 1;
    } catch (cause) {
      log.error({ err: cause, userId: row.user_id }, 'account deletion failed; the next run retries');
    }
  }
  return { due: rows.length, deleted };
};

export default { status, request, cancel, runDue, GRACE_DAYS };
