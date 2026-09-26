// classroom-app/server/src/identity/dataExport.js
/**
 * "Download your data"  (Settings, Phase C)
 *
 * Everything the platform keeps about one person, as one JSON document they
 * can read and take elsewhere: the account, the profile and every setting,
 * signed-in devices and history, what they wrote in chats and the community,
 * courses, progress, submissions and notifications.
 *
 * Tables are read by whichever column names the person in them (user_id,
 * author_id, …), looked up in the catalogue rather than assumed, so a table
 * that changes shape still exports — and one that does not exist is listed
 * as unavailable instead of failing the whole download. Secrets never leave
 * (security/exportSanitize.js).
 */

import { pool } from '../db/pool.js';
import { logger } from '../observability/logger.js';
import { stripSensitive } from '../security/exportSanitize.js';

const log = logger.child({ component: 'data-export' });

const ROW_LIMIT = 20_000;

/** Tables, and the columns that point at the person, in order of preference. */
const TABLES = [
  ['messages', ['author_id']],
  ['conversation_participants', ['user_id']],
  ['channel_participants', ['user_id']],
  ['message_receipts', ['user_id']],
  ['threads', ['author_id', 'user_id', 'created_by']],
  ['posts', ['author_id', 'user_id']],
  ['post_reactions', ['user_id']],
  ['space_memberships', ['user_id']],
  ['enrollments', ['user_id']],
  ['lesson_progress', ['user_id']],
  ['course_progress', ['user_id']],
  ['certificates', ['user_id']],
  ['submissions', ['user_id', 'learner_id', 'student_id']],
  ['grades', ['user_id', 'learner_id', 'student_id']],
  ['assets', ['owner_id', 'user_id', 'uploaded_by']],
  ['scheduled_sessions', ['host_id', 'created_by']],
  ['session_invitees', ['user_id']],
  ['notifications', ['user_id']],
  ['notification_preferences', ['user_id']],
  ['blocks', ['user_id']],
  ['chat_mutes', ['user_id']],
  ['web_push_subscriptions', ['user_id']],
  ['devices', ['user_id']],
  ['user_passkeys', ['user_id']],
];

const columnsOf = async () => {
  const { rows } = await pool.query(
    `SELECT table_name, column_name FROM information_schema.columns
      WHERE table_schema = current_schema() AND table_name = ANY($1::text[])`,
    [TABLES.map(([name]) => name)],
  );
  const map = new Map();
  for (const row of rows) {
    if (!map.has(row.table_name)) map.set(row.table_name, new Set());
    map.get(row.table_name).add(row.column_name);
  }
  return map;
};

const readTable = async (table, candidates, columns, userId) => {
  const present = columns.get(table);
  if (!present) return { unavailable: 'not in this database' };
  const owner = candidates.find((column) => present.has(column));
  if (!owner) return { unavailable: 'no column names a person' };
  const order = present.has('created_at') ? ' ORDER BY created_at' : '';
  try {
    // Identifiers come from the catalogue above, never from a request.
    const { rows } = await pool.query(
      `SELECT * FROM "${table}" WHERE "${owner}" = $1${order} LIMIT ${ROW_LIMIT + 1}`,
      [userId],
    );
    return {
      rows: rows.slice(0, ROW_LIMIT).map(stripSensitive),
      truncated: rows.length > ROW_LIMIT,
    };
  } catch (cause) {
    log.warn({ err: cause, table }, 'export: table not read');
    return { unavailable: 'could not be read' };
  }
};

/**
 * @param {{ userId: string }} input
 * @returns {Promise<object>} the document, ready for JSON.stringify
 */
export const buildExport = async ({ userId }) => {
  const Users = await import('./User.js');
  const account = await Users.findById(userId);
  if (!account) throw Object.assign(new Error('No account'), { code: 'not_found' });

  const [profileRows, settings, security, sessions, history, columns] = await Promise.all([
    pool.query(`SELECT * FROM profiles WHERE user_id = $1`, [userId]),
    import('../community/NotificationService.js').then((m) => m.getSettings(userId)).catch(() => null),
    import('./secondFactor.js').then((m) => m.status(userId)).catch(() => null),
    import('./deviceSessions.js').then((m) => m.list(userId)).catch(() => []),
    pool
      .query(
        `SELECT action, metadata, host(ip) AS ip, user_agent, created_at
           FROM audit_log WHERE actor_id = $1 ORDER BY id DESC LIMIT 1000`,
        [userId],
      )
      .then((result) => result.rows.map(stripSensitive))
      .catch(() => []),
    columnsOf(),
  ]);

  const data = {};
  for (const [table, candidates] of TABLES) {
    data[table] = await readTable(table, candidates, columns, userId);
  }

  return {
    format: 'classroom-export/1',
    exportedAt: new Date().toISOString(),
    note: 'Everything Classroom keeps about your account. Passwords, keys and secrets are never included.',
    account,
    profile: profileRows.rows[0] ? stripSensitive(profileRows.rows[0]) : null,
    notificationSettings: settings,
    twoStepSignIn: security
      ? {
          authenticatorApp: security.totp.enabled,
          recoveryCodesRemaining: security.recoveryCodesRemaining,
          passkeys: security.passkeyCount,
        }
      : null,
    signedInDevices: sessions,
    history,
    data,
  };
};

export default buildExport;
