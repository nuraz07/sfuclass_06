// classroom-app/server/src/community/NotificationService.js
/**
 * Notifications  (F2, F5, F6 · Settings Phase B)
 *
 * The one place that knows a person's notification settings, writes the bell
 * (in-app) entries and prepares everything the notification worker delivers.
 * Every caller in the platform goes through here rather than reaching for SNS,
 * SES or the socket directly — that is what makes one set of settings apply
 * everywhere.
 *
 * Phase B:
 *
 *   - settings have real storage (notification_preferences, 004 + 022); the
 *     rules that apply them are settings/notifications.js
 *   - the bell table is written with its real columns (kind, url); the output
 *     keeps the names clients already read (type, href)
 *   - notify() and notifyMany() hand everything to the worker's
 *     'notification.fanout' job, which decides per person, so a notification
 *     queued an hour ago is judged by the settings of now
 *   - a new bell entry reaches the person's open tabs at once
 *     ('notification:new', via realtime/userEvents.js)
 */

import { pool } from '../db/pool.js';
import { logger } from '../observability/logger.js';
import * as Rules from '../settings/notifications.js';
import { pushToUser } from '../realtime/userEvents.js';

const log = logger.child({ component: 'notifications' });

const iso = (value) => (value ? new Date(value).toISOString() : null);

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

const CONTEXT_SQL = `
  SELECT u.id, u.email, u.display_name, u.time_zone, u.role, u.status,
         np.user_id AS preferences_user_id, np.channels, np.digest,
         np.quiet_start, np.quiet_end, np.quiet_enabled, np.quiet_allow_lessons,
         np.focus_in_lessons, np.show_previews, np.email_suppressed_at
    FROM users u
    LEFT JOIN notification_preferences np ON np.user_id = u.id
   WHERE u.id = $1 AND u.deleted_at IS NULL
`;

/**
 * Everything delivery needs about one person, in one query.
 * @returns {Promise<null | { userId, email, displayName, timeZone, role, active, emailSuppressed, settings }>}
 */
export const getDeliveryContext = async (userId) => {
  const { rows } = await pool.query(CONTEXT_SQL, [userId]);
  const row = rows[0];
  if (!row) return null;
  return {
    userId: row.id,
    email: row.email ?? null,
    displayName: row.display_name ?? null,
    timeZone: row.time_zone || 'UTC',
    role: row.role,
    active: row.status === 'active',
    emailSuppressed: Boolean(row.email_suppressed_at),
    settings: Rules.fromRow(row.preferences_user_id ? row : null),
  };
};

export const getSettings = async (userId) => (await getDeliveryContext(userId))?.settings ?? Rules.fromRow(null);

/** v6 name, still used by older callers. */
export const getPreferences = getSettings;

/**
 * Validates one change, merges it into what is stored and returns the full
 * settings. Throws with code 'validation_failed' for anything invalid.
 */
export const updateSettings = async ({ userId, patch }) => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const { rows } = await client.query(
      `SELECT * FROM notification_preferences WHERE user_id = $1 FOR UPDATE`,
      [userId],
    );
    const next = Rules.mergeNotificationPatch(Rules.fromRow(rows[0] ?? null), patch);
    const row = Rules.toRow(next);

    await client.query(
      `INSERT INTO notification_preferences
         (user_id, digest, channels, quiet_start, quiet_end, quiet_enabled,
          quiet_allow_lessons, focus_in_lessons, show_previews, updated_at)
       VALUES ($1, $2, $3::jsonb, $4::time, $5::time, $6, $7, $8, $9, now())
       ON CONFLICT (user_id) DO UPDATE
          SET digest = EXCLUDED.digest,
              channels = EXCLUDED.channels,
              quiet_start = EXCLUDED.quiet_start,
              quiet_end = EXCLUDED.quiet_end,
              quiet_enabled = EXCLUDED.quiet_enabled,
              quiet_allow_lessons = EXCLUDED.quiet_allow_lessons,
              focus_in_lessons = EXCLUDED.focus_in_lessons,
              show_previews = EXCLUDED.show_previews,
              updated_at = now()`,
      [
        userId,
        row.digest,
        JSON.stringify(row.channels),
        row.quiet_start,
        row.quiet_end,
        row.quiet_enabled,
        row.quiet_allow_lessons,
        row.focus_in_lessons,
        row.show_previews,
      ],
    );
    await client.query('COMMIT');
    return next;
  } catch (cause) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw cause;
  } finally {
    client.release();
  }
};

/**
 * v6 pure rule, kept for callers and tests that still import it. The rule that
 * is applied is settings/notifications.js#decide.
 */
export const decideChannels = ({
  type,
  settings,
  presence = { state: 'offline' },
  actorIsRecipient = false,
  now = new Date(),
  timeZone = 'UTC',
}) => {
  if (actorIsRecipient) {
    return { inApp: false, push: false, email: false, delayMinutes: 0, reason: 'own action' };
  }
  const decision = Rules.decide({ kind: type, settings, presence: presence?.state ?? 'offline', now, timeZone });
  return {
    inApp: decision.channels.includes('inApp'),
    push: decision.channels.includes('push'),
    email: decision.channels.includes('email'),
    delayMinutes: 0,
    reason: decision.reason ?? undefined,
  };
};

// ---------------------------------------------------------------------------
// The bell
// ---------------------------------------------------------------------------

const toNotification = (row) => ({
  notificationId: row.id,
  type: row.kind,
  kind: row.kind,
  actor: row.actor_id
    ? { userId: row.actor_id, displayName: row.actor_name ?? null, avatarUrl: null }
    : null,
  title: row.title,
  body: row.body ?? null,
  href: row.url ?? null,
  url: row.url ?? null,
  readAt: iso(row.read_at),
  createdAt: iso(row.created_at),
});

/**
 * Writes one bell entry and tells the person's open tabs. Called by the
 * worker after the rules said "in the app", and by "Send test notification".
 */
export const createInApp = async ({ userId, kind, title, body = null, url = null, actorId = null, data = {} }) => {
  const { rows } = await pool.query(
    `INSERT INTO notifications (user_id, kind, title, body, url, actor_id, data)
     VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb)
     RETURNING id, kind, title, body, url, actor_id, read_at, created_at`,
    [userId, kind, title, body, url, actorId, JSON.stringify(data ?? {})],
  );
  const notification = toNotification(rows[0]);
  const unread = await unreadCount(userId).catch(() => null);

  await pushToUser(userId, 'notification:new', { notification, unread });
  // The name the community bell listened for before Phase B.
  await pushToUser(userId, 'community:notification', { notification, unread });
  return notification;
};

export const list = async ({ userId, cursor = null, limit = 25, unreadOnly = false }) => {
  const params = [userId];
  let where = 'n.user_id = $1';

  if (unreadOnly) where += ' AND n.read_at IS NULL';
  if (cursor) {
    const [at, id] = Buffer.from(cursor, 'base64url').toString().split('|');
    params.push(at, id);
    where += ` AND (n.created_at, n.id) < ($${params.length - 1}::timestamptz, $${params.length}::uuid)`;
  }
  params.push(limit + 1);

  const { rows } = await pool.query(
    `SELECT n.*, u.display_name AS actor_name
       FROM notifications n LEFT JOIN users u ON u.id = n.actor_id
      WHERE ${where}
      ORDER BY n.created_at DESC, n.id DESC
      LIMIT $${params.length}`,
    params,
  );

  const hasMore = rows.length > limit;
  const page = rows.slice(0, limit);
  const last = page.at(-1);

  return {
    items: page.map(toNotification),
    hasMore,
    nextCursor:
      hasMore && last
        ? Buffer.from(`${new Date(last.created_at).toISOString()}|${last.id}`).toString('base64url')
        : null,
  };
};

export const unreadCount = async (userId) => {
  const { rows } = await pool.query(
    `SELECT count(*)::int AS unread FROM notifications WHERE user_id = $1 AND read_at IS NULL`,
    [userId],
  );
  return rows[0].unread;
};

/** No ids means everything. */
export const markRead = async ({ userId, notificationIds = [] }) => {
  const { rowCount } = await pool.query(
    `UPDATE notifications SET read_at = now()
      WHERE user_id = $1 AND read_at IS NULL
        AND ($2::uuid[] IS NULL OR cardinality($2::uuid[]) = 0 OR id = ANY($2::uuid[]))`,
    [userId, notificationIds],
  );
  return rowCount;
};

// ---------------------------------------------------------------------------
// Sending (through the worker)
// ---------------------------------------------------------------------------

const enqueueFanout = async (payload) => {
  try {
    const queues = await import('../queues/queues.js');
    if (typeof queues.enqueueNotification === 'function') {
      await queues.enqueueNotification('notification.fanout', payload);
    } else {
      await queues.enqueue(queues.QUEUE_NAMES.NOTIFY, 'notification.fanout', payload);
    }
  } catch (cause) {
    log.error({ err: cause, kind: payload.kind }, 'could not queue a notification');
  }
};

/**
 * One person. Queued: the worker applies the settings, presence and quiet
 * hours at delivery time.
 *
 * @param {{ userId: string, type: string, title: string, body?: string, href?: string,
 *           actorId?: string|null, data?: object, dedupeKey?: string }} input
 */
export const notify = async ({ userId, type, title, body = null, href = null, actorId = null, data = {}, dedupeKey }) => {
  if (!userId || !type) return { queued: 0 };
  await enqueueFanout({ kind: type, recipientIds: [userId], title, body, url: href, actorId, data, dedupeKey });
  return { queued: 1 };
};

/** Many people, one job. */
export const notifyMany = async ({ userIds = [], type, kind, title, body = null, href = null, url = null, actorId = null, data = {}, dedupeKey }) => {
  const recipients = [...new Set(userIds)].filter(Boolean);
  if (recipients.length === 0) return { queued: 0 };
  await enqueueFanout({
    kind: kind ?? type,
    recipientIds: recipients,
    title,
    body,
    url: url ?? href,
    actorId,
    data,
    dedupeKey,
  });
  return { queued: recipients.length };
};

// ---------------------------------------------------------------------------
// Email helpers for the worker
// ---------------------------------------------------------------------------

export const emailRecipient = async (userId) => {
  const context = await getDeliveryContext(userId);
  if (!context) return null;
  return {
    userId: context.userId,
    email: context.email,
    displayName: context.displayName,
    suppressed: context.emailSuppressed,
    timeZone: context.timeZone,
  };
};

export const renderEmail = async ({ title, body, url, recipient, actionLabel }) => {
  const { renderEmail: render } = await import('../notifications/delivery.js');
  return render({ title, body, url, recipientName: recipient?.displayName ?? null, actionLabel });
};

/**
 * The community digest: unread community notifications since the last one.
 * Daily by default; weekly sends on Mondays (UTC); off sends nothing.
 */
export const buildDigest = async ({ userId, date = null }) => {
  const context = await getDeliveryContext(userId);
  if (!context?.active) return null;
  const { digest } = context.settings;
  if (digest === 'off') return null;

  const today = date ? new Date(date) : new Date();
  if (digest === 'weekly' && today.getUTCDay() !== 1) return null;
  const days = digest === 'weekly' ? 7 : 1;

  const { rows } = await pool.query(
    `SELECT id, kind, title, body, url, created_at
       FROM notifications
      WHERE user_id = $1 AND read_at IS NULL
        AND created_at > $2::timestamptz - ($3 || ' days')::interval
      ORDER BY created_at DESC
      LIMIT 50`,
    [userId, today.toISOString(), String(days)],
  );
  const items = rows.filter((row) => Rules.categoryOf(row.kind) === 'community');
  if (items.length === 0) return { items: [] };

  const lines = items.slice(0, 10).map((row) => `• ${row.title}${row.body ? ` — ${row.body}` : ''}`);
  if (items.length > 10) lines.push(`…and ${items.length - 10} more`);

  return {
    items,
    subject: `Your community ${digest === 'weekly' ? 'week' : 'day'}: ${items.length} update${items.length === 1 ? '' : 's'}`,
    summary: lines.join('\n'),
    url: '/community',
  };
};

// ---------------------------------------------------------------------------
// Muted chats (Settings → Notifications)
// ---------------------------------------------------------------------------

/** Every chat this person has muted right now, with when the mute ends. */
export const mutedChats = async (userId) => {
  const [conversations, channels] = await Promise.all([
    pool.query(
      `SELECT cp.conversation_id, c.kind, c.title, cp.muted_until,
              (SELECT string_agg(u.display_name, ', ' ORDER BY u.display_name)
                 FROM conversation_participants o
                 JOIN users u ON u.id = o.user_id
                WHERE o.conversation_id = cp.conversation_id
                  AND o.user_id <> $1 AND o.left_at IS NULL) AS others
         FROM conversation_participants cp
         JOIN conversations c ON c.id = cp.conversation_id
        WHERE cp.user_id = $1 AND cp.left_at IS NULL AND cp.muted
          AND (cp.muted_until IS NULL OR cp.muted_until > now())
        ORDER BY cp.muted_until NULLS FIRST`,
      [userId],
    ),
    pool
      .query(
        `SELECT cm.channel_id, ch.name, cm.muted_until
           FROM channel_members cm
           JOIN channels ch ON ch.channel_id = cm.channel_id
          WHERE cm.user_id = $1 AND cm.muted AND ch.archived_at IS NULL
            AND (cm.muted_until IS NULL OR cm.muted_until > now())
          ORDER BY cm.muted_until NULLS FIRST`,
        [userId],
      )
      .catch((cause) => {
        log.warn({ err: cause }, 'muted channels unavailable');
        return { rows: [] };
      }),
  ]);

  return {
    items: [
      ...channels.rows.map((row) => ({
        kind: 'channel',
        id: row.channel_id,
        title: `# ${row.name}`,
        mutedUntil: iso(row.muted_until),
      })),
      ...conversations.rows.map((row) => ({
        kind: 'conversation',
        id: row.conversation_id,
        title: row.kind === 'group' ? row.title || row.others || 'Group chat' : row.others || 'Private chat',
        mutedUntil: iso(row.muted_until),
      })),
    ],
  };
};

// ---------------------------------------------------------------------------
// Domain helpers
// ---------------------------------------------------------------------------

/** Called by LiveSessionLink when a room opens. */
export const notifyLessonStarted = async ({ lessonId }) => {
  const { rows } = await pool.query(
    `SELECT l.title, c.title AS course_title, c.slug, e.user_id
       FROM lessons l
       JOIN modules m ON m.id = l.module_id
       JOIN courses c ON c.id = m.course_id
       JOIN enrollments e ON e.course_id = c.id AND e.status = 'active'
      WHERE l.id = $1`,
    [lessonId],
  );
  if (rows.length === 0) return { queued: 0 };

  return notifyMany({
    userIds: rows.map((row) => row.user_id),
    type: 'lesson.starting',
    title: `${rows[0].title} is starting`,
    body: rows[0].course_title,
    href: `/lessons/${lessonId}/live`,
    data: { lessonId },
    dedupeKey: `lesson-starting:${lessonId}`,
  });
};

/** Called by LiveSessionLink when a recording finishes processing. */
export const notifyRecordingReady = async ({ lessonId, assetId }) => {
  const { rows } = await pool.query(
    `SELECT l.title, c.slug, e.user_id
       FROM lessons l
       JOIN modules m ON m.id = l.module_id
       JOIN courses c ON c.id = m.course_id
       JOIN enrollments e ON e.course_id = c.id AND e.status = 'active'
      WHERE l.id = $1`,
    [lessonId],
  );
  if (rows.length === 0) return { queued: 0 };

  return notifyMany({
    userIds: rows.map((row) => row.user_id),
    type: 'asset.ready',
    title: `The recording of ${rows[0].title} is ready`,
    href: `/courses/${rows[0].slug}/lessons/${lessonId}`,
    data: { lessonId, assetId },
  });
};

/** Called when someone replies in a thread. */
export const notifyThreadReply = async ({ threadId, actorId, excerpt }) => {
  const Threads = await import('./models/Thread.js');
  const [thread, watchers] = await Promise.all([
    Threads.findById(threadId),
    Threads.followers(threadId, actorId),
  ]);
  if (!thread || watchers.length === 0) return { queued: 0 };

  return notifyMany({
    userIds: watchers,
    type: 'thread.reply',
    title: `New reply in “${thread.title}”`,
    body: excerpt,
    href: `/community/threads/${threadId}`,
    actorId,
    data: { threadId },
  });
};

export default {
  getDeliveryContext,
  getSettings,
  getPreferences,
  updateSettings,
  decideChannels,
  createInApp,
  list,
  unreadCount,
  markRead,
  notify,
  notifyMany,
  emailRecipient,
  renderEmail,
  buildDigest,
  mutedChats,
  notifyLessonStarted,
  notifyRecordingReady,
  notifyThreadReply,
};
