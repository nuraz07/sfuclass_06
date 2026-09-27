// classroom-app/server/src/rooms/ScheduledRooms.js
/**
 * Rooms people create themselves  (Rooms)
 *
 * A created room is a scheduled session (scheduling/ScheduleService, 010 +
 * 024) with a room code of its own. This module is everything around it:
 *
 *   create · preview · update · cancel · extend · end    for the host
 *   detail, entry decision, knock, waiting list          for the lobby
 *   admissionFor · applyToRoom                           for the socket join
 *   startEnforcer                                        closes rooms at their
 *                                                        end time, hands freed
 *                                                        seats to the waiting
 *                                                        list, marks rooms ended
 *
 * The rules themselves (when the doors open, who may enter) are pure and live
 * in rooms/roomRules.js. Short-lived state — who was already in, who knocked,
 * who was let in, the waiting list, held seats — is in Redis next to the
 * seats (capacity/CapacityGuard) and expires a day after the room ends.
 *
 * Ad-hoc rooms (any other id in /rooms/<id>) are untouched: admissionFor()
 * answers null for them and the join works exactly as before.
 */

import { env, isProduction } from '../config/env.js';
import { publicAppUrl } from '../config/publicUrl.js';
import { pool } from '../db/pool.js';
import { stateRedis as redis } from '../db/redis.js';
import { logger } from '../observability/logger.js';
import * as Rules from './roomRules.js';

const log = logger.child({ component: 'scheduled-rooms' });

const P = env.REDIS_PREFIX;
const keys = {
  joined: (code) => `${P}:room:${code}:joined`,
  admitted: (code) => `${P}:room:${code}:admitted`,
  knocks: (code) => `${P}:room:${code}:knocks`,
  waitlist: (code) => `${P}:room:${code}:waitlist`,
  holds: (code) => `${P}:room:${code}:holds`,
  withWaitlist: () => `${P}:rooms:with-waitlist`,
  enforcerLock: () => `${P}:rooms:enforcer-lock`,
};

const fail = (code, message, details) => {
  throw Object.assign(new Error(message), { code, details });
};

const iso = (value) => (value ? new Date(value).toISOString() : null);

// ---------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------

const COLUMNS = `
  s.id, s.tenant_id, s.series_id, s.host_id, s.room_id, s.room_code, s.title, s.description,
  s.starts_at, s.ends_at, s.time_zone, s.status, s.sequence, s.recurrence,
  s.early_entry_min, s.late_join_min, s.capacity, s.access, s.approval,
  s.cohost_ids, s.room_settings, s.created_at, s.cancelled_at, s.cancel_reason
`;

const toRoom = (row) =>
  row && {
    id: row.id,
    tenantId: row.tenant_id,
    seriesId: row.series_id,
    hostId: row.host_id,
    code: row.room_code,
    title: row.title,
    description: row.description,
    startsAt: iso(row.starts_at),
    endsAt: iso(row.ends_at),
    timeZone: row.time_zone,
    status: row.status,
    sequence: row.sequence,
    recurrence: row.recurrence,
    earlyEntryMinutes: row.early_entry_min,
    lateJoinMinutes: row.late_join_min,
    capacity: row.capacity,
    access: row.access,
    approval: row.approval,
    cohostIds: row.cohost_ids ?? [],
    settings: row.room_settings ?? {},
    createdAt: iso(row.created_at),
    cancelledAt: iso(row.cancelled_at),
    cancelReason: row.cancel_reason ?? null,
  };

export const findByCode = async (code, client = pool) => {
  if (!Rules.isRoomCode(code)) return null;
  const { rows } = await client.query(`SELECT ${COLUMNS} FROM scheduled_sessions s WHERE s.room_code = $1`, [code]);
  return toRoom(rows[0]);
};

const isInvited = async (sessionId, userId) => {
  const { rows } = await pool.query(
    `SELECT 1 FROM session_invitees WHERE session_id = $1 AND user_id = $2`,
    [sessionId, userId],
  );
  return rows.length > 0;
};

const tenantOfUser = async (userId) => {
  const { rows } = await pool.query(`SELECT tenant_id FROM users WHERE id = $1 AND deleted_at IS NULL`, [userId]);
  return rows[0]?.tenant_id ?? null;
};

export const relationFor = async (room, { userId, tenantId = null }) => {
  const tenant = tenantId ?? (await tenantOfUser(userId));
  const sameTenant = tenant === room.tenantId;
  if (!sameTenant) return null;
  return Rules.relationOf(room, { userId, invited: await isInvited(room.id, userId), sameTenant });
};

/** Seats for learners: the room's own limit, never above the platform maximum. */
export const capacityOf = (room) => Math.min(room.capacity ?? Rules.CAPACITY.max, Rules.CAPACITY.max);

// ---------------------------------------------------------------------------
// Redis state
// ---------------------------------------------------------------------------

const expireWithRoom = async (key, room) => {
  const at = Math.floor(new Date(room.endsAt).getTime() / 1000) + 86_400;
  await redis.expireat(key, at).catch(() => undefined);
};

const liveHolds = async (room) => {
  const raw = (await redis.hgetall(keys.holds(room.code)).catch(() => ({}))) ?? {};
  const now = Date.now();
  const holds = new Map();
  for (const [userId, expiry] of Object.entries(raw)) {
    if (Number(expiry) > now) holds.set(userId, Number(expiry));
    else void redis.hdel(keys.holds(room.code), userId).catch(() => undefined);
  }
  return holds;
};

const occupancyOf = async (room) => {
  try {
    const { occupancy } = await import('../capacity/CapacityGuard.js');
    return await occupancy(room.code);
  } catch {
    return { occupied: 0, userIds: [] };
  }
};

/** Everything the entry decision needs about one person, read together. */
const stateFor = async (room, userId) => {
  const [joined, admitted, knocked, position, holds, seats] = await Promise.all([
    redis.sismember(keys.joined(room.code), userId).catch(() => 0),
    redis.sismember(keys.admitted(room.code), userId).catch(() => 0),
    redis.hexists(keys.knocks(room.code), userId).catch(() => 0),
    redis.zrank(keys.waitlist(room.code), userId).catch(() => null),
    liveHolds(room),
    occupancyOf(room),
  ]);
  const others = seats.userIds.filter((id) => id !== userId);
  const heldForOthers = [...holds.keys()].filter((id) => id !== userId).length;
  return {
    joinedBefore: joined === 1,
    admitted: admitted === 1,
    knocked: knocked === 1,
    waitlistPosition: position === null || position === undefined ? null : Number(position) + 1,
    holdsSeat: holds.has(userId),
    holdUntil: holds.get(userId) ?? null,
    occupied: seats.occupied,
    occupiedByOthers: others.length,
    heldForOthers,
  };
};

export const decide = async ({ room, userId, tenantId = null, now = Date.now() }) => {
  const relation = await relationFor(room, { userId, tenantId });
  const state = await stateFor(room, userId);
  const decision = Rules.entryDecision({
    room,
    relation,
    now,
    joinedBefore: state.joinedBefore,
    admitted: state.admitted,
    occupiedByOthers: state.occupiedByOthers,
    heldForOthers: state.heldForOthers,
    holdsSeat: state.holdsSeat,
    capacity: capacityOf(room),
  });
  return { relation, state, decision };
};

const markLive = (room) =>
  pool
    .query(
      `UPDATE scheduled_sessions SET status = 'live', room_id = coalesce(room_id, room_code), updated_at = now()
        WHERE id = $1 AND status = 'scheduled'`,
      [room.id],
    )
    .catch((cause) => log.warn({ err: cause, code: room.code }, 'room not marked live'));

// ---------------------------------------------------------------------------
// The socket join (signaling/socketHandlers.js)
// ---------------------------------------------------------------------------

/**
 * null for rooms that are not scheduled — their join is unchanged. Otherwise
 * whether this person may come in now, their role in the room, the seat
 * limit to reserve against and the settings the room starts with.
 */
export const admissionFor = async ({ roomId, userId, tenantId }) => {
  if (!Rules.isRoomCode(roomId)) return null;
  let room;
  try {
    room = await findByCode(roomId);
  } catch (cause) {
    // A database problem must not turn every room into a locked one.
    log.error({ err: cause, roomId }, 'scheduled room lookup failed; joining as an ad-hoc room');
    return null;
  }
  if (!room) return null;

  const { relation, decision } = await decide({ room, userId, tenantId });
  if (!decision.allowed) return { allowed: false, code: decision.code, message: decision.message };

  const moderator = Rules.isModerator(relation);
  await Promise.all([
    redis.sadd(keys.joined(room.code), userId).then(() => expireWithRoom(keys.joined(room.code), room)),
    redis.hdel(keys.holds(room.code), userId),
    redis.zrem(keys.waitlist(room.code), userId),
    redis.hdel(keys.knocks(room.code), userId),
  ]).catch(() => undefined);
  await markLive(room);

  return {
    allowed: true,
    role: relation === 'host' ? 'host' : relation === 'cohost' ? 'cohost' : 'learner',
    hostId: room.hostId,
    // Hosts and co-hosts always get in: 0 is "no limit" for reserveSeat.
    capacity: moderator ? 0 : capacityOf(room),
    code: room.code,
    endsAt: room.endsAt,
    settings: room.settings,
  };
};

/** The room's own starting settings, once, when the live room is created. */
export const applyToRoom = (liveRoom, admission) => {
  if (!liveRoom || !admission || liveRoom.scheduled) return;
  const settings = admission.settings ?? {};
  // The lobby is the waiting room for scheduled rooms (knock and admit), so
  // the classroom's own waiting room stays off.
  liveRoom.settings.waitingRoom = false;
  if (typeof settings.learnersJoinMuted === 'boolean') liveRoom.settings.startMuted = settings.learnersJoinMuted;
  if (typeof settings.reactionsEnabled === 'boolean') liveRoom.settings.reactionsEnabled = settings.reactionsEnabled;
  if (typeof settings.learnersMayShare === 'boolean') liveRoom.settings.learnersMayShare = settings.learnersMayShare;
  liveRoom.hostUserId = admission.hostId;
  liveRoom.scheduled = { code: admission.code, endsAt: admission.endsAt };
};

// ---------------------------------------------------------------------------
// Lobby: knocking, the waiting list
// ---------------------------------------------------------------------------

export const knock = async ({ room, user }) => {
  await redis.hset(
    keys.knocks(room.code),
    user.userId,
    JSON.stringify({ displayName: user.displayName ?? 'Someone', at: new Date().toISOString() }),
  );
  await expireWithRoom(keys.knocks(room.code), room);
  const { pushToUser } = await import('../realtime/userEvents.js');
  for (const id of [room.hostId, ...room.cohostIds]) {
    await pushToUser(id, 'room:knock', { code: room.code, displayName: user.displayName ?? 'Someone' });
  }
};

export const withdrawKnock = (room, userId) => redis.hdel(keys.knocks(room.code), userId);

export const listKnocks = async (room) => {
  const raw = (await redis.hgetall(keys.knocks(room.code))) ?? {};
  return Object.entries(raw)
    .map(([userId, value]) => {
      try {
        return { userId, ...JSON.parse(value) };
      } catch {
        return { userId, displayName: 'Someone', at: null };
      }
    })
    .sort((a, b) => String(a.at).localeCompare(String(b.at)));
};

/** Lets people in. `userIds` empty means everyone who is knocking. */
export const admit = async ({ room, userIds = [] }) => {
  const targets = userIds.length ? userIds : (await listKnocks(room)).map((entry) => entry.userId);
  if (targets.length === 0) return { admitted: 0 };
  await redis.sadd(keys.admitted(room.code), ...targets);
  await expireWithRoom(keys.admitted(room.code), room);
  await redis.hdel(keys.knocks(room.code), ...targets);
  const { pushToUser } = await import('../realtime/userEvents.js');
  for (const id of targets) await pushToUser(id, 'room:admitted', { code: room.code });
  return { admitted: targets.length };
};

export const deny = async ({ room, userId }) => {
  await redis.hdel(keys.knocks(room.code), userId);
  const { pushToUser } = await import('../realtime/userEvents.js');
  await pushToUser(userId, 'room:denied', { code: room.code });
  return { denied: true };
};

export const joinWaitlist = async ({ room, userId }) => {
  await redis.zadd(keys.waitlist(room.code), 'NX', Date.now(), userId);
  await expireWithRoom(keys.waitlist(room.code), room);
  await redis.sadd(keys.withWaitlist(), room.code);
  const rank = await redis.zrank(keys.waitlist(room.code), userId);
  return { position: rank === null ? null : Number(rank) + 1 };
};

export const leaveWaitlist = async ({ room, userId }) => {
  await redis.zrem(keys.waitlist(room.code), userId);
  await redis.hdel(keys.holds(room.code), userId);
  return { position: null };
};

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

const namesOf = async (userIds) => {
  if (userIds.length === 0) return new Map();
  const { rows } = await pool.query(
    `SELECT u.id, u.display_name, p.handle FROM users u LEFT JOIN profiles p ON p.user_id = u.id
      WHERE u.id = ANY($1::uuid[])`,
    [userIds],
  );
  return new Map(rows.map((row) => [row.id, { userId: row.id, displayName: row.display_name, handle: row.handle ?? null }]));
};

const inviteesOf = async (sessionId) => {
  const { rows } = await pool.query(`SELECT user_id FROM session_invitees WHERE session_id = $1`, [sessionId]);
  return rows.map((row) => row.user_id);
};

/**
 * The link to a room's lobby. `base` is the address the asking browser is on
 * (routes pass publicAppUrlFor(req)); without it, the public address of the
 * app (config/publicUrl.js) — never localhost in a Codespace.
 */
export const roomUrl = (code, base = publicAppUrl()) => `${String(base).replace(/\/$/, '')}/rooms/${code}/lobby`;

/** What a person sees of a room: the lobby, the room card, the editor. */
export const detailFor = async ({ room, userId, tenantId = null, now = Date.now(), baseUrl = undefined }) => {
  const { relation, state, decision } = await decide({ room, userId, tenantId, now });
  if (!relation) fail('not_found', 'No such room, or it is not shared with you.');

  const moderator = Rules.isModerator(relation);
  const invitees = moderator ? await inviteesOf(room.id) : [];
  const names = await namesOf([...new Set([room.hostId, ...room.cohostIds, ...invitees])]);
  const time = Rules.windowFor(room);

  return {
    code: room.code,
    sessionId: room.id,
    seriesId: room.seriesId,
    title: room.title,
    description: room.description,
    agenda: room.settings.agenda ?? null,
    startsAt: room.startsAt,
    endsAt: room.endsAt,
    timeZone: room.timeZone,
    doorsOpenAt: new Date(time.doorsOpenAt).toISOString(),
    hostOpensAt: new Date(time.hostOpensAt).toISOString(),
    lateUntil: time.lateUntil ? new Date(time.lateUntil).toISOString() : null,
    earlyEntryMinutes: room.earlyEntryMinutes,
    lateJoinMinutes: room.lateJoinMinutes,
    status: room.status,
    phase: Rules.phaseOf(room, now),
    access: room.access,
    approval: room.approval,
    capacity: room.capacity,
    effectiveCapacity: capacityOf(room),
    occupied: state.occupied,
    settings: {
      learnersJoinMuted: room.settings.learnersJoinMuted ?? null,
      reactionsEnabled: room.settings.reactionsEnabled ?? null,
      learnersMayShare: room.settings.learnersMayShare ?? null,
    },
    host: names.get(room.hostId) ?? { userId: room.hostId, displayName: 'Host' },
    cohosts: room.cohostIds.map((id) => names.get(id) ?? { userId: id, displayName: 'Co-host' }),
    invitees: moderator ? invitees.map((id) => names.get(id) ?? { userId: id, displayName: 'Invitee' }) : undefined,
    url: roomUrl(room.code, baseUrl),
    cancelReason: room.cancelReason,
    viewer: {
      relation,
      moderator,
      canEnter: decision.allowed,
      reason: decision.code,
      message: decision.message,
      opensAt: decision.opensAt ? new Date(decision.opensAt).toISOString() : null,
      knocked: state.knocked,
      admitted: state.admitted,
      waitlistPosition: state.waitlistPosition,
      holdUntil: state.holdUntil ? new Date(state.holdUntil).toISOString() : null,
    },
    serverTime: new Date(now).toISOString(),
  };
};

/** "My rooms": hosted, co-hosted or invited; upcoming (incl. running) or past. */
export const listMine = async ({ userId, when = 'upcoming', limit = 50 }) => {
  const upcoming = when !== 'past';
  const { rows } = await pool.query(
    `SELECT ${COLUMNS},
            (SELECT count(*)::int FROM session_invitees i WHERE i.session_id = s.id) AS invitee_count,
            u.display_name AS host_name
       FROM scheduled_sessions s
       JOIN users u ON u.id = s.host_id
      WHERE s.room_code IS NOT NULL
        AND (s.host_id = $1 OR $1 = ANY(s.cohost_ids)
             OR EXISTS (SELECT 1 FROM session_invitees i WHERE i.session_id = s.id AND i.user_id = $1))
        AND ${upcoming
          ? `s.ends_at >= now() AND s.status IN ('scheduled', 'live')`
          : `(s.ends_at < now() OR s.status IN ('ended', 'cancelled')) AND s.starts_at > now() - interval '90 days'`}
      ORDER BY s.starts_at ${upcoming ? 'ASC' : 'DESC'}
      LIMIT $2`,
    [userId, limit],
  );
  const now = Date.now();
  return {
    items: rows.map((row) => {
      const room = toRoom(row);
      const relation = room.hostId === userId ? 'host' : room.cohostIds.includes(userId) ? 'cohost' : 'invitee';
      return {
        code: room.code,
        sessionId: room.id,
        seriesId: room.seriesId,
        title: room.title,
        startsAt: room.startsAt,
        endsAt: room.endsAt,
        doorsOpenAt: new Date(Rules.windowFor(room).doorsOpenAt).toISOString(),
        timeZone: room.timeZone,
        status: room.status,
        phase: Rules.phaseOf(room, now),
        access: room.access,
        capacity: room.capacity,
        inviteeCount: row.invitee_count,
        hostName: row.host_name,
        relation,
      };
    }),
  };
};

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

const Schedule = () => import('../scheduling/ScheduleService.js');
const Reminders = () => import('../scheduling/ReminderRules.js');

const withTransaction = async (fn) => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (cause) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw cause;
  } finally {
    client.release();
  }
};

/** Occurrences a create or a reschedule would make, and what they collide with. */
export const preview = async ({ tenantId, hostId, startsAtLocal, durationMinutes, timeZone, recurrence = null, excludeSessionIds = [] }) => {
  const S = await Schedule();
  S.assertTimeZone(timeZone);
  const first = S.parseLocalDateTime(startsAtLocal, timeZone);
  const instants = S.expandRecurrence(first.wall, timeZone, recurrence ?? null);
  const occurrences = instants.map((start) => ({
    startsAt: new Date(start).toISOString(),
    endsAt: new Date(start + durationMinutes * 60_000).toISOString(),
  }));
  const conflicts = [];
  for (const occurrence of occurrences.slice(0, 60)) {
    const found = await S.findHostConflicts({
      tenantId,
      hostId,
      startsAt: new Date(occurrence.startsAt),
      endsAt: new Date(occurrence.endsAt),
      excludeSessionIds,
    });
    for (const conflict of found) {
      conflicts.push({ at: occurrence.startsAt, title: conflict.title, startsAt: iso(conflict.startsAt), endsAt: iso(conflict.endsAt) });
    }
  }
  return {
    occurrences,
    conflicts,
    adjusted: first.adjusted,
    inPast: new Date(occurrences[0].startsAt).getTime() < Date.now() - 60_000,
  };
};

const notifyPeople = async ({ userIds, type, title, body, code, actorId }) => {
  const recipients = [...new Set(userIds)].filter((id) => id && id !== actorId);
  if (recipients.length === 0) return;
  try {
    const { notifyMany } = await import('../community/NotificationService.js');
    await notifyMany({
      userIds: recipients,
      type,
      title,
      body,
      href: `/rooms/${code}/lobby`,
      actorId,
      data: { roomCode: code },
      dedupeKey: `${type}:${code}`,
    });
  } catch (cause) {
    log.warn({ err: cause, type }, 'room notification not queued');
  }
};

const whenText = (room) =>
  new Intl.DateTimeFormat('en-GB', { timeZone: room.timeZone, dateStyle: 'medium', timeStyle: 'short' }).format(
    new Date(room.startsAt),
  );

const cleanPeople = (ids, hostId) => [...new Set(ids)].filter((id) => id && id !== hostId);

/**
 * Creates a room, or one room per date of a series. One transaction: either
 * every date exists or none does.
 */
export const create = async ({ input, tenantId, hostId }) => {
  const S = await Schedule();
  const R = await Reminders();
  S.assertTimeZone(input.timeZone);

  if (input.capacity && input.capacity > Rules.CAPACITY.max) {
    fail('validation_failed', `A room holds at most ${Rules.CAPACITY.max} people.`);
  }
  const first = S.parseLocalDateTime(input.startsAtLocal, input.timeZone);
  if (first.date.getTime() < Date.now() - 60_000) fail('validation_failed', 'That start time is in the past.');

  const recurrence = input.recurrence ?? null;
  const instants = S.expandRecurrence(first.wall, input.timeZone, recurrence);
  const cohostIds = cleanPeople(input.cohostIds ?? [], hostId);
  const inviteeIds = cleanPeople([...(input.inviteeIds ?? [])], hostId).filter((id) => !cohostIds.includes(id));
  const seriesId = recurrence ? (await import('node:crypto')).randomUUID() : null;
  const durationMs = input.durationMinutes * 60_000;

  const created = await withTransaction(async (client) => {
    const rooms = [];
    for (const start of instants) {
      const startsAt = new Date(start);
      const endsAt = new Date(start + durationMs);
      const conflicts = await S.findHostConflicts({ tenantId, hostId, startsAt, endsAt }, client);
      if (conflicts.length > 0) {
        fail('conflict', `You already have “${conflicts[0].title}” at that time.`, {
          at: startsAt.toISOString(),
          conflictWith: conflicts.map((c) => ({ title: c.title, startsAt: iso(c.startsAt) })),
        });
      }

      const { rows } = await client.query(
        `INSERT INTO scheduled_sessions
           (tenant_id, series_id, host_id, title, description, starts_at, ends_at, time_zone,
            status, sequence, waiting_room, recurrence, created_by,
            room_code, early_entry_min, late_join_min, capacity, access, approval, cohost_ids, room_settings)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,'scheduled',0,false,$9,$3,$10,$11,$12,$13,$14,$15,$16,$17)
         RETURNING id`,
        [
          tenantId,
          seriesId,
          hostId,
          input.title,
          input.description ?? null,
          startsAt,
          endsAt,
          input.timeZone,
          recurrence ? JSON.stringify(recurrence) : null,
          Rules.newRoomCode(),
          input.earlyEntryMinutes ?? Rules.EARLY_ENTRY.default,
          input.lateJoinMinutes ?? null,
          input.capacity ?? null,
          input.access ?? 'invited',
          Boolean(input.approval),
          cohostIds,
          JSON.stringify(input.settings ?? {}),
        ],
      );
      const id = rows[0].id;
      if (inviteeIds.length > 0) {
        await client.query(
          `INSERT INTO session_invitees (session_id, user_id) SELECT $1, unnest($2::uuid[]) ON CONFLICT DO NOTHING`,
          [id, inviteeIds],
        );
      }
      const { rows: full } = await client.query(`SELECT ${COLUMNS} FROM scheduled_sessions s WHERE s.id = $1`, [id]);
      const room = toRoom(full[0]);
      await R.syncForSession({ id: room.id, startsAt: room.startsAt, status: room.status, sequence: room.sequence }, client);
      rooms.push(room);
    }
    return rooms;
  });

  const firstRoom = created[0];
  await notifyPeople({
    userIds: [...inviteeIds, ...cohostIds],
    type: 'session.invited',
    title: created.length > 1 ? `Invitation: ${firstRoom.title} (${created.length} dates)` : `Invitation: ${firstRoom.title}`,
    body: `${whenText(firstRoom)} (${firstRoom.timeZone.replace(/_/g, ' ')})`,
    code: firstRoom.code,
    actorId: hostId,
  });
  log.info({ hostId, count: created.length }, 'rooms created');
  return created;
};

/** Changes one date of a room. Moving it bumps SEQUENCE and re-plans the reminders. */
export const update = async ({ room, patch, actorId }) => {
  const S = await Schedule();
  const R = await Reminders();
  if (room.status === 'cancelled' || room.status === 'ended') fail('validation_failed', 'This room is over and cannot be changed.');

  const zone = patch.timeZone ?? room.timeZone;
  const timeChanged = patch.startsAtLocal !== undefined || patch.durationMinutes !== undefined || patch.timeZone !== undefined;
  let startsAt = new Date(room.startsAt);
  let endsAt = new Date(room.endsAt);

  if (timeChanged) {
    S.assertTimeZone(zone);
    const duration = patch.durationMinutes ?? Math.round((endsAt - startsAt) / 60_000);
    if (patch.startsAtLocal !== undefined) startsAt = S.parseLocalDateTime(patch.startsAtLocal, zone).date;
    endsAt = new Date(startsAt.getTime() + duration * 60_000);
    if (room.status === 'scheduled' && startsAt.getTime() < Date.now() - 60_000) {
      fail('validation_failed', 'That start time is in the past.');
    }
    const conflicts = await S.findHostConflicts({
      tenantId: room.tenantId, hostId: room.hostId, startsAt, endsAt, excludeSessionIds: [room.id],
    });
    if (conflicts.length > 0) fail('conflict', `You already have “${conflicts[0].title}” at that time.`);
  }

  const cohostIds = patch.cohostIds ? cleanPeople(patch.cohostIds, room.hostId) : room.cohostIds;
  const settings = patch.settings ? { ...room.settings, ...patch.settings } : room.settings;
  const before = await inviteesOf(room.id);

  const updated = await withTransaction(async (client) => {
    const { rows } = await client.query(
      `UPDATE scheduled_sessions
          SET title = $2, description = $3, starts_at = $4, ends_at = $5, time_zone = $6,
              early_entry_min = $7, late_join_min = $8, capacity = $9, access = $10, approval = $11,
              cohost_ids = $12, room_settings = $13,
              sequence = sequence + CASE WHEN $14 THEN 1 ELSE 0 END, updated_at = now()
        WHERE id = $1
        RETURNING id`,
      [
        room.id,
        patch.title ?? room.title,
        patch.description !== undefined ? patch.description : room.description,
        startsAt,
        endsAt,
        zone,
        patch.earlyEntryMinutes ?? room.earlyEntryMinutes,
        patch.lateJoinMinutes !== undefined ? patch.lateJoinMinutes : room.lateJoinMinutes,
        patch.capacity !== undefined ? patch.capacity : room.capacity,
        patch.access ?? room.access,
        patch.approval ?? room.approval,
        cohostIds,
        JSON.stringify(settings),
        timeChanged,
      ],
    );
    if (!rows[0]) fail('not_found', 'No such room');

    if (patch.inviteeIds) {
      const next = cleanPeople(patch.inviteeIds, room.hostId).filter((id) => !cohostIds.includes(id));
      await client.query(`DELETE FROM session_invitees WHERE session_id = $1 AND NOT (user_id = ANY($2::uuid[]))`, [room.id, next]);
      if (next.length) {
        await client.query(
          `INSERT INTO session_invitees (session_id, user_id) SELECT $1, unnest($2::uuid[]) ON CONFLICT DO NOTHING`,
          [room.id, next],
        );
      }
    }
    const { rows: full } = await client.query(`SELECT ${COLUMNS} FROM scheduled_sessions s WHERE s.id = $1`, [room.id]);
    const next = toRoom(full[0]);
    if (timeChanged) {
      await R.syncForSession({ id: next.id, startsAt: next.startsAt, status: next.status, sequence: next.sequence }, client);
    }
    return next;
  });

  const after = await inviteesOf(room.id);
  const added = [...after.filter((id) => !before.includes(id)), ...cohostIds.filter((id) => !room.cohostIds.includes(id))];
  await notifyPeople({
    userIds: added,
    type: 'session.invited',
    title: `Invitation: ${updated.title}`,
    body: `${whenText(updated)} (${updated.timeZone.replace(/_/g, ' ')})`,
    code: updated.code,
    actorId,
  });
  if (timeChanged) {
    await notifyPeople({
      userIds: [...after, ...cohostIds].filter((id) => !added.includes(id)),
      type: 'session.rescheduled',
      title: `New time: ${updated.title}`,
      body: `${whenText(updated)} (${updated.timeZone.replace(/_/g, ' ')})`,
      code: updated.code,
      actorId,
    });
  }
  return updated;
};

export const cancel = async ({ room, scope = 'this', reason = null, actorId }) => {
  const S = await Schedule();
  const audience = [...(await inviteesOf(room.id)), ...room.cohostIds];
  const cancelled = await S.cancelSession(room.id, { reason, scope }, { userId: actorId });
  await notifyPeople({
    userIds: audience,
    type: 'session.cancelled',
    title: `Cancelled: ${room.title}`,
    body: reason ? `${whenText(room)} — ${reason}` : whenText(room),
    code: room.code,
    actorId,
  });
  return { cancelled: cancelled.length };
};

/** More time for a running room. Refused when it would run into the host's next room. */
export const extend = async ({ room, minutes }) => {
  if (!Rules.EXTEND_MINUTES.includes(minutes)) fail('validation_failed', 'Extend by 5, 10, 15 or 30 minutes.');
  if (Rules.phaseOf(room) === 'ended' || room.status === 'cancelled') fail('validation_failed', 'This room has ended.');
  const S = await Schedule();
  const endsAt = new Date(new Date(room.endsAt).getTime() + minutes * 60_000);
  const conflicts = await S.findHostConflicts({
    tenantId: room.tenantId, hostId: room.hostId, startsAt: new Date(room.endsAt), endsAt, excludeSessionIds: [room.id],
  });
  if (conflicts.length > 0) fail('conflict', `That would run into “${conflicts[0].title}”.`);
  await pool.query(
    `UPDATE scheduled_sessions SET ends_at = $2, sequence = sequence + 1, updated_at = now() WHERE id = $1`,
    [room.id, endsAt],
  );
  return { endsAt: endsAt.toISOString() };
};

/** Ends the room for everyone now. The enforcer closes it on the media node within seconds. */
export const end = async ({ room }) => {
  await pool.query(
    `UPDATE scheduled_sessions SET ends_at = least(ends_at, now()), status = 'ended', updated_at = now()
      WHERE id = $1 AND status IN ('scheduled', 'live')`,
    [room.id],
  );
  try {
    const RoomManager = await import('../classroom/RoomManager.js');
    if (RoomManager.getRoom(room.code)) await RoomManager.closeRoom(room.code, 'ended-by-host');
  } catch {
    // Not the media process: the enforcer there closes it.
  }
  return { ended: true };
};

// ---------------------------------------------------------------------------
// Enforcer (runs where the rooms live: next to the socket handlers)
// ---------------------------------------------------------------------------

let enforcer = null;
let ticks = 0;

const closeEndedRooms = async ({ listRoomIds, closeRoom }) => {
  const codes = listRoomIds().filter(Rules.isRoomCode);
  if (codes.length === 0) return;
  const { rows } = await pool.query(
    `SELECT room_code, ends_at, status FROM scheduled_sessions WHERE room_code = ANY($1::text[])`,
    [codes],
  );
  const now = Date.now();
  for (const row of rows) {
    if (row.status === 'cancelled' || row.status === 'ended' || new Date(row.ends_at).getTime() <= now) {
      log.info({ code: row.room_code }, 'room reached its end time; closing');
      await closeRoom(row.room_code, 'ended-by-host').catch(() => undefined);
    }
  }
};

const promoteWaitlists = async () => {
  const codes = await redis.smembers(keys.withWaitlist());
  for (const code of codes) {
    const room = await findByCode(code);
    const waiting = room ? await redis.zcard(keys.waitlist(code)) : 0;
    if (!room || waiting === 0 || Rules.phaseOf(room) === 'ended' || room.status === 'cancelled') {
      await redis.srem(keys.withWaitlist(), code);
      continue;
    }
    const [holds, seats] = await Promise.all([liveHolds(room), occupancyOf(room)]);
    const free = Rules.freeSeats({ capacity: capacityOf(room), occupied: seats.occupied, held: holds.size });
    if (free === 0) continue;

    const next = await redis.zrange(keys.waitlist(code), 0, free - 1);
    const { pushToUser } = await import('../realtime/userEvents.js');
    for (const userId of next) {
      const until = Date.now() + Rules.HOLD_MS;
      await redis.hset(keys.holds(code), userId, String(until));
      await expireWithRoom(keys.holds(code), room);
      await redis.zrem(keys.waitlist(code), userId);
      await pushToUser(userId, 'room:seat-available', { code, holdUntil: new Date(until).toISOString() });
      await notifyPeople({
        userIds: [userId],
        type: 'session.seat_available',
        title: `A seat is free: ${room.title}`,
        body: 'It is held for you for 2 minutes.',
        code,
        actorId: null,
      });
    }
  }
};

const markEnded = () =>
  pool.query(
    `UPDATE scheduled_sessions SET status = 'ended', updated_at = now()
      WHERE room_code IS NOT NULL AND status IN ('scheduled', 'live') AND ends_at < now()`,
  );

/**
 * Every 15 seconds. Closing rooms runs on every task (rooms are local to a
 * node); the rest runs once cluster-wide behind a short Redis lock. In
 * development it also hands due lesson reminders to the queue, which in
 * production is the maintenance sweep's job.
 */
export const startEnforcer = ({ listRoomIds, closeRoom, intervalMs = 15_000 }) => {
  if (enforcer) return enforcer;
  const tick = async () => {
    ticks += 1;
    try {
      await closeEndedRooms({ listRoomIds, closeRoom });
    } catch (cause) {
      log.warn({ err: cause }, 'room end check failed');
    }
    try {
      const lock = await redis.set(keys.enforcerLock(), String(process.pid), 'PX', intervalMs - 1_000, 'NX');
      if (lock !== 'OK') return;
      await markEnded();
      await promoteWaitlists();
      if (!isProduction && ticks % 4 === 0 && process.env.REMINDER_SWEEP !== 'off') {
        const { enqueueDue } = await import('../scheduling/ReminderRules.js');
        await enqueueDue().catch((cause) => log.debug({ err: cause }, 'reminder sweep skipped'));
      }
    } catch (cause) {
      log.warn({ err: cause }, 'room sweep failed');
    }
  };
  enforcer = setInterval(() => void tick(), intervalMs);
  enforcer.unref?.();
  log.info('scheduled room enforcer started');
  return enforcer;
};

export default {
  findByCode, relationFor, decide, admissionFor, applyToRoom, detailFor, listMine, preview,
  create, update, cancel, extend, end, knock, withdrawKnock, listKnocks, admit, deny,
  joinWaitlist, leaveWaitlist, startEnforcer, capacityOf, roomUrl,
};
