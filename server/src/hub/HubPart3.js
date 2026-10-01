// classroom-app/server/src/hub/HubPart3.js
/**
 * Community, part 3  (Community)
 *
 *   study partners   opt in with subjects and free times; suggestions say why
 *                    ("both in Year 7 maths, both free Tuesday evenings");
 *                    nothing is shared until both agree; then "study
 *                    together now" opens a room for the two of you
 *   late-night nudge a reply, thread or chat message written late at night
 *                    can wait until 8:00 in the writer's time zone
 *   calm mode        moderators slow a heated thread or chat to one message
 *                    per person every few minutes, instead of locking it
 *   per-space mode   each / daily summary / off
 *   daily summary    one notification at 17:00 local time for "daily" spaces
 *   space log        what moderators did, for moderators to see
 *
 * The scheduler (sending morning posts, the summaries) runs once a minute in
 * the API process, guarded by a Redis lock so several API instances never do
 * the same work twice.
 */

import { pool } from '../db/pool.js';
import { logger } from '../observability/logger.js';
import * as Rules from './hubRules.js';
import * as P from './partRules.js';
import * as Hub from './HubService.js';

const log = logger.child({ component: 'community-part3' });
const { loadSpace, loadThread, notify, notBlocked, iso, fail, logAction } = Hub.internals;

// ---------------------------------------------------------------------------
// Study partners
// ---------------------------------------------------------------------------

const toProfile = (row) =>
  row
    ? {
        exists: true,
        active: row.active,
        subjects: row.subjects ?? [],
        availability: row.availability ?? [],
        note: row.note ?? null,
        updatedAt: iso(row.updated_at),
      }
    : { exists: false, active: false, subjects: [], availability: [], note: null, updatedAt: null };

export const getStudyProfile = async ({ viewer }) => {
  const { rows } = await pool.query(`SELECT * FROM study_profiles WHERE user_id = $1`, [viewer.userId]);
  return toProfile(rows[0]);
};

export const saveStudyProfile = async ({ viewer, input }) => {
  const { rows } = await pool.query(
    `INSERT INTO study_profiles (user_id, tenant_id, active, subjects, availability, note, updated_at)
     VALUES ($1, $2, $3, $4, $5, $6, now())
     ON CONFLICT (user_id) DO UPDATE SET active = EXCLUDED.active, subjects = EXCLUDED.subjects,
       availability = EXCLUDED.availability, note = EXCLUDED.note, updated_at = now()
     RETURNING *`,
    [viewer.userId, viewer.tenantId, input.active, [...new Set(input.subjects)], [...new Set(input.availability)], input.note ?? null],
  );
  return toProfile(rows[0]);
};

/** Suggestions only for people who opted in themselves, and only among people who opted in. */
export const studySuggestions = async ({ viewer }) => {
  const me = await getStudyProfile({ viewer });
  if (!me.exists || !me.active) return { items: [], needsProfile: true };
  const { rows } = await pool.query(
    `SELECT sp.user_id, sp.subjects, sp.availability, sp.note, u.display_name,
            ARRAY(SELECT s.name FROM space_memberships a
                    JOIN space_memberships b ON b.space_id = a.space_id
                    JOIN spaces s ON s.id = a.space_id
                   WHERE a.user_id = $1 AND b.user_id = sp.user_id AND s.archived_at IS NULL
                   ORDER BY s.name LIMIT 5) AS shared
       FROM study_profiles sp JOIN users u ON u.id = sp.user_id
      WHERE sp.tenant_id = $2 AND sp.active AND sp.user_id <> $1 AND u.deleted_at IS NULL
        AND ${notBlocked('sp.user_id', '$1')}
        AND NOT EXISTS (SELECT 1 FROM study_requests r
                         WHERE (r.requester_id = $1 AND r.target_id = sp.user_id)
                            OR (r.requester_id = sp.user_id AND r.target_id = $1))
      LIMIT 300`,
    [viewer.userId, viewer.tenantId],
  );
  const items = rows
    .map((row) => {
      const match = P.scoreMatch({ me, other: { subjects: row.subjects ?? [], availability: row.availability ?? [] }, sharedSpaces: row.shared ?? [] });
      return match
        ? { userId: row.user_id, displayName: row.display_name, note: row.note ?? null, reasons: match.reasons, score: match.score, sharedTimes: match.sharedTimes }
        : null;
    })
    .filter(Boolean)
    .sort((a, b) => b.score - a.score || a.displayName.localeCompare(b.displayName))
    .slice(0, 12)
    .map(({ score, ...rest }) => rest);
  return { items, needsProfile: false };
};

export const requestPartner = async ({ viewer, targetId, message = null }) => {
  if (targetId === viewer.userId) fail('validation_failed', 'That is you.');
  const me = await getStudyProfile({ viewer });
  if (!me.active) fail('forbidden', 'Turn on your study profile first.');
  const { rows } = await pool.query(
    `SELECT u.id FROM users u JOIN study_profiles sp ON sp.user_id = u.id AND sp.active
      WHERE u.id = $1 AND u.tenant_id = $2 AND u.deleted_at IS NULL AND ${notBlocked('u.id', '$3')}`,
    [targetId, viewer.tenantId, viewer.userId],
  );
  if (!rows[0]) fail('not_found', 'This person is not looking for study partners.');
  const { rowCount } = await pool.query(
    `INSERT INTO study_requests (requester_id, target_id, message) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING`,
    [viewer.userId, targetId, message],
  );
  if (rowCount === 0) fail('conflict', 'You already asked this person.');
  await notify({
    userIds: [targetId],
    type: 'study.request',
    title: `${viewer.displayName} would like to study together`,
    body: message ?? null,
    href: '/community?tab=partners',
    actorId: viewer.userId,
    data: {},
  });
  return { requested: true };
};

export const respondPartner = async ({ viewer, requesterId, accept }) => {
  const { rowCount } = await pool.query(
    `UPDATE study_requests SET status = $3, decided_at = now()
      WHERE requester_id = $1 AND target_id = $2 AND status = 'pending'`,
    [requesterId, viewer.userId, accept ? 'accepted' : 'declined'],
  );
  if (rowCount === 0) fail('not_found', 'No open request from this person.');
  if (accept) {
    await notify({
      userIds: [requesterId],
      type: 'study.accepted',
      title: `${viewer.displayName} said yes to studying together`,
      href: '/community?tab=partners',
      actorId: viewer.userId,
      data: {},
    });
  }
  return { decided: true };
};

/** Partners, requests for me, requests I sent. A declined request just stays "sent" for the asker. */
export const partners = async ({ viewer }) => {
  const { rows } = await pool.query(
    `SELECT r.*, ru.display_name AS requester_name, tu.display_name AS target_name,
            rp.availability AS requester_times, tp.availability AS target_times
       FROM study_requests r
       JOIN users ru ON ru.id = r.requester_id
       JOIN users tu ON tu.id = r.target_id
       LEFT JOIN study_profiles rp ON rp.user_id = r.requester_id
       LEFT JOIN study_profiles tp ON tp.user_id = r.target_id
      WHERE (r.requester_id = $1 OR r.target_id = $1) AND r.status IN ('pending', 'accepted', 'declined')
        AND ru.deleted_at IS NULL AND tu.deleted_at IS NULL
      ORDER BY coalesce(r.decided_at, r.created_at) DESC`,
    [viewer.userId],
  );
  const accepted = [];
  const incoming = [];
  const outgoing = [];
  for (const row of rows) {
    const mineSent = row.requester_id === viewer.userId;
    const other = mineSent
      ? { userId: row.target_id, displayName: row.target_name }
      : { userId: row.requester_id, displayName: row.requester_name };
    if (row.status === 'accepted') {
      const times = (row.requester_times ?? []).filter((slot) => (row.target_times ?? []).includes(slot));
      accepted.push({ ...other, since: iso(row.decided_at), sharedTimes: times.map(P.slotLabel) });
    } else if (row.status === 'pending' && !mineSent) {
      incoming.push({ ...other, message: row.message ?? null, at: iso(row.created_at) });
    } else if (mineSent) {
      outgoing.push({ ...other, at: iso(row.created_at) });
    }
  }
  return { partners: accepted, incoming, outgoing };
};

const assertPartners = async (viewer, otherId) => {
  const { rows } = await pool.query(
    `SELECT 1 FROM study_requests WHERE status = 'accepted'
        AND ((requester_id = $1 AND target_id = $2) OR (requester_id = $2 AND target_id = $1))`,
    [viewer.userId, otherId],
  );
  if (!rows[0]) fail('forbidden', 'You are not study partners.');
};

export const endPartnership = async ({ viewer, otherId }) => {
  await pool.query(
    `UPDATE study_requests SET status = 'ended', decided_at = now()
      WHERE (requester_id = $1 AND target_id = $2) OR (requester_id = $2 AND target_id = $1)`,
    [viewer.userId, otherId],
  );
  return { ended: true };
};

/** A room for two, now, for an hour — with the rooms feature's doors and lobby. */
export const studyNow = async ({ viewer, otherId }) => {
  await assertPartners(viewer, otherId);
  const { rows: zone } = await pool.query(`SELECT time_zone FROM users WHERE id = $1`, [viewer.userId]);
  const timeZone = zone[0]?.time_zone || 'UTC';
  const { localNow } = await import('./HubExtras.js');
  const { rows: names } = await pool.query(`SELECT display_name FROM users WHERE id = $1`, [otherId]);
  const Rooms = await import('../rooms/ScheduledRooms.js');
  let created;
  try {
    [created] = await Rooms.create({
      tenantId: viewer.tenantId,
      hostId: viewer.userId,
      input: {
        title: `Study session: ${viewer.displayName} and ${names[0]?.display_name ?? 'partner'}`,
        description: null,
        startsAtLocal: localNow(timeZone),
        durationMinutes: 60,
        timeZone,
        earlyEntryMinutes: 3,
        lateJoinMinutes: null,
        capacity: 2,
        access: 'invited',
        approval: false,
        inviteeIds: [otherId],
        cohostIds: [otherId],
        settings: { learnersJoinMuted: false, reactionsEnabled: true, learnersMayShare: true },
        recurrence: null,
      },
    });
  } catch (cause) {
    if (cause?.code === 'conflict') fail('conflict', 'You already have a room at this time.');
    throw cause;
  }
  const { rows } = await pool.query(`SELECT room_code FROM scheduled_sessions WHERE id = $1`, [created.id]);
  const code = rows[0].room_code;
  await notify({
    userIds: [otherId],
    type: 'study.room',
    title: `${viewer.displayName} opened a study room for you two`,
    href: `/rooms/${code}/lobby`,
    actorId: viewer.userId,
    data: { roomCode: code },
  });
  return { code };
};

// ---------------------------------------------------------------------------
// Late-night nudge: posts sent at 8:00
// ---------------------------------------------------------------------------

const timeZoneOf = async (userId) => {
  const { rows } = await pool.query(`SELECT time_zone FROM users WHERE id = $1`, [userId]);
  return rows[0]?.time_zone || 'UTC';
};

const describe = (row) => {
  const payload = row.payload ?? {};
  const text = payload.title ?? payload.body ?? '';
  return Rules.excerpt(text, 90);
};

export const schedulePost = async ({ viewer, input }) => {
  // Check now that it could be posted, so nobody waits until morning for a "no".
  if (input.kind === 'reply') {
    const { space, membership } = await loadThread(viewer, input.targetId);
    const blocked = Rules.postingBlockedBecause(space, membership);
    if (blocked) fail('forbidden', blocked);
  } else {
    const { space, membership } = await loadSpace(viewer, input.targetId);
    const blocked = Rules.postingBlockedBecause(space, membership);
    if (blocked) fail('forbidden', blocked);
  }
  const sendAt = P.nextMorning(new Date(), await timeZoneOf(viewer.userId));
  const { kind, targetId, ...payload } = input;
  const { rows } = await pool.query(
    `INSERT INTO scheduled_posts (user_id, kind, target_id, payload, send_at) VALUES ($1, $2, $3, $4, $5) RETURNING *`,
    [viewer.userId, kind, targetId, JSON.stringify(payload), sendAt],
  );
  return { scheduledId: rows[0].id, kind, sendAt: iso(rows[0].send_at), preview: describe(rows[0]) };
};

export const listScheduled = async ({ viewer }) => {
  const { rows } = await pool.query(
    `SELECT * FROM scheduled_posts WHERE user_id = $1 AND status = 'pending' ORDER BY send_at, created_at LIMIT 50`,
    [viewer.userId],
  );
  return {
    items: rows.map((row) => ({ scheduledId: row.id, kind: row.kind, targetId: row.target_id, sendAt: iso(row.send_at), preview: describe(row) })),
  };
};

export const cancelScheduled = async ({ viewer, scheduledId }) => {
  const { rowCount } = await pool.query(
    `UPDATE scheduled_posts SET status = 'cancelled' WHERE id = $1 AND user_id = $2 AND status = 'pending'`,
    [scheduledId, viewer.userId],
  );
  if (rowCount === 0) fail('not_found', 'Nothing waiting with this id (it may have been sent already).');
  return { cancelled: true };
};

/** Sends what is due. Each row is claimed before it is sent, so no instance sends it twice. */
export const dispatchDue = async () => {
  const { rows } = await pool.query(
    `UPDATE scheduled_posts SET status = 'sent', sent_at = now()
      WHERE id IN (SELECT id FROM scheduled_posts WHERE status = 'pending' AND send_at <= now()
                   ORDER BY send_at LIMIT 50 FOR UPDATE SKIP LOCKED)
      RETURNING *`,
  );
  for (const row of rows) {
    const payload = row.payload ?? {};
    try {
      const viewer = await Hub.viewerOf(row.user_id);
      if (row.kind === 'reply') {
        await Hub.reply({ viewer, threadId: row.target_id, input: { body: payload.body, hiddenSolution: Boolean(payload.hiddenSolution), replyToId: null } });
      } else if (row.kind === 'thread') {
        await Hub.createThread({
          viewer,
          spaceId: row.target_id,
          input: { title: payload.title, body: payload.body, kind: payload.threadKind ?? 'discussion', anonymous: Boolean(payload.anonymous) },
        });
      } else {
        const { sendMessage } = await import('./HubExtras.js');
        await sendMessage({ viewer, spaceId: row.target_id, input: { body: payload.body } });
      }
    } catch (cause) {
      await pool.query(`UPDATE scheduled_posts SET status = 'failed', error = $2 WHERE id = $1`, [row.id, String(cause?.message ?? cause).slice(0, 300)]);
      await notify({
        userIds: [row.user_id],
        type: 'space.scheduled_failed',
        title: 'A post you scheduled for this morning was not sent',
        body: String(cause?.message ?? 'It could not be posted.').slice(0, 140),
        href: '/community',
        data: { scheduledId: row.id },
      });
    }
  }
  return rows.length;
};

// ---------------------------------------------------------------------------
// Calm mode, notification mode, the log
// ---------------------------------------------------------------------------

const normaliseCalm = (seconds) => {
  const value = Number(seconds);
  if (!P.CALM_OPTIONS.includes(value)) fail('validation_failed', `Calm mode is one of ${P.CALM_OPTIONS.join(', ')} seconds.`);
  return value;
};

export const setThreadCalm = async ({ viewer, threadId, seconds }) => {
  const { thread, membership } = await loadThread(viewer, threadId);
  if (!Rules.isModerator(membership)) fail('forbidden', 'Only moderators change calm mode.');
  const value = normaliseCalm(seconds);
  await pool.query(`UPDATE threads SET slow_seconds = $2 WHERE id = $1`, [threadId, value]);
  await logAction(thread.space_id, viewer.userId, 'thread.calm', { targetType: 'thread', targetId: threadId, detail: { seconds: value, title: thread.title } });
  return Hub.getThread({ viewer, threadId });
};

export const setChatCalm = async ({ viewer, spaceId, seconds }) => {
  const { membership } = await loadSpace(viewer, spaceId);
  if (!Rules.isModerator(membership)) fail('forbidden', 'Only moderators change calm mode.');
  const value = normaliseCalm(seconds);
  await pool.query(`UPDATE spaces SET chat_slow_seconds = $2 WHERE id = $1`, [spaceId, value]);
  await logAction(spaceId, viewer.userId, 'chat.calm', { detail: { seconds: value } });
  return { chatSlowSeconds: value };
};

export const setNotifyMode = async ({ viewer, spaceId, mode }) => {
  if (!P.NOTIFY_MODES.includes(mode)) fail('validation_failed', 'each, daily or off');
  const { membership } = await loadSpace(viewer, spaceId);
  if (!membership) fail('forbidden', 'Join the space first.');
  await pool.query(`UPDATE space_memberships SET notify_mode = $3 WHERE space_id = $1 AND user_id = $2`, [spaceId, viewer.userId, mode]);
  return { notifyMode: mode };
};

export const listLog = async ({ viewer, spaceId }) => {
  const { membership } = await loadSpace(viewer, spaceId);
  if (!Rules.isModerator(membership)) fail('forbidden', 'Only moderators see the log.');
  const { rows } = await pool.query(
    `SELECT l.*, a.display_name AS actor_name, t.display_name AS target_name
       FROM space_log l
       LEFT JOIN users a ON a.id = l.actor_id
       LEFT JOIN users t ON l.target_type = 'user' AND t.id = l.target_id
      WHERE l.space_id = $1 ORDER BY l.created_at DESC LIMIT 200`,
    [spaceId],
  );
  return {
    items: rows.map((row) => ({
      entryId: row.id,
      action: row.action,
      label: P.LOG_LABELS[row.action] ?? row.action,
      actorName: row.actor_name ?? 'Someone',
      targetName: row.target_name ?? null,
      detail: row.detail ?? {},
      at: iso(row.created_at),
    })),
  };
};

// ---------------------------------------------------------------------------
// Daily summary
// ---------------------------------------------------------------------------

const localHour = (date, timeZone) => {
  try {
    return Number(new Intl.DateTimeFormat('en-US', { timeZone, hour: 'numeric', hourCycle: 'h23' }).format(date)) % 24;
  } catch {
    return date.getUTCHours();
  }
};

/** One person's summary over their "daily" spaces, or null when nothing happened. */
export const buildDigest = async (userId) => {
  const { rows } = await pool.query(
    `SELECT s.id, s.name,
            (SELECT count(*)::int FROM threads t WHERE t.space_id = s.id AND t.deleted_at IS NULL AND t.created_at > since) AS threads,
            (SELECT count(*)::int FROM threads t WHERE t.space_id = s.id AND t.deleted_at IS NULL AND t.kind = 'question'
               AND t.created_at > since AND t.answered_post_id IS NULL) AS open_questions,
            (SELECT count(*)::int FROM posts p JOIN threads t ON t.id = p.thread_id
              WHERE t.space_id = s.id AND p.deleted_at IS NULL AND p.created_at > since) AS posts,
            (SELECT count(*)::int FROM space_messages c WHERE c.space_id = s.id AND c.deleted_at IS NULL AND c.created_at > since) AS chat,
            (SELECT count(*)::int FROM scheduled_sessions r WHERE r.space_id = s.id AND r.status = 'scheduled'
               AND r.starts_at BETWEEN now() AND now() + interval '24 hours') AS rooms_soon
       FROM space_memberships m
       JOIN spaces s ON s.id = m.space_id AND s.archived_at IS NULL
       CROSS JOIN LATERAL (SELECT coalesce(m.last_digest_at, now() - interval '24 hours') AS since) w
      WHERE m.user_id = $1 AND m.notify_mode = 'daily'
      ORDER BY s.name`,
    [userId],
  );
  const lines = rows
    .map((row) => {
      const parts = [];
      if (row.threads) parts.push(`${row.threads} new ${row.threads === 1 ? 'thread' : 'threads'}${row.open_questions ? ` (${row.open_questions} open ${row.open_questions === 1 ? 'question' : 'questions'})` : ''}`);
      if (row.posts) parts.push(`${row.posts} ${row.posts === 1 ? 'post' : 'posts'}`);
      if (row.chat) parts.push(`${row.chat} chat ${row.chat === 1 ? 'message' : 'messages'}`);
      if (row.rooms_soon) parts.push(`${row.rooms_soon} ${row.rooms_soon === 1 ? 'room' : 'rooms'} in the next 24 hours`);
      return parts.length ? `${row.name}: ${parts.join(', ')}` : null;
    })
    .filter(Boolean);
  return lines.length ? { lines, spaces: rows.length } : null;
};

/** Sends summaries to people for whom it is 17:00 now and who had none in the last 20 hours. */
export const runDigests = async (now = new Date()) => {
  const { rows } = await pool.query(
    `SELECT DISTINCT m.user_id, u.time_zone
       FROM space_memberships m JOIN users u ON u.id = m.user_id AND u.deleted_at IS NULL
      WHERE m.notify_mode = 'daily' AND (m.last_digest_at IS NULL OR m.last_digest_at < now() - interval '20 hours')`,
  );
  let sent = 0;
  for (const row of rows) {
    if (localHour(now, row.time_zone || 'UTC') !== P.DIGEST_HOUR) continue;
    const digest = await buildDigest(row.user_id);
    await pool.query(`UPDATE space_memberships SET last_digest_at = now() WHERE user_id = $1 AND notify_mode = 'daily'`, [row.user_id]);
    if (!digest) continue;
    await notify({
      userIds: [row.user_id],
      type: 'space.digest',
      title: 'Your spaces today',
      body: digest.lines.slice(0, 6).join('\n'),
      href: '/community',
      data: {},
      dedupeKey: `space.digest:${row.user_id}:${now.toISOString().slice(0, 10)}`,
    });
    sent += 1;
  }
  return sent;
};

// ---------------------------------------------------------------------------
// Scheduler
// ---------------------------------------------------------------------------

let timer = null;

const tick = async () => {
  try {
    const { stateRedis } = await import('../db/redis.js');
    const { env } = await import('../config/env.js');
    const minute = Math.floor(Date.now() / 60_000);
    const got = await stateRedis.set(`${env.REDIS_PREFIX ?? ''}hub:tick:${minute}`, '1', 'EX', 55, 'NX');
    if (got !== 'OK') return;
  } catch (cause) {
    log.debug({ err: cause }, 'scheduler lock unavailable; skipping this minute');
    return;
  }
  try {
    const sent = await dispatchDue();
    if (sent) log.info({ sent }, 'morning posts sent');
    const digests = await runDigests();
    if (digests) log.info({ digests }, 'daily summaries sent');
  } catch (cause) {
    log.warn({ err: cause }, 'community scheduler tick failed');
  }
};

export const startHubScheduler = () => {
  if (timer || process.env.NODE_ENV === 'test') return;
  timer = setInterval(tick, 60_000);
  timer.unref?.();
  log.info('community scheduler started');
};

export default {
  getStudyProfile, saveStudyProfile, studySuggestions, requestPartner, respondPartner, partners, endPartnership, studyNow,
  schedulePost, listScheduled, cancelScheduled, dispatchDue, setThreadCalm, setChatCalm, setNotifyMode, listLog,
  buildDigest, runDigests, startHubScheduler,
};
