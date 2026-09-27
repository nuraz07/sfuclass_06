#!/usr/bin/env bash
# rooms-roomid-install.sh — Rooms fix: the live room runs under a UUID.
#
# Symptom this fixes: in a scheduled room, writing a private message (and the
# lesson chat's block list, and profile cards) fails with 422, because those
# existing routes accept a room id only in UUID form and got the room's link
# code ("7x5-8ute-4z9"). Now the code stays the link, and the live room runs
# under the session's UUID.
#
# Run from the project folder:  bash rooms-roomid-install.sh
# Undo:                         bash rooms-roomid-install.sh --restore
set -euo pipefail

if [ ! -d server/src/messaging ] || [ ! -d packages/core-client/src ] || [ ! -d apps/web/src ]; then
  echo "Run this from the project folder (the one that contains server/, packages/ and apps/)." >&2
  exit 1
fi

TOUCHED=(
  server/src/rooms/ScheduledRooms.js
  server/src/routes/scheduledRooms.routes.js
  packages/core-client/src/api/roomsApi.ts
  apps/web/src/lib/useRoomGate.js
  apps/web/src/pages/ClassroomPage.jsx
)

if [ "${1:-}" = "--restore" ]; then
  FIRST=$(ls -1d .rooms-roomid-backup/* 2>/dev/null | head -1 || true)
  [ -n "$FIRST" ] || { echo "No backup found." >&2; exit 1; }
  for f in "${TOUCHED[@]}"; do
    if [ -f "$FIRST/$f" ]; then cp "$FIRST/$f" "$f"; echo "restored $f"; fi
  done
  touch server/src/server.js 2>/dev/null || true
  echo "Restored from $FIRST."
  exit 0
fi

MISSING=()
need() { # need <file> <text> <why>
  if [ ! -f "$1" ]; then MISSING+=("$1 is missing ($3)");
  elif ! grep -qF -- "$2" "$1"; then MISSING+=("$1 has no '$2' ($3)"); fi
}
need server/src/rooms/ScheduledRooms.js "export const admissionFor" "the rooms feature (rooms-install.sh)"
need server/src/config/publicUrl.js "publicAppUrlFor" "the links update (rooms-links-install.sh)"
need apps/web/src/pages/ClassroomPage.jsx "useRoomGate(roomId)" "the rooms feature (rooms-install.sh)"
need packages/core-client/src/api/roomsApi.ts "pageOrigin" "the links update (rooms-links-install.sh)"
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "This tree does not match what this fix expects. Nothing was changed:" >&2
  for m in "${MISSING[@]}"; do echo "  - $m" >&2; done
  exit 1
fi

BACKUP=".rooms-roomid-backup/$(date +%Y%m%d-%H%M%S)"
for f in "${TOUCHED[@]}"; do
  if [ -f "$f" ]; then mkdir -p "$BACKUP/$(dirname "$f")"; cp "$f" "$BACKUP/$f"; fi
done
echo "backup: $BACKUP"

mkdir -p server/src/rooms
cat > server/src/rooms/ScheduledRooms.js <<'__RID_EOF__'
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
 * Two ids, on purpose:
 *
 *   code     "kqz-7hfd-2mx"  the link people share (/rooms/<code>/lobby)
 *   liveId   the session's UUID, the id of the live room on the media node.
 *            Everything that already existed around a live room — lesson
 *            chat, blocks for this lesson, profiles "in this room", seats —
 *            expects a UUID there and rejects anything else (422). So the
 *            classroom page resolves the code to this id (GET …/gate) and
 *            joins with it; the code never reaches those routes.
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

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const isLiveId = (value) => UUID.test(String(value ?? ''));

/** The live room id of a scheduled room: its session's UUID. */
export const liveIdOf = (room) => room.id;

/** A scheduled room by the id of its live room. null for every other room. */
export const findByLiveId = async (liveId, client = pool) => {
  if (!isLiveId(liveId)) return null;
  const { rows } = await client.query(
    `SELECT ${COLUMNS} FROM scheduled_sessions s WHERE s.id = $1 AND s.room_code IS NOT NULL`,
    [liveId],
  );
  return toRoom(rows[0]);
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
    return await occupancy(liveIdOf(room));
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
      `UPDATE scheduled_sessions SET status = 'live', room_id = coalesce(room_id, id::text), updated_at = now()
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
  // A code is the link, never a live room: joining with it would open a
  // second room next to the real one. Up-to-date pages never send it.
  if (Rules.isRoomCode(roomId)) {
    return { allowed: false, code: 'reload_required', message: 'Reload the page to enter this room.' };
  }
  if (!isLiveId(roomId)) return null;
  let room;
  try {
    room = await findByLiveId(roomId);
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
    liveId: liveIdOf(room),
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
    liveRoomId: liveIdOf(room),
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
    const liveId = liveIdOf(room);
    if (RoomManager.getRoom(liveId)) await RoomManager.closeRoom(liveId, 'ended-by-host');
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
  const ids = listRoomIds().filter(isLiveId);
  if (ids.length === 0) return;
  const { rows } = await pool.query(
    `SELECT id, room_code, ends_at, status FROM scheduled_sessions
      WHERE id = ANY($1::uuid[]) AND room_code IS NOT NULL`,
    [ids],
  );
  const now = Date.now();
  for (const row of rows) {
    if (row.status === 'cancelled' || row.status === 'ended' || new Date(row.ends_at).getTime() <= now) {
      log.info({ code: row.room_code }, 'room reached its end time; closing');
      await closeRoom(row.id, 'ended-by-host').catch(() => undefined);
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
  findByCode, findByLiveId, isLiveId, liveIdOf, relationFor, decide, admissionFor, applyToRoom, detailFor, listMine, preview,
  create, update, cancel, extend, end, knock, withdrawKnock, listKnocks, admit, deny,
  joinWaitlist, leaveWaitlist, startEnforcer, capacityOf, roomUrl,
};
__RID_EOF__
echo "wrote server/src/rooms/ScheduledRooms.js"

mkdir -p server/src/routes
cat > server/src/routes/scheduledRooms.routes.js <<'__RID_EOF__'
/**
 * scheduledRooms.routes — create, plan and enter your own rooms  (Rooms)
 *
 * Links (lobby URL, QR code, calendar file) use the address the browser is
 * on (config/publicUrl.js), so they work for others, also in a Codespace.
 *
 * Mounted under /scheduled-rooms (app.js). The room itself is still joined
 * through the classroom socket at /rooms/<code>; this is everything around
 * it. Rules: rooms/roomRules.js; storage and state: rooms/ScheduledRooms.js.
 *
 *   GET    /config                     limits and defaults for the form
 *   POST   /preview                    dates a form would create, and clashes
 *   POST   /                           create (one room, or one per date of a series)
 *   GET    /mine?when=upcoming|past    rooms I host, co-host or am invited to
 *   GET    /:code                      the room as I may see it, with my entry state
 *   GET    /:code/gate                 may I enter now, and with which live room id?
 *                                     (the classroom page asks first)
 *   PATCH  /:code                      edit this date            host
 *   POST   /:code/cancel               { scope, reason }         host
 *   POST   /:code/extend               { minutes }               host, co-host
 *   POST   /:code/end                  end now for everyone      host, co-host
 *   POST   /:code/knock                ask to be let in
 *   DELETE /:code/knock
 *   GET    /:code/knocks               who is asking             host, co-host
 *   POST   /:code/admit                { userIds? } empty = all  host, co-host
 *   POST   /:code/deny                 { userId }                host, co-host
 *   POST   /:code/waitlist             wait for the next free seat
 *   DELETE /:code/waitlist
 *   GET    /:code/qr                   the link as a QR code
 *   GET    /:code/calendar.ics         the room for any calendar
 */

import { Router } from 'express';
import { z } from 'zod';

import * as Rooms from '../rooms/ScheduledRooms.js';
import * as Rules from '../rooms/roomRules.js';
import { rateLimit } from '../middleware/rateLimit.js';
import { publicAppUrlFor } from '../config/publicUrl.js';
import { route, validate, requireAuth, tenantOf, notFound, badRequest, forbidden, conflict } from './_helpers.js';

const router = Router();
router.use(requireAuth);

/** Errors the services raise with a code, as the HTTP answers clients understand. */
const asHttp = (fn) => async (req, res) => {
  try {
    return await fn(req, res);
  } catch (error) {
    if (error?.name === 'ScheduleError') {
      if (error.code === 'HOST_CONFLICT') throw conflict(error.message, error.details);
      throw badRequest(error.message);
    }
    switch (error?.code) {
      case 'validation_failed':
        throw badRequest(error.message);
      case 'forbidden':
        throw forbidden(error.message);
      case 'not_found':
        throw notFound(error.message);
      case 'conflict':
        throw conflict(error.message, error.details);
      default:
        throw error;
    }
  }
};

const handle = (fn) => route(asHttp(fn));

/** zod issues as one readable sentence. */
const parse = (schema, body) => {
  const parsed = schema.safeParse(body ?? {});
  if (!parsed.success) {
    const issue = parsed.error.issues[0];
    const where = issue?.path?.length ? `${issue.path.join('.')}: ` : '';
    throw badRequest(`${where}${issue?.message ?? 'invalid input'}`);
  }
  return parsed.data;
};

const codeParam = z.object({ code: z.string().regex(Rules.ROOM_CODE, 'not a room code') });

/** The room, or 404 — also when it exists but is not shared with this person. */
const loadRoom = async (req) => {
  const room = await Rooms.findByCode(req.params.code);
  if (!room) throw notFound('No such room');
  const relation = await Rooms.relationFor(room, { userId: req.user.id, tenantId: tenantOf(req) });
  if (!relation) throw notFound('No such room, or it is not shared with you.');
  return { room, relation };
};

const requireModerator = async (req) => {
  const loaded = await loadRoom(req);
  if (!Rules.isModerator(loaded.relation)) throw forbidden('Only the host and co-hosts can do that.');
  return loaded;
};

const requireHost = async (req) => {
  const loaded = await loadRoom(req);
  if (loaded.relation !== 'host') throw forbidden('Only the host can change this room.');
  return loaded;
};

/** Links in the answer use the address this browser is on, never localhost for a shared link. */
const detail = (req, room) =>
  Rooms.detailFor({ room, userId: req.user.id, tenantId: tenantOf(req), baseUrl: publicAppUrlFor(req) });

/* ------------------------------------------------------------------ *
 * Planning
 * ------------------------------------------------------------------ */

router.get(
  '/config',
  route(async () => ({
    earlyEntry: Rules.EARLY_ENTRY,
    duration: Rules.DURATION,
    capacity: Rules.CAPACITY,
    lateJoinOptions: Rules.LATE_JOIN_OPTIONS,
    extendOptions: Rules.EXTEND_MINUTES,
    hostEarlyMinutes: Rules.HOST_EARLY_MIN,
    limits: { invitees: Rules.MAX_INVITEES, cohosts: Rules.MAX_COHOSTS },
  })),
);

const previewBody = z
  .object({
    startsAtLocal: Rules.CreateRoomSchema.shape.startsAtLocal,
    durationMinutes: Rules.CreateRoomSchema.shape.durationMinutes,
    timeZone: z.string().min(1).max(64),
    recurrence: Rules.CreateRoomSchema.shape.recurrence,
    excludeCode: z.string().regex(Rules.ROOM_CODE).optional(),
  })
  .strict();

router.post(
  '/preview',
  rateLimit({ key: 'rooms:preview', points: 120, durationSec: 60, by: ['user'] }),
  handle(async (req) => {
    const input = parse(previewBody, req.body);
    const exclude = input.excludeCode ? await Rooms.findByCode(input.excludeCode) : null;
    return Rooms.preview({
      tenantId: tenantOf(req),
      hostId: req.user.id,
      startsAtLocal: input.startsAtLocal,
      durationMinutes: input.durationMinutes,
      timeZone: input.timeZone,
      recurrence: input.recurrence ?? null,
      excludeSessionIds: exclude && exclude.hostId === req.user.id ? [exclude.id] : [],
    });
  }),
);

router.post(
  '/',
  rateLimit({ key: 'rooms:create', points: 30, durationSec: 3600, by: ['user'] }),
  handle(async (req, res) => {
    const input = parse(Rules.CreateRoomSchema, req.body);
    const created = await Rooms.create({ input, tenantId: tenantOf(req), hostId: req.user.id });
    res.status(201).set('Location', `/scheduled-rooms/${created[0].code}`);
    return {
      room: await detail(req, created[0]),
      occurrences: created.map((room) => ({ code: room.code, startsAt: room.startsAt, endsAt: room.endsAt })),
    };
  }),
);

router.get(
  '/mine',
  validate({ query: z.object({ when: z.enum(['upcoming', 'past']).optional() }).passthrough() }),
  route(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    return Rooms.listMine({ userId: req.user.id, when: req.query.when ?? 'upcoming' });
  }),
);

/* ------------------------------------------------------------------ *
 * One room
 * ------------------------------------------------------------------ */

router.get(
  '/:code',
  validate({ params: codeParam }),
  handle(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    const { room } = await loadRoom(req);
    return detail(req, room);
  }),
);

/** Asked by the classroom page before it opens a socket. Not scheduled: enter as before. */
router.get(
  '/:code/gate',
  handle(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    if (!Rules.isRoomCode(req.params.code)) return { scheduled: false, canEnter: true };
    const room = await Rooms.findByCode(req.params.code);
    if (!room) return { scheduled: false, canEnter: true };
    const { decision } = await Rooms.decide({ room, userId: req.user.id, tenantId: tenantOf(req) });
    return {
      scheduled: true,
      canEnter: decision.allowed,
      reason: decision.code,
      message: decision.message,
      // The id the live room runs under; the code is only the link.
      roomId: decision.allowed ? Rooms.liveIdOf(room) : null,
    };
  }),
);

router.patch(
  '/:code',
  validate({ params: codeParam }),
  handle(async (req) => {
    const { room } = await requireHost(req);
    const patch = parse(Rules.UpdateRoomSchema, req.body);
    const updated = await Rooms.update({ room, patch, actorId: req.user.id });
    return detail(req, updated);
  }),
);

router.post(
  '/:code/cancel',
  validate({
    params: codeParam,
    body: z.object({ scope: z.enum(['this', 'following']).default('this'), reason: z.string().trim().max(300).nullish() }).default({}),
  }),
  handle(async (req) => {
    const { room } = await requireHost(req);
    return Rooms.cancel({ room, scope: req.body.scope, reason: req.body.reason ?? null, actorId: req.user.id });
  }),
);

router.post(
  '/:code/extend',
  validate({ params: codeParam, body: z.object({ minutes: z.number().int() }) }),
  handle(async (req) => {
    const { room } = await requireModerator(req);
    return Rooms.extend({ room, minutes: req.body.minutes });
  }),
);

router.post(
  '/:code/end',
  validate({ params: codeParam }),
  handle(async (req) => {
    const { room } = await requireModerator(req);
    return Rooms.end({ room });
  }),
);

/* ------------------------------------------------------------------ *
 * Lobby
 * ------------------------------------------------------------------ */

router.post(
  '/:code/knock',
  rateLimit({ key: 'rooms:knock', points: 20, durationSec: 300, by: ['user'] }),
  validate({ params: codeParam }),
  handle(async (req) => {
    const { room, relation } = await loadRoom(req);
    if (!room.approval || Rules.isModerator(relation)) return detail(req, room);
    const phase = Rules.phaseOf(room);
    if (phase !== 'doors-open' && phase !== 'live') throw badRequest('The doors are not open yet.');
    await Rooms.knock({ room, user: { userId: req.user.id, displayName: req.user.displayName } });
    return detail(req, room);
  }),
);

router.delete(
  '/:code/knock',
  validate({ params: codeParam }),
  handle(async (req) => {
    const { room } = await loadRoom(req);
    await Rooms.withdrawKnock(room, req.user.id);
    return detail(req, room);
  }),
);

router.get(
  '/:code/knocks',
  validate({ params: codeParam }),
  handle(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    const { room } = await requireModerator(req);
    return { items: await Rooms.listKnocks(room) };
  }),
);

router.post(
  '/:code/admit',
  validate({ params: codeParam, body: z.object({ userIds: z.array(z.string().uuid()).max(300).default([]) }).default({}) }),
  handle(async (req) => {
    const { room } = await requireModerator(req);
    return Rooms.admit({ room, userIds: req.body.userIds });
  }),
);

router.post(
  '/:code/deny',
  validate({ params: codeParam, body: z.object({ userId: z.string().uuid() }) }),
  handle(async (req) => {
    const { room } = await requireModerator(req);
    return Rooms.deny({ room, userId: req.body.userId });
  }),
);

router.post(
  '/:code/waitlist',
  validate({ params: codeParam }),
  handle(async (req) => {
    const { room } = await loadRoom(req);
    await Rooms.joinWaitlist({ room, userId: req.user.id });
    return detail(req, room);
  }),
);

router.delete(
  '/:code/waitlist',
  validate({ params: codeParam }),
  handle(async (req) => {
    const { room } = await loadRoom(req);
    await Rooms.leaveWaitlist({ room, userId: req.user.id });
    return detail(req, room);
  }),
);

/* ------------------------------------------------------------------ *
 * Sharing
 * ------------------------------------------------------------------ */

/** The link as a QR code. Uses qrcode (installed with Settings Phase C); 404 without it. */
router.get(
  '/:code/qr',
  validate({ params: codeParam }),
  handle(async (req, res) => {
    const { room } = await loadRoom(req);
    let QRCode;
    try {
      const imported = await import('qrcode');
      QRCode = imported.default ?? imported;
    } catch {
      throw notFound('QR codes are not available on this server.');
    }
    res.set('Cache-Control', 'private, max-age=3600');
    return { dataUrl: await QRCode.toDataURL(Rooms.roomUrl(room.code, publicAppUrlFor(req)), { margin: 1, width: 264, errorCorrectionLevel: 'M' }) };
  }),
);

/* ------------------------------------------------------------------ *
 * Calendar
 * ------------------------------------------------------------------ */

router.get(
  '/:code/calendar.ics',
  validate({ params: codeParam }),
  // Not route(): the answer is a file, not JSON. Errors still go to the error handler.
  (req, res, next) =>
    asHttp(async () => {
      const { room } = await loadRoom(req);
      res.set('Content-Type', 'text/calendar; charset=utf-8');
      res.set('Content-Disposition', `attachment; filename="${room.code}.ics"`);
      res.set('Cache-Control', 'no-store');
      res.send(Rules.icsFor({ room, url: Rooms.roomUrl(room.code, publicAppUrlFor(req)) }));
    })(req, res).catch(next),
);

export default router;
__RID_EOF__
echo "wrote server/src/routes/scheduledRooms.routes.js"

mkdir -p packages/core-client/src/api
cat > packages/core-client/src/api/roomsApi.ts <<'__RID_EOF__'
/**
 * Rooms API  (Rooms: create your own room)
 *
 * Planning, the lobby and the host's controls for rooms people create
 * themselves. Paths are the server's (server/src/routes/scheduledRooms.routes.js,
 * mounted under /scheduled-rooms). The room is still joined through the
 * classroom socket at /rooms/<code>.
 *
 * Links in answers (lobby URL, QR code, calendar file) are built by the
 * server for the address this page is on: the page's origin travels along
 * as ?origin=, and the server only uses it when it trusts it.
 */

import { z } from 'zod';
import type { HttpClient } from '../http/httpClient.js';

const Person = z
  .object({ userId: z.string(), displayName: z.string(), handle: z.string().nullable().default(null) })
  .passthrough();
export type RoomPerson = z.infer<typeof Person>;

export const RoomPhaseSchema = z.enum(['scheduled', 'doors-open', 'live', 'ended', 'cancelled']);
export type RoomPhase = z.infer<typeof RoomPhaseSchema>;

export const RoomDetailSchema = z
  .object({
    code: z.string(),
    sessionId: z.string(),
    liveRoomId: z.string().nullable().default(null),
    seriesId: z.string().nullable().default(null),
    title: z.string(),
    description: z.string().nullable().default(null),
    agenda: z.string().nullable().default(null),
    startsAt: z.string(),
    endsAt: z.string(),
    timeZone: z.string(),
    doorsOpenAt: z.string(),
    hostOpensAt: z.string(),
    lateUntil: z.string().nullable().default(null),
    earlyEntryMinutes: z.number(),
    lateJoinMinutes: z.number().nullable().default(null),
    status: z.string(),
    phase: RoomPhaseSchema,
    access: z.enum(['invited', 'link']),
    approval: z.boolean(),
    capacity: z.number().nullable().default(null),
    effectiveCapacity: z.number(),
    occupied: z.number().default(0),
    settings: z
      .object({
        learnersJoinMuted: z.boolean().nullable().default(null),
        reactionsEnabled: z.boolean().nullable().default(null),
        learnersMayShare: z.boolean().nullable().default(null),
      })
      .passthrough(),
    host: Person,
    cohosts: z.array(Person).default([]),
    invitees: z.array(Person).optional(),
    url: z.string(),
    cancelReason: z.string().nullable().default(null),
    viewer: z
      .object({
        relation: z.enum(['host', 'cohost', 'invitee', 'guest']),
        moderator: z.boolean(),
        canEnter: z.boolean(),
        reason: z.string().nullable().default(null),
        message: z.string().nullable().default(null),
        opensAt: z.string().nullable().default(null),
        knocked: z.boolean().default(false),
        admitted: z.boolean().default(false),
        waitlistPosition: z.number().nullable().default(null),
        holdUntil: z.string().nullable().default(null),
      })
      .passthrough(),
    serverTime: z.string(),
  })
  .passthrough();
export type RoomDetail = z.infer<typeof RoomDetailSchema>;

export const RoomListItemSchema = z
  .object({
    code: z.string(),
    sessionId: z.string(),
    seriesId: z.string().nullable().default(null),
    title: z.string(),
    startsAt: z.string(),
    endsAt: z.string(),
    doorsOpenAt: z.string(),
    timeZone: z.string(),
    status: z.string(),
    phase: RoomPhaseSchema,
    access: z.string(),
    capacity: z.number().nullable().default(null),
    inviteeCount: z.number().default(0),
    hostName: z.string().nullable().default(null),
    relation: z.enum(['host', 'cohost', 'invitee']),
  })
  .passthrough();
export type RoomListItem = z.infer<typeof RoomListItemSchema>;

const ConfigSchema = z
  .object({
    earlyEntry: z.object({ min: z.number(), max: z.number(), default: z.number() }),
    duration: z.object({ min: z.number(), max: z.number(), presets: z.array(z.number()) }),
    capacity: z.object({ min: z.number(), max: z.number(), default: z.number() }),
    lateJoinOptions: z.array(z.number().nullable()),
    extendOptions: z.array(z.number()),
    hostEarlyMinutes: z.number(),
    limits: z.object({ invitees: z.number(), cohosts: z.number() }),
  })
  .passthrough();
export type RoomsConfig = z.infer<typeof ConfigSchema>;

const PreviewSchema = z
  .object({
    occurrences: z.array(z.object({ startsAt: z.string(), endsAt: z.string() })),
    conflicts: z.array(
      z.object({ at: z.string(), title: z.string(), startsAt: z.string().nullable(), endsAt: z.string().nullable() }).passthrough(),
    ),
    adjusted: z.string().nullable().default(null),
    inPast: z.boolean().default(false),
  })
  .passthrough();
export type RoomPreview = z.infer<typeof PreviewSchema>;

const GateSchema = z
  .object({
    scheduled: z.boolean(),
    canEnter: z.boolean(),
    reason: z.string().nullable().optional(),
    message: z.string().nullable().optional(),
    /** The live room's id (a UUID) for scheduled rooms; the link's code is not one. */
    roomId: z.string().nullable().optional(),
  })
  .passthrough();
export type RoomGate = z.infer<typeof GateSchema>;

const KnocksSchema = z.object({
  items: z.array(z.object({ userId: z.string(), displayName: z.string(), at: z.string().nullable() }).passthrough()),
});

export interface RoomRecurrence {
  freq: 'DAILY' | 'WEEKLY';
  interval?: number;
  byDay?: Array<'MO' | 'TU' | 'WE' | 'TH' | 'FR' | 'SA' | 'SU'>;
  count?: number;
  until?: string;
}

export interface RoomInput {
  title: string;
  description?: string | null;
  startsAtLocal: string;
  durationMinutes: number;
  timeZone: string;
  earlyEntryMinutes?: number;
  lateJoinMinutes?: number | null;
  capacity?: number | null;
  access?: 'invited' | 'link';
  approval?: boolean;
  inviteeIds?: string[];
  cohostIds?: string[];
  settings?: {
    learnersJoinMuted?: boolean;
    reactionsEnabled?: boolean;
    learnersMayShare?: boolean;
    agenda?: string | null;
  };
  recurrence?: RoomRecurrence | null;
}

export interface RoomsApi {
  config(signal?: AbortSignal): Promise<RoomsConfig>;
  preview(
    input: Pick<RoomInput, 'startsAtLocal' | 'durationMinutes' | 'timeZone' | 'recurrence'> & { excludeCode?: string },
    signal?: AbortSignal,
  ): Promise<RoomPreview>;
  create(input: RoomInput): Promise<{ room: RoomDetail; occurrences: Array<{ code: string; startsAt: string; endsAt: string }> }>;
  mine(when?: 'upcoming' | 'past', signal?: AbortSignal): Promise<{ items: RoomListItem[] }>;
  get(code: string, signal?: AbortSignal): Promise<RoomDetail>;
  gate(code: string, signal?: AbortSignal): Promise<RoomGate>;
  update(code: string, patch: Partial<Omit<RoomInput, 'recurrence'>>): Promise<RoomDetail>;
  cancel(code: string, input?: { scope?: 'this' | 'following'; reason?: string | null }): Promise<{ cancelled: number }>;
  extend(code: string, minutes: number): Promise<{ endsAt: string }>;
  end(code: string): Promise<{ ended: boolean }>;
  knock(code: string): Promise<RoomDetail>;
  withdrawKnock(code: string): Promise<RoomDetail>;
  knocks(code: string, signal?: AbortSignal): Promise<z.infer<typeof KnocksSchema>>;
  admit(code: string, userIds?: string[]): Promise<{ admitted: number }>;
  deny(code: string, userId: string): Promise<{ denied: boolean }>;
  joinWaitlist(code: string): Promise<RoomDetail>;
  leaveWaitlist(code: string): Promise<RoomDetail>;
  /** The .ics file, for a download link. */
  calendarFile(code: string): Promise<Blob>;
  /** The link as a QR code (a data: URL), for a slide or a printed sheet. */
  qr(code: string): Promise<{ dataUrl: string }>;
}

const BASE = '/scheduled-rooms';
const path = (code: string, rest = '') => `${BASE}/${encodeURIComponent(code)}${rest}`;
const once = { retry: { attempts: 1 } };

/** This page's address, for links the server builds (browsers only). */
const pageOrigin = (): string | undefined => {
  const location = (globalThis as { location?: { origin?: string } }).location;
  return location?.origin && location.origin !== 'null' ? location.origin : undefined;
};

export const createRoomsApi = (http: HttpClient): RoomsApi => ({
  config: (signal) => http.get(`${BASE}/config`, { schema: ConfigSchema, signal }),

  preview: (input, signal) => http.post(`${BASE}/preview`, input, { schema: PreviewSchema, signal, ...once }),

  create: (input) =>
    http.post(BASE, input, {
      schema: z
        .object({
          room: RoomDetailSchema,
          occurrences: z.array(z.object({ code: z.string(), startsAt: z.string(), endsAt: z.string() })),
        })
        .passthrough(),
      ...once,
    }),

  mine: (when = 'upcoming', signal) =>
    http.get(`${BASE}/mine`, { schema: z.object({ items: z.array(RoomListItemSchema) }), query: { when }, signal }),

  get: (code, signal) => http.get(path(code), { schema: RoomDetailSchema, query: { origin: pageOrigin() }, signal }),

  gate: (code, signal) => http.get(path(code, '/gate'), { schema: GateSchema, signal, retry: { attempts: 2 } }),

  update: (code, patch) => http.patch(path(code), patch, { schema: RoomDetailSchema }),

  cancel: (code, input = {}) =>
    http.post(path(code, '/cancel'), input, { schema: z.object({ cancelled: z.number() }).passthrough(), ...once }),

  extend: (code, minutes) =>
    http.post(path(code, '/extend'), { minutes }, { schema: z.object({ endsAt: z.string() }).passthrough(), ...once }),

  end: (code) => http.post(path(code, '/end'), {}, { schema: z.object({ ended: z.boolean() }).passthrough(), ...once }),

  knock: (code) => http.post(path(code, '/knock'), {}, { schema: RoomDetailSchema, ...once }),

  withdrawKnock: (code) => http.delete(path(code, '/knock'), { schema: RoomDetailSchema }),

  knocks: (code, signal) => http.get(path(code, '/knocks'), { schema: KnocksSchema, signal }),

  admit: (code, userIds = []) =>
    http.post(path(code, '/admit'), { userIds }, { schema: z.object({ admitted: z.number() }).passthrough() }),

  deny: (code, userId) =>
    http.post(path(code, '/deny'), { userId }, { schema: z.object({ denied: z.boolean() }).passthrough() }),

  joinWaitlist: (code) => http.post(path(code, '/waitlist'), {}, { schema: RoomDetailSchema, ...once }),

  leaveWaitlist: (code) => http.delete(path(code, '/waitlist'), { schema: RoomDetailSchema }),

  qr: (code) =>
    http.get(path(code, '/qr'), {
      schema: z.object({ dataUrl: z.string() }).passthrough(),
      query: { origin: pageOrigin() },
      retry: { attempts: 1 },
    }),

  calendarFile: async (code) => {
    const origin = pageOrigin();
    const query = origin ? `?origin=${encodeURIComponent(origin)}` : '';
    const response = await http.raw('GET', `${path(code, '/calendar.ics')}${query}`);
    if (!response.ok) throw new Error('The calendar file could not be downloaded.');
    return response.blob();
  },
});
__RID_EOF__
echo "wrote packages/core-client/src/api/roomsApi.ts"

mkdir -p apps/web/src/lib
cat > apps/web/src/lib/useRoomGate.js <<'__RID_EOF__'
import { useEffect, useMemo, useState } from 'react';
import { createRoomsApi, useCore } from '@classroom/core-client';

/**
 * May this person enter this room right now?  (Rooms)
 *
 * Asked by the classroom page before it opens a socket, so someone who
 * arrives too early, uninvited or without a seat lands in the lobby instead
 * of on an error. Only scheduled rooms (codes like "kqz-7hfd-2mx") are asked
 * about; any other room id — and any failure to ask — enters as before. The
 * socket join checks again either way.
 *
 * `roomId` in the answer is the id the live room runs under (the session's
 * UUID). The code in the link is only the link: the lesson chat, blocks and
 * profiles expect a UUID and refuse anything else.
 */
const ROOM_CODE = /^[a-hjkmnp-z2-9]{3}-[a-hjkmnp-z2-9]{4}-[a-hjkmnp-z2-9]{3}$/;

export const isRoomCode = (value) => ROOM_CODE.test(String(value ?? ''));

export function useRoomGate(roomId) {
  const { http, status } = useCore();
  const rooms = useMemo(() => createRoomsApi(http), [http]);
  const scheduled = isRoomCode(roomId);
  const [gate, setGate] = useState({ ready: !scheduled, canEnter: true, scheduled, reason: null, roomId: null });

  useEffect(() => {
    if (!scheduled) {
      setGate({ ready: true, canEnter: true, scheduled: false, reason: null, roomId: null });
      return undefined;
    }
    if (status !== 'authenticated') return undefined;
    const controller = new AbortController();
    rooms
      .gate(roomId, controller.signal)
      .then((answer) =>
        setGate({
          ready: true,
          canEnter: answer.canEnter,
          scheduled: answer.scheduled,
          reason: answer.reason ?? null,
          roomId: answer.roomId ?? null,
        }),
      )
      .catch(() => {
        // Could not ask: go to the lobby, which explains and retries, rather
        // than joining under the code.
        if (!controller.signal.aborted) setGate({ ready: true, canEnter: false, scheduled: true, reason: null, roomId: null });
      });
    return () => controller.abort();
  }, [rooms, roomId, scheduled, status]);

  return gate;
}

export default useRoomGate;
__RID_EOF__
echo "wrote apps/web/src/lib/useRoomGate.js"

cat > .rooms-roomid-patch.mjs <<'__RID_EOF__'
import { existsSync, readFileSync, writeFileSync } from 'node:fs';

/*
 * Rooms · live room id — the classroom page joins a scheduled room under its
 * session UUID, and hands that id to everything in the room (lesson chat,
 * blocks, profiles). The code stays in the address bar.
 * Every anchor must be found exactly once; otherwise nothing is written.
 */

const plan = [
  {
    file: 'apps/web/src/pages/ClassroomPage.jsx',
    marker: 'liveRoomId',
    edits: [
      {
        name: 'the id the live room runs under',
        find: '  const gate = useRoomGate(roomId);\n',
        replace:
          '  const gate = useRoomGate(roomId);\n' +
          '  // The live room\'s id: a scheduled room runs under its session UUID (the\n' +
          '  // code in the address is only the link); every other room under its URL id.\n' +
          '  const liveRoomId = gate.scheduled ? gate.roomId : roomId;\n',
      },
      {
        name: 'join with it',
        find:
          '      roomId,\n' +
          "      autoJoin: status === 'authenticated' && gate.ready && gate.canEnter,\n",
        replace:
          '      roomId: liveRoomId,\n' +
          "      autoJoin: status === 'authenticated' && gate.ready && gate.canEnter && Boolean(liveRoomId),\n",
      },
      {
        name: 'dependencies',
        find: '    [sfu, deviceAdapter, roomId, status, onReaction, gate.ready, gate.canEnter],\n',
        replace: '    [sfu, deviceAdapter, liveRoomId, status, onReaction, gate.ready, gate.canEnter],\n',
      },
      {
        name: 'lesson chat, blocks and profiles get the UUID, not the code',
        find: '            roomId={roomId}\n',
        replace: '            roomId={liveRoomId}\n',
      },
    ],
  },
];

const results = [];
for (const entry of plan) {
  if (!existsSync(entry.file)) {
    console.error(`${entry.file}: not found. Nothing was changed.`);
    process.exit(1);
  }
  let src = readFileSync(entry.file, 'utf8');
  if (src.includes(entry.marker)) {
    console.log(`${entry.file}: already patched, nothing to do`);
    continue;
  }
  for (const edit of entry.edits) {
    const n = src.split(edit.find).length - 1;
    if (n !== 1) {
      console.error(`${entry.file}: "${edit.name}": expected the anchor exactly once, found ${n}. Nothing was changed.`);
      process.exit(1);
    }
  }
  for (const edit of entry.edits) src = src.replace(edit.find, () => edit.replace);
  results.push({ ...entry, src });
}
for (const entry of results) {
  writeFileSync(entry.file, entry.src);
  console.log('patched', entry.file);
  for (const edit of entry.edits) console.log('  -', edit.name);
}
__RID_EOF__
node .rooms-roomid-patch.mjs
rm -f .rooms-roomid-patch.mjs

echo "--- checks"
ESBUILD=""
[ -x node_modules/.bin/esbuild ] && ESBUILD=node_modules/.bin/esbuild
FAILED=0
for f in "${TOUCHED[@]}"; do
  [ -f "$f" ] || continue
  case "$f" in
    *.js|*.mjs) if node --check "$f"; then echo "ok  $f"; else FAILED=1; fi ;;
    *.ts) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.ts=ts --log-level=error >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
    *.jsx) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.jsx=jsx --jsx=automatic --log-level=error >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
    *) echo "ok  $f" ;;
  esac
done
if [ "$FAILED" -ne 0 ]; then
  echo "A file did not pass its check (see above). Undo with: bash rooms-roomid-install.sh --restore" >&2
  exit 1
fi

echo "--- rules (node --test)"
CHECKS=$(ls server/test/settings/*.check.mjs server/test/rooms/*.check.mjs \
  apps/web/src/components/Settings/__checks__/*.check.mjs apps/web/src/components/Rooms/__checks__/*.check.mjs 2>/dev/null || true)
if node --test $CHECKS > .rooms-roomid-test.log 2>&1; then
  PASSED=$(grep -E '^(# |ℹ )pass [0-9]+' .rooms-roomid-test.log | tail -1 | awk '{print $NF}')
  echo "ok  ${PASSED:-all} rule tests passed"
  rm -f .rooms-roomid-test.log
else
  cat .rooms-roomid-test.log
  rm -f .rooms-roomid-test.log
  echo "The rule checks failed (see above). Undo with: bash rooms-roomid-install.sh --restore" >&2
  exit 1
fi

touch server/src/server.js
[ -f server/src/worker.js ] && touch server/src/worker.js
echo
echo "Fixed. The API restarts on its own. Leave any open room, reload the browser"
echo "tabs with Ctrl+Shift+R and enter again from the lobby: private messages, the"
echo "lesson chat and profile cards now work in scheduled rooms."