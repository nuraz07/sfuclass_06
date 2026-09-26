#!/usr/bin/env bash
# rooms-install.sh — Rooms: create your own room, with doors, seats, guests and a lobby.
#
# Run from the project folder (the one containing server/, packages/ and apps/):
#   bash rooms-install.sh
#
# Writes 17 files, patches 6 more, keeps a backup of every file it touches
# in .rooms-backup/<timestamp>/, checks all of them, runs the rule tests,
# applies migration 024 and restarts API and worker.
# Undo: bash rooms-install.sh --restore   (back to the state before the first install;
#       the columns added by 024 stay — they are unused without these files)
set -euo pipefail

if [ ! -d server/src/messaging ] || [ ! -d packages/core-client/src ] || [ ! -d apps/web/src ]; then
  echo "Run this from the project folder (the one that contains server/, packages/ and apps/)." >&2
  exit 1
fi

TOUCHED=(
  server/src/db/migrations/024_scheduled_rooms.sql
  server/src/rooms/roomRules.js
  server/src/rooms/ScheduledRooms.js
  server/src/routes/scheduledRooms.routes.js
  server/test/rooms/roomRules.check.mjs
  packages/core-client/src/api/roomsApi.ts
  apps/web/src/lib/useRoomGate.js
  apps/web/src/pages/DashboardPage.jsx
  apps/web/src/pages/RoomEditorPage.jsx
  apps/web/src/pages/RoomLobbyPage.jsx
  apps/web/src/components/Rooms/roomModel.js
  apps/web/src/components/Rooms/RoomCard.jsx
  apps/web/src/components/Rooms/PeoplePicker.jsx
  apps/web/src/components/Rooms/DeviceCheck.jsx
  apps/web/src/components/Rooms/RoomClock.jsx
  apps/web/src/components/Rooms/rooms.css
  apps/web/src/components/Rooms/__checks__/roomModel.check.mjs
  server/src/app.js
  server/src/signaling/socketHandlers.js
  server/src/queues/workers/notificationWorker.js
  packages/core-client/src/index.ts
  apps/web/src/main.jsx
  apps/web/src/pages/ClassroomPage.jsx
)

if [ "${1:-}" = "--restore" ]; then
  FIRST=$(ls -1d .rooms-backup/* 2>/dev/null | head -1 || true)
  [ -n "$FIRST" ] || { echo "No backup found." >&2; exit 1; }
  for f in "${TOUCHED[@]}"; do
    if [ -f "$FIRST/$f" ]; then mkdir -p "$(dirname "$f")"; cp "$FIRST/$f" "$f"; echo "restored $f";
    elif [ -f "$f" ] && [ "$f" != "server/src/db/migrations/024_scheduled_rooms.sql" ]; then rm "$f"; echo "removed $f (did not exist before)"; fi
  done
  touch server/src/server.js 2>/dev/null || true
  [ -f server/src/worker.js ] && touch server/src/worker.js || true
  echo "Restored from $FIRST. The migration file 024 stays, because the database already has it."
  exit 0
fi

# ---------------------------------------------------------------------------
# Is this the tree the rooms feature was written for? Nothing is changed if not.
# ---------------------------------------------------------------------------
MISSING=()
need() { # need <file> <text> <why>
  if [ ! -f "$1" ]; then MISSING+=("$1 is missing ($3)");
  elif ! grep -qF -- "$2" "$1"; then MISSING+=("$1 has no '$2' ($3)"); fi
}
need server/src/routes/accountSecurity.routes.js "router" "Settings Phase C"
need server/src/queues/workers/notificationWorker.js "account.deletion" "Settings Phase C"
need apps/web/src/lib/userEvents.js "onUserEvent" "Settings Phase B"
need apps/web/src/lib/preferences.js "mediaConstraints" "Settings Phase A"
need server/src/scheduling/ScheduleService.js "export function expandRecurrence" "scheduling"
need server/src/scheduling/ScheduleService.js "export function parseLocalDateTime" "scheduling"
need server/src/scheduling/ScheduleService.js "export async function findHostConflicts" "scheduling"
need server/src/scheduling/ScheduleService.js "export async function cancelSession" "scheduling"
need server/src/scheduling/ReminderRules.js "export async function syncForSession" "reminders"
need server/src/scheduling/ReminderRules.js "export async function enqueueDue" "reminders"
need server/src/capacity/CapacityGuard.js "export const occupancy" "seats"
need server/src/classroom/RoomManager.js "export const listRoomIds" "rooms on this node"
need server/src/classroom/RoomManager.js "export const closeRoom" "rooms on this node"
need server/src/routes/_helpers.js "conflict" "routes"
need server/src/db/migrations/010_scheduling.sql "scheduled_sessions" "scheduling tables"
need packages/core-client/src/api/profileApi.ts "search(" "people picker"
if ls server/src/db/migrations/024_*.sql 2>/dev/null | grep -qv 024_scheduled_rooms.sql; then
  MISSING+=("another migration 024 exists: $(ls server/src/db/migrations/024_*.sql | tr '\n' ' ')")
fi
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "This tree does not match what the rooms feature expects. Nothing was changed:" >&2
  for m in "${MISSING[@]}"; do echo "  - $m" >&2; done
  exit 1
fi

BACKUP=".rooms-backup/$(date +%Y%m%d-%H%M%S)"
for f in "${TOUCHED[@]}"; do
  if [ -f "$f" ]; then mkdir -p "$BACKUP/$(dirname "$f")"; cp "$f" "$BACKUP/$f"; fi
done
echo "backup: $BACKUP"

mkdir -p server/src/db/migrations
cat > server/src/db/migrations/024_scheduled_rooms.sql <<'__RM_EOF__'
-- 024_scheduled_rooms.sql  (Rooms: create your own room)
--
-- A room someone creates is a scheduled session (010) with a room of its own.
-- The session row stays the source of truth for time, host, invitees and
-- reminders, so the calendar feed, the reminder sweep and "who is invited"
-- keep working unchanged. What a self-created room adds:
--
--   room_code       the id in its link (/rooms/<code>), unique, unguessable
--   early_entry_min when the doors open: 3 to 10 minutes before the start
--   late_join_min   optional: nobody new after this many minutes past the
--                   start (people who were already in may always come back)
--   capacity        seats; null means the plan's limit
--   access          'invited'  host, co-hosts and invitees only
--                   'link'     anyone in the organisation who has the link
--   approval        people knock in the lobby and a host lets them in
--   cohost_ids      co-hosts: may enter early, admit people, extend and end
--   room_settings   how the room starts (muted learners, reactions, screen
--                   sharing) and the agenda
--
-- Additive only; lessons scheduled before this stay as they were.

alter table scheduled_sessions add column if not exists room_code       text;
alter table scheduled_sessions add column if not exists early_entry_min integer not null default 5;
alter table scheduled_sessions add column if not exists late_join_min   integer;
alter table scheduled_sessions add column if not exists capacity        integer;
alter table scheduled_sessions add column if not exists access          text    not null default 'invited';
alter table scheduled_sessions add column if not exists approval        boolean not null default false;
alter table scheduled_sessions add column if not exists cohost_ids      uuid[]  not null default '{}';
alter table scheduled_sessions add column if not exists room_settings   jsonb   not null default '{}'::jsonb;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'scheduled_sessions_early_entry_check') then
    alter table scheduled_sessions add constraint scheduled_sessions_early_entry_check
      check (early_entry_min between 3 and 10);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'scheduled_sessions_late_join_check') then
    alter table scheduled_sessions add constraint scheduled_sessions_late_join_check
      check (late_join_min is null or late_join_min between 0 and 120);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'scheduled_sessions_capacity_check') then
    alter table scheduled_sessions add constraint scheduled_sessions_capacity_check
      check (capacity is null or capacity between 2 and 1000);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'scheduled_sessions_access_check') then
    alter table scheduled_sessions add constraint scheduled_sessions_access_check
      check (access in ('invited', 'link'));
  end if;
end $$;

create unique index if not exists scheduled_sessions_room_code_key
  on scheduled_sessions (room_code) where room_code is not null;

-- "My rooms": what someone hosts, co-hosts or is invited to, by time.
create index if not exists scheduled_sessions_host_rooms_idx
  on scheduled_sessions (host_id, starts_at) where room_code is not null;
create index if not exists scheduled_sessions_cohosts_idx
  on scheduled_sessions using gin (cohost_ids) where room_code is not null;
__RM_EOF__
echo "wrote server/src/db/migrations/024_scheduled_rooms.sql"

mkdir -p server/src/rooms
cat > server/src/rooms/roomRules.js <<'__RM_EOF__'
// classroom-app/server/src/rooms/roomRules.js
/**
 * Rules for rooms people create themselves  (Rooms)
 *
 * The one definition of when a room may be entered and by whom, and what a
 * valid room looks like. Pure: no database, no Redis, no clock of its own —
 * the API, the socket join and the tests call the same functions, so the
 * lobby's countdown and the server's refusal can never disagree.
 *
 * The timeline of one room:
 *
 *   hostOpensAt   start − 30 min   hosts and co-hosts may come in and prepare
 *   doorsOpenAt   start − 3…10 min everyone else (the room's "doors" setting)
 *   startsAt
 *   lateUntil     start + N min    optional: nobody new after this; people who
 *                                  were already in may always come back
 *   endsAt                         the room closes (a host can extend it)
 */

import { randomInt } from 'node:crypto';
import { z } from 'zod';

export const EARLY_ENTRY = Object.freeze({ min: 3, max: 10, default: 5 });
export const HOST_EARLY_MIN = 30;
export const DURATION = Object.freeze({ min: 10, max: 8 * 60, presets: [30, 45, 60, 90] });
export const CAPACITY = Object.freeze({ min: 2, max: 300, default: 25 });
export const LATE_JOIN_OPTIONS = Object.freeze([null, 0, 5, 10, 15, 30]);
export const EXTEND_MINUTES = Object.freeze([5, 10, 15, 30]);
/** How long a freed seat is held for the next person on the waiting list. */
export const HOLD_MS = 2 * 60_000;
/** The warning before a room closes. */
export const ENDING_SOON_MS = 5 * 60_000;
export const MAX_INVITEES = 300;
export const MAX_COHOSTS = 10;

const MINUTE = 60_000;
const ms = (value) => (value instanceof Date ? value.getTime() : new Date(value).getTime());

// ---------------------------------------------------------------------------
// Room codes
// ---------------------------------------------------------------------------

/** No look-alikes (0/o, 1/l/i): a code read out loud or typed from a slide still works. */
const ALPHABET = 'abcdefghjkmnpqrstuvwxyz23456789';

/** "kqz-7hfd-2mx": 10 random characters, ~49 bits — the link is the key for 'link' rooms. */
export const newRoomCode = () => {
  const chars = Array.from({ length: 10 }, () => ALPHABET[randomInt(ALPHABET.length)]).join('');
  return `${chars.slice(0, 3)}-${chars.slice(3, 7)}-${chars.slice(7)}`;
};

export const ROOM_CODE = /^[a-hjkmnp-z2-9]{3}-[a-hjkmnp-z2-9]{4}-[a-hjkmnp-z2-9]{3}$/;
export const isRoomCode = (value) => ROOM_CODE.test(String(value ?? ''));

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

export const RoomSettingsSchema = z
  .object({
    learnersJoinMuted: z.boolean(),
    reactionsEnabled: z.boolean(),
    learnersMayShare: z.boolean(),
    agenda: z.string().max(2000).nullable(),
  })
  .partial()
  .strict();

const recurrence = z
  .object({
    freq: z.enum(['DAILY', 'WEEKLY']),
    interval: z.number().int().min(1).max(4).optional(),
    byDay: z.array(z.enum(['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'])).max(7).optional(),
    count: z.number().int().min(2).max(52).optional(),
    until: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
  })
  .strict()
  .refine((value) => value.count || value.until, 'a series needs an end: a number of dates or a last date');

const localDateTime = z.string().regex(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/, 'a date and time such as 2026-10-01T18:00');

export const CreateRoomSchema = z
  .object({
    title: z.string().trim().min(1).max(120),
    description: z.string().trim().max(2000).nullish(),
    startsAtLocal: localDateTime,
    durationMinutes: z.number().int().min(DURATION.min).max(DURATION.max),
    timeZone: z.string().min(1).max(64),
    earlyEntryMinutes: z.number().int().min(EARLY_ENTRY.min).max(EARLY_ENTRY.max).default(EARLY_ENTRY.default),
    lateJoinMinutes: z.number().int().min(0).max(120).nullable().default(null),
    capacity: z.number().int().min(CAPACITY.min).max(1000).nullable().default(null),
    access: z.enum(['invited', 'link']).default('invited'),
    approval: z.boolean().default(false),
    inviteeIds: z.array(z.string().uuid()).max(MAX_INVITEES).default([]),
    cohostIds: z.array(z.string().uuid()).max(MAX_COHOSTS).default([]),
    settings: RoomSettingsSchema.default({}),
    recurrence: recurrence.nullish(),
  })
  .strict();

/** Editing one occurrence: any field of the create input except the series. */
export const UpdateRoomSchema = CreateRoomSchema.omit({ recurrence: true }).partial().strict();

// ---------------------------------------------------------------------------
// Time
// ---------------------------------------------------------------------------

/** Every moment of a room's timeline, as epoch milliseconds. */
export const windowFor = (room) => {
  const startsAt = ms(room.startsAt);
  const endsAt = ms(room.endsAt);
  const early = clampEarly(room.earlyEntryMinutes);
  return {
    hostOpensAt: startsAt - HOST_EARLY_MIN * MINUTE,
    doorsOpenAt: startsAt - early * MINUTE,
    startsAt,
    lateUntil: room.lateJoinMinutes == null ? null : startsAt + room.lateJoinMinutes * MINUTE,
    endsAt,
  };
};

export const clampEarly = (value) => {
  const number = Number(value);
  if (!Number.isFinite(number)) return EARLY_ENTRY.default;
  return Math.min(EARLY_ENTRY.max, Math.max(EARLY_ENTRY.min, Math.round(number)));
};

/** 'scheduled' · 'doors-open' · 'live' · 'ended' · 'cancelled' — what the lobby shows. */
export const phaseOf = (room, now = Date.now()) => {
  if (room.status === 'cancelled') return 'cancelled';
  const time = windowFor(room);
  if (room.status === 'ended' || now >= time.endsAt) return 'ended';
  if (now >= time.startsAt) return 'live';
  if (now >= time.doorsOpenAt) return 'doors-open';
  return 'scheduled';
};

// ---------------------------------------------------------------------------
// Who may come in
// ---------------------------------------------------------------------------

/** 'host' · 'cohost' · 'invitee' · 'guest' (link rooms) · null (no access). */
export const relationOf = (room, { userId, invited = false, sameTenant = true }) => {
  if (!userId) return null;
  if (room.hostId === userId) return 'host';
  if ((room.cohostIds ?? []).includes(userId)) return 'cohost';
  if (invited) return 'invitee';
  if (room.access === 'link' && sameTenant) return 'guest';
  return null;
};

export const isModerator = (relation) => relation === 'host' || relation === 'cohost';

/**
 * May this person enter now? Checked by the lobby (to show the right screen)
 * and again by the socket join (to refuse whatever the lobby did not stop).
 *
 * @param {{
 *   room: object, relation: string|null, now?: number,
 *   joinedBefore?: boolean, admitted?: boolean,
 *   occupiedByOthers?: number, heldForOthers?: number, holdsSeat?: boolean,
 *   capacity?: number|null,
 * }} input
 * @returns {{ allowed: boolean, code: string|null, message: string|null, opensAt: number|null }}
 */
export const entryDecision = ({
  room,
  relation,
  now = Date.now(),
  joinedBefore = false,
  admitted = false,
  occupiedByOthers = 0,
  heldForOthers = 0,
  holdsSeat = false,
  capacity = room.capacity ?? null,
}) => {
  const time = windowFor(room);
  const deny = (code, message, opensAt = null) => ({ allowed: false, code, message, opensAt });

  if (!relation) return deny('not_invited', 'This room is for invited people only.');
  if (room.status === 'cancelled') return deny('room_cancelled', 'This room was cancelled.');
  if (room.status === 'ended' || now >= time.endsAt) return deny('room_ended', 'This room has ended.');

  const moderator = isModerator(relation);
  if (moderator) {
    if (now < time.hostOpensAt) {
      return deny('room_not_open', 'You can open this room 30 minutes before it starts.', time.hostOpensAt);
    }
    return { allowed: true, code: null, message: null, opensAt: null };
  }

  if (now < time.doorsOpenAt) {
    return deny('room_not_open', 'The doors are not open yet.', time.doorsOpenAt);
  }
  if (time.lateUntil !== null && now > time.lateUntil && !joinedBefore) {
    return deny('room_closed_for_entry', 'This room no longer lets new people in.');
  }
  if (room.approval && !admitted && !joinedBefore) {
    return deny('needs_admission', 'A host lets people in. Ask to join from the lobby.');
  }
  if (capacity && !joinedBefore && !holdsSeat && occupiedByOthers + heldForOthers >= capacity) {
    return deny('room_full', 'The room is full. Join the waiting list to get the next free seat.');
  }
  return { allowed: true, code: null, message: null, opensAt: null };
};

/** Seats a waiting list may hand out right now. */
export const freeSeats = ({ capacity, occupied, held }) =>
  capacity ? Math.max(0, capacity - occupied - held) : 0;

// ---------------------------------------------------------------------------
// Calendar
// ---------------------------------------------------------------------------

const icsDate = (value) => new Date(value).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');

/** RFC 5545 text: backslash, semicolon, comma and newline escaped. */
const icsText = (value) =>
  String(value ?? '')
    .replace(/\\/g, '\\\\')
    .replace(/;/g, '\\;')
    .replace(/,/g, '\\,')
    .replace(/\r?\n/g, '\\n');

/** Lines longer than 75 octets are folded, as the RFC requires. */
const fold = (line) => {
  const parts = [];
  let rest = line;
  while (Buffer.byteLength(rest) > 75) {
    let cut = 75;
    while (Buffer.byteLength(rest.slice(0, cut)) > 75) cut -= 1;
    parts.push(rest.slice(0, cut));
    rest = ` ${rest.slice(cut)}`;
  }
  parts.push(rest);
  return parts.join('\r\n');
};

/** One room as an .ics file; SEQUENCE lets calendars accept a moved room. */
export const icsFor = ({ room, url, now = new Date() }) =>
  [
    'BEGIN:VCALENDAR',
    'VERSION:2.0',
    'PRODID:-//Classroom//Rooms//EN',
    'CALSCALE:GREGORIAN',
    `METHOD:${room.status === 'cancelled' ? 'CANCEL' : 'PUBLISH'}`,
    'BEGIN:VEVENT',
    `UID:${room.id}@classroom`,
    `SEQUENCE:${room.sequence ?? 0}`,
    `DTSTAMP:${icsDate(now)}`,
    `DTSTART:${icsDate(room.startsAt)}`,
    `DTEND:${icsDate(room.endsAt)}`,
    `SUMMARY:${icsText(room.title)}`,
    `DESCRIPTION:${icsText([room.description, `Join: ${url}`].filter(Boolean).join('\n\n'))}`,
    `URL:${url}`,
    `LOCATION:${icsText(url)}`,
    `STATUS:${room.status === 'cancelled' ? 'CANCELLED' : 'CONFIRMED'}`,
    'BEGIN:VALARM',
    'ACTION:DISPLAY',
    `DESCRIPTION:${icsText(room.title)}`,
    `TRIGGER:-PT${clampEarly(room.earlyEntryMinutes)}M`,
    'END:VALARM',
    'END:VEVENT',
    'END:VCALENDAR',
    '',
  ]
    .map(fold)
    .join('\r\n');

export default {
  EARLY_ENTRY, DURATION, CAPACITY, HOLD_MS, newRoomCode, isRoomCode, windowFor, phaseOf,
  relationOf, isModerator, entryDecision, freeSeats, icsFor, CreateRoomSchema, UpdateRoomSchema,
};
__RM_EOF__
echo "wrote server/src/rooms/roomRules.js"

mkdir -p server/src/rooms
cat > server/src/rooms/ScheduledRooms.js <<'__RM_EOF__'
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

export const roomUrl = (code) => `${String(env.APP_URL).replace(/\/$/, '')}/rooms/${code}/lobby`;

/** What a person sees of a room: the lobby, the room card, the editor. */
export const detailFor = async ({ room, userId, tenantId = null, now = Date.now() }) => {
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
    url: roomUrl(room.code),
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
__RM_EOF__
echo "wrote server/src/rooms/ScheduledRooms.js"

mkdir -p server/src/routes
cat > server/src/routes/scheduledRooms.routes.js <<'__RM_EOF__'
/**
 * scheduledRooms.routes — create, plan and enter your own rooms  (Rooms)
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
 *   GET    /:code/gate                 may I enter now? (the classroom page asks first)
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

const detail = (req, room) => Rooms.detailFor({ room, userId: req.user.id, tenantId: tenantOf(req) });

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
    return { scheduled: true, canEnter: decision.allowed, reason: decision.code, message: decision.message };
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
    return { dataUrl: await QRCode.toDataURL(Rooms.roomUrl(room.code), { margin: 1, width: 264, errorCorrectionLevel: 'M' }) };
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
      res.send(Rules.icsFor({ room, url: Rooms.roomUrl(room.code) }));
    })(req, res).catch(next),
);

export default router;
__RM_EOF__
echo "wrote server/src/routes/scheduledRooms.routes.js"

mkdir -p server/test/rooms
cat > server/test/rooms/roomRules.check.mjs <<'__RM_EOF__'
// Rooms — who may enter when, and what a valid room is.
// Run: node --test server/test/rooms/*.check.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  CreateRoomSchema,
  entryDecision,
  freeSeats,
  icsFor,
  isRoomCode,
  newRoomCode,
  phaseOf,
  relationOf,
  windowFor,
} from '../../src/rooms/roomRules.js';

const T = Date.parse('2026-10-06T16:00:00Z');
const min = 60_000;
const room = (overrides = {}) => ({
  id: 's1',
  hostId: 'host',
  cohostIds: ['co'],
  status: 'scheduled',
  startsAt: new Date(T).toISOString(),
  endsAt: new Date(T + 60 * min).toISOString(),
  earlyEntryMinutes: 5,
  lateJoinMinutes: null,
  capacity: null,
  access: 'invited',
  approval: false,
  title: 'Maths, revision; part 1',
  sequence: 2,
  ...overrides,
});

test('room codes are readable and unguessable', () => {
  const codes = new Set(Array.from({ length: 500 }, newRoomCode));
  assert.equal(codes.size, 500);
  for (const code of codes) assert.ok(isRoomCode(code), code);
  assert.equal(isRoomCode('00000000-0000-0000-0000-000000000000'), false);
  assert.equal(isRoomCode('abc-defg-hjk'), true);
  assert.equal(isRoomCode('abc-defg-hjl'), false); // no l
});

test('the timeline: host 30 min early, doors 3–10 min early', () => {
  const time = windowFor(room({ earlyEntryMinutes: 7, lateJoinMinutes: 10 }));
  assert.equal(time.hostOpensAt, T - 30 * min);
  assert.equal(time.doorsOpenAt, T - 7 * min);
  assert.equal(time.lateUntil, T + 10 * min);
  assert.equal(windowFor(room({ earlyEntryMinutes: 60 })).doorsOpenAt, T - 10 * min);
  assert.equal(windowFor(room({ earlyEntryMinutes: 0 })).doorsOpenAt, T - 3 * min);
});

test('phases', () => {
  assert.equal(phaseOf(room(), T - 6 * min), 'scheduled');
  assert.equal(phaseOf(room(), T - 5 * min), 'doors-open');
  assert.equal(phaseOf(room(), T), 'live');
  assert.equal(phaseOf(room(), T + 60 * min), 'ended');
  assert.equal(phaseOf(room({ status: 'cancelled' }), T), 'cancelled');
});

test('relations: host, co-host, invitee, link guest, nobody', () => {
  assert.equal(relationOf(room(), { userId: 'host' }), 'host');
  assert.equal(relationOf(room(), { userId: 'co' }), 'cohost');
  assert.equal(relationOf(room(), { userId: 'x', invited: true }), 'invitee');
  assert.equal(relationOf(room(), { userId: 'x' }), null);
  assert.equal(relationOf(room({ access: 'link' }), { userId: 'x' }), 'guest');
  assert.equal(relationOf(room({ access: 'link' }), { userId: 'x', sameTenant: false }), null);
});

test('doors: before, at, and the host exception', () => {
  const r = room();
  assert.equal(entryDecision({ room: r, relation: 'invitee', now: T - 6 * min }).code, 'room_not_open');
  assert.equal(entryDecision({ room: r, relation: 'invitee', now: T - 6 * min }).opensAt, T - 5 * min);
  assert.equal(entryDecision({ room: r, relation: 'invitee', now: T - 5 * min }).allowed, true);
  assert.equal(entryDecision({ room: r, relation: 'host', now: T - 20 * min }).allowed, true);
  assert.equal(entryDecision({ room: r, relation: 'cohost', now: T - 31 * min }).code, 'room_not_open');
  assert.equal(entryDecision({ room: r, relation: null, now: T }).code, 'not_invited');
});

test('late entry: new people refused, returning people welcome', () => {
  const r = room({ lateJoinMinutes: 10 });
  assert.equal(entryDecision({ room: r, relation: 'invitee', now: T + 9 * min }).allowed, true);
  assert.equal(entryDecision({ room: r, relation: 'invitee', now: T + 11 * min }).code, 'room_closed_for_entry');
  assert.equal(entryDecision({ room: r, relation: 'invitee', now: T + 11 * min, joinedBefore: true }).allowed, true);
  assert.equal(entryDecision({ room: r, relation: 'host', now: T + 50 * min }).allowed, true);
});

test('approval, capacity and held seats', () => {
  const knock = room({ approval: true });
  assert.equal(entryDecision({ room: knock, relation: 'guest', now: T }).code, 'needs_admission');
  assert.equal(entryDecision({ room: knock, relation: 'guest', now: T, admitted: true }).allowed, true);
  assert.equal(entryDecision({ room: knock, relation: 'host', now: T }).allowed, true);

  const small = room({ capacity: 3 });
  assert.equal(entryDecision({ room: small, relation: 'invitee', now: T, occupiedByOthers: 2 }).allowed, true);
  assert.equal(entryDecision({ room: small, relation: 'invitee', now: T, occupiedByOthers: 2, heldForOthers: 1 }).code, 'room_full');
  assert.equal(entryDecision({ room: small, relation: 'invitee', now: T, occupiedByOthers: 3, holdsSeat: true }).allowed, true);
  assert.equal(entryDecision({ room: small, relation: 'host', now: T, occupiedByOthers: 3 }).allowed, true);
  assert.equal(freeSeats({ capacity: 3, occupied: 1, held: 1 }), 1);
  assert.equal(freeSeats({ capacity: 3, occupied: 4, held: 0 }), 0);
});

test('ended and cancelled rooms admit nobody, hosts included', () => {
  assert.equal(entryDecision({ room: room(), relation: 'host', now: T + 60 * min }).code, 'room_ended');
  assert.equal(entryDecision({ room: room({ status: 'cancelled' }), relation: 'host', now: T }).code, 'room_cancelled');
});

test('create input: doors between 3 and 10 minutes, a series needs an end', () => {
  const base = {
    title: 'Room', startsAtLocal: '2026-10-06T18:00', durationMinutes: 60, timeZone: 'Europe/Berlin',
  };
  assert.equal(CreateRoomSchema.parse(base).earlyEntryMinutes, 5);
  assert.equal(CreateRoomSchema.safeParse({ ...base, earlyEntryMinutes: 2 }).success, false);
  assert.equal(CreateRoomSchema.safeParse({ ...base, earlyEntryMinutes: 11 }).success, false);
  assert.equal(CreateRoomSchema.safeParse({ ...base, earlyEntryMinutes: 10 }).success, true);
  assert.equal(CreateRoomSchema.safeParse({ ...base, recurrence: { freq: 'WEEKLY' } }).success, false);
  assert.equal(CreateRoomSchema.safeParse({ ...base, recurrence: { freq: 'WEEKLY', count: 4 } }).success, true);
  assert.equal(CreateRoomSchema.safeParse({ ...base, surprise: true }).success, false);
});

test('the calendar file is valid, escaped and folded', () => {
  const text = icsFor({ room: room({ description: 'Bring a calculator' }), url: 'https://app.example/rooms/abc-defg-hjk/lobby', now: new Date(T) });
  assert.ok(text.startsWith('BEGIN:VCALENDAR\r\n'));
  assert.ok(text.includes('DTSTART:20261006T160000Z'));
  assert.ok(text.includes('SUMMARY:Maths\\, revision\\; part 1'));
  assert.ok(text.includes('SEQUENCE:2'));
  assert.ok(text.includes('TRIGGER:-PT5M'));
  for (const line of text.split('\r\n')) assert.ok(Buffer.byteLength(line) <= 75, line);
  assert.ok(icsFor({ room: room({ status: 'cancelled' }), url: 'u' }).includes('METHOD:CANCEL'));
});
__RM_EOF__
echo "wrote server/test/rooms/roomRules.check.mjs"

mkdir -p packages/core-client/src/api
cat > packages/core-client/src/api/roomsApi.ts <<'__RM_EOF__'
/**
 * Rooms API  (Rooms: create your own room)
 *
 * Planning, the lobby and the host's controls for rooms people create
 * themselves. Paths are the server's (server/src/routes/scheduledRooms.routes.js,
 * mounted under /scheduled-rooms). The room is still joined through the
 * classroom socket at /rooms/<code>.
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

  get: (code, signal) => http.get(path(code), { schema: RoomDetailSchema, signal }),

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

  qr: (code) => http.get(path(code, '/qr'), { schema: z.object({ dataUrl: z.string() }).passthrough(), retry: { attempts: 1 } }),

  calendarFile: async (code) => {
    const response = await http.raw('GET', path(code, '/calendar.ics'));
    if (!response.ok) throw new Error('The calendar file could not be downloaded.');
    return response.blob();
  },
});
__RM_EOF__
echo "wrote packages/core-client/src/api/roomsApi.ts"

mkdir -p apps/web/src/lib
cat > apps/web/src/lib/useRoomGate.js <<'__RM_EOF__'
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
 */
const ROOM_CODE = /^[a-hjkmnp-z2-9]{3}-[a-hjkmnp-z2-9]{4}-[a-hjkmnp-z2-9]{3}$/;

export const isRoomCode = (value) => ROOM_CODE.test(String(value ?? ''));

export function useRoomGate(roomId) {
  const { http, status } = useCore();
  const rooms = useMemo(() => createRoomsApi(http), [http]);
  const scheduled = isRoomCode(roomId);
  const [gate, setGate] = useState({ ready: !scheduled, canEnter: true, scheduled, reason: null });

  useEffect(() => {
    if (!scheduled) {
      setGate({ ready: true, canEnter: true, scheduled: false, reason: null });
      return undefined;
    }
    if (status !== 'authenticated') return undefined;
    const controller = new AbortController();
    rooms
      .gate(roomId, controller.signal)
      .then((answer) =>
        setGate({ ready: true, canEnter: answer.canEnter, scheduled: answer.scheduled, reason: answer.reason ?? null }),
      )
      .catch(() => {
        if (!controller.signal.aborted) setGate({ ready: true, canEnter: true, scheduled: true, reason: null });
      });
    return () => controller.abort();
  }, [rooms, roomId, scheduled, status]);

  return gate;
}

export default useRoomGate;
__RM_EOF__
echo "wrote apps/web/src/lib/useRoomGate.js"

mkdir -p apps/web/src/pages
cat > apps/web/src/pages/DashboardPage.jsx <<'__RM_EOF__'
import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { createRoomsApi, useCore } from '@classroom/core-client';

import RoomCard from '../components/Rooms/RoomCard.jsx';
import { destinationFor } from '../components/Rooms/roomModel.js';
import { onUserEvent } from '../lib/userEvents.js';
import '../components/Rooms/rooms.css';

/**
 * Dashboard  (Rooms)
 *
 * "New room" first, then your rooms — running and upcoming ones, or the
 * past ones — and a box to join by code or link. The course and lesson lists
 * join this page when F3 lands.
 */

export default function DashboardPage() {
  const navigate = useNavigate();
  const core = useCore();
  const { http, session } = core;
  const rooms = useMemo(() => createRoomsApi(http), [http]);

  const [when, setWhen] = useState('upcoming');
  const [items, setItems] = useState(null);
  const [failed, setFailed] = useState(false);
  const [joinText, setJoinText] = useState('');

  const load = useCallback(async () => {
    try {
      setItems((await rooms.mine(when)).items);
      setFailed(false);
    } catch {
      setFailed(true);
      setItems((current) => current ?? []);
    }
  }, [rooms, when]);

  useEffect(() => {
    setItems(null);
    load();
    const timer = window.setInterval(load, 60_000);
    return () => window.clearInterval(timer);
  }, [load]);

  // A new invitation arrives as a notification; show it without a reload.
  useEffect(
    () =>
      onUserEvent(core, 'notification:new', (payload) => {
        if (String(payload?.notification?.kind ?? '').startsWith('session.')) load();
      }),
    [core, load],
  );

  const destination = destinationFor(joinText);
  const live = (items ?? []).filter((room) => room.phase === 'live' || room.phase === 'doors-open');
  const later = (items ?? []).filter((room) => room.phase !== 'live' && room.phase !== 'doors-open');

  return (
    <section className="page rm-page">
      <header className="rm-head">
        <div>
          <h1>{session?.displayName ? `Hello, ${session.displayName.split(' ')[0]}` : 'Dashboard'}</h1>
          <p className="muted">Your rooms, and a way into anyone else’s.</p>
        </div>
        <Link className="btn btn--primary" to="/rooms/new">
          + New room
        </Link>
      </header>

      <div className="rm-dash">
        <div className="rm-dash__main">
          <div className="rm-tabs" role="tablist">
            {[
              ['upcoming', 'Upcoming'],
              ['past', 'Past'],
            ].map(([value, label]) => (
              <button key={value} type="button" role="tab" aria-selected={when === value} className={when === value ? 'rm-tab is-on' : 'rm-tab'} onClick={() => setWhen(value)}>
                {label}
              </button>
            ))}
          </div>

          {items === null ? <p className="muted">Loading…</p> : null}
          {failed ? <p className="rm-error">Your rooms could not be loaded.</p> : null}
          {items?.length === 0 && !failed ? (
            <div className="rm-empty">
              <p>{when === 'upcoming' ? 'No rooms planned.' : 'No rooms in the last 90 days.'}</p>
              {when === 'upcoming' ? (
                <Link className="btn" to="/rooms/new">
                  Plan your first room
                </Link>
              ) : null}
            </div>
          ) : null}

          {live.length > 0 ? (
            <>
              <h2 className="rm-subhead">Now</h2>
              <div className="rm-cards">
                {live.map((room) => (
                  <RoomCard key={room.code} room={room} to={`/rooms/${room.code}/lobby`} />
                ))}
              </div>
            </>
          ) : null}
          {later.length > 0 ? (
            <>
              {live.length > 0 ? <h2 className="rm-subhead">Later</h2> : null}
              <div className="rm-cards">
                {later.map((room) => (
                  <RoomCard key={room.code} room={room} to={`/rooms/${room.code}/lobby`} />
                ))}
              </div>
            </>
          ) : null}
        </div>

        <aside className="card rm-join">
          <h2>Join with a code or link</h2>
          <label htmlFor="rm-join">Room code or link</label>
          <input
            id="rm-join"
            value={joinText}
            onChange={(event) => setJoinText(event.target.value)}
            onKeyDown={(event) => event.key === 'Enter' && destination && navigate(destination)}
            placeholder="kqz-7hfd-2mx"
            autoComplete="off"
          />
          <button type="button" className="btn btn--primary" disabled={!destination} onClick={() => navigate(destination)}>
            Join
          </button>
        </aside>
      </div>
    </section>
  );
}
__RM_EOF__
echo "wrote apps/web/src/pages/DashboardPage.jsx"

mkdir -p apps/web/src/pages
cat > apps/web/src/pages/RoomEditorPage.jsx <<'__RM_EOF__'
import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom';
import { createProfileApi, createRoomsApi, useCore } from '@classroom/core-client';

import PeoplePicker from '../components/Rooms/PeoplePicker.jsx';
import RoomCard from '../components/Rooms/RoomCard.jsx';
import {
  REPEAT_OPTIONS,
  defaultForm,
  durationLabel,
  formToInput,
  recurrenceOf,
  roomToForm,
  validateForm,
} from '../components/Rooms/roomModel.js';
import { formatDate, formatTime } from '../lib/preferences.js';
import '../components/Rooms/rooms.css';

/**
 * Create or edit a room  (Rooms)
 *
 *   /rooms/new                 a new room (or a series of them)
 *   /rooms/new?from=<code>     a copy of an existing room, on a new date
 *   /rooms/<code>/edit         one date of a room, host only
 *
 * The card on the right is exactly what invitees will see, updated while you
 * type, and every change of time is checked against your other rooms before
 * you save — a clash is shown, not discovered.
 */

const browserZone = () => Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';

const zones = () => {
  try {
    return Intl.supportedValuesOf('timeZone');
  } catch {
    return [browserZone()];
  }
};

function Field({ label, hint, error, children, htmlFor }) {
  return (
    <div className="rm-field">
      <label className="rm-label" htmlFor={htmlFor}>
        {label}
      </label>
      {hint ? <p className="rm-hint">{hint}</p> : null}
      {children}
      {error ? <p className="rm-error">{error}</p> : null}
    </div>
  );
}

function Switch({ label, hint, checked, onChange }) {
  return (
    <label className="rm-switch-row">
      <span>
        <span className="rm-label">{label}</span>
        {hint ? <span className="rm-hint">{hint}</span> : null}
      </span>
      <input type="checkbox" role="switch" className="rm-switch" checked={checked} onChange={(e) => onChange(e.target.checked)} />
    </label>
  );
}

export default function RoomEditorPage() {
  const { code } = useParams();
  const [search] = useSearchParams();
  const fromCode = search.get('from');
  const editing = Boolean(code);
  const navigate = useNavigate();
  const { http, session } = useCore();
  const rooms = useMemo(() => createRoomsApi(http), [http]);
  const profiles = useMemo(() => createProfileApi(http), [http]);

  const [config, setConfig] = useState(null);
  const [form, setForm] = useState(null);
  const [loadError, setLoadError] = useState(null);
  const [preview, setPreview] = useState(null);
  const [touched, setTouched] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState(null);

  const allZones = useMemo(zones, []);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const [cfg, own, prefs] = await Promise.all([
          rooms.config(),
          profiles.getOwn().catch(() => null),
          profiles.getPreferences().catch(() => null),
        ]);
        let next = defaultForm({ timeZone: own?.timeZone || browserZone(), roomDefaults: prefs?.roomDefaults });
        const source = code ?? fromCode;
        if (source) {
          const room = await rooms.get(source);
          if (editing && !room.viewer.moderator) throw new Error('Only the host can edit this room.');
          next = roomToForm(room);
          if (!editing) {
            next = { ...next, title: `${room.title}`, startsAtLocal: defaultForm({ timeZone: room.timeZone }).startsAtLocal };
          }
        }
        if (!cancelled) {
          setConfig(cfg);
          setForm(next);
        }
      } catch (cause) {
        if (!cancelled) setLoadError(cause?.detail ?? cause?.message ?? 'The room could not be loaded.');
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [rooms, profiles, code, fromCode, editing]);

  const set = (patch) => setForm((current) => ({ ...current, ...patch }));

  // Clash check and dates of a series, while the time is being chosen.
  const previewKey = form
    ? JSON.stringify([form.startsAtLocal, form.durationMinutes, form.timeZone, editing ? null : recurrenceOf(form)])
    : '';
  useEffect(() => {
    if (!form || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(form.startsAtLocal)) return undefined;
    const controller = new AbortController();
    const timer = window.setTimeout(async () => {
      try {
        setPreview(
          await rooms.preview(
            {
              startsAtLocal: form.startsAtLocal,
              durationMinutes: Number(form.durationMinutes),
              timeZone: form.timeZone,
              recurrence: editing ? null : recurrenceOf(form),
              excludeCode: editing ? code : undefined,
            },
            controller.signal,
          ),
        );
      } catch (cause) {
        if (!controller.signal.aborted) setPreview({ error: cause?.detail ?? 'These dates cannot be used.' });
      }
    }, 350);
    return () => {
      controller.abort();
      window.clearTimeout(timer);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [previewKey, rooms, editing, code]);

  if (loadError) {
    return (
      <section className="page rm-page">
        <h1>{editing ? 'Edit room' : 'New room'}</h1>
        <p className="rm-error">{loadError}</p>
        <Link className="btn" to="/">
          Back
        </Link>
      </section>
    );
  }
  if (!form || !config) {
    return (
      <section className="page rm-page">
        <p className="muted">Loading…</p>
      </section>
    );
  }

  const errors = validateForm(form, config);
  const shown = touched ? errors : {};
  const firstOccurrence = preview?.occurrences?.[0];
  const startsAt = firstOccurrence?.startsAt ?? null;
  const endsAt = firstOccurrence?.endsAt ?? null;
  const doorsAt = startsAt ? new Date(new Date(startsAt).getTime() - form.earlyEntryMinutes * 60_000).toISOString() : null;
  const blocking = Boolean(preview?.conflicts?.length) || Boolean(preview?.inPast) || Boolean(preview?.error);

  const submit = async (event) => {
    event.preventDefault();
    setTouched(true);
    if (Object.keys(errors).length > 0 || blocking) return;
    setSaving(true);
    setSaveError(null);
    try {
      if (editing) {
        await rooms.update(code, formToInput(form, { editing: true }));
        navigate(`/rooms/${code}/lobby`, { replace: true, state: { saved: true } });
      } else {
        const result = await rooms.create(formToInput(form));
        navigate(`/rooms/${result.room.code}/lobby`, { state: { created: true, occurrences: result.occurrences } });
      }
    } catch (cause) {
      setSaveError(cause?.detail ?? cause?.message ?? 'The room was not saved.');
    } finally {
      setSaving(false);
    }
  };

  const previewRoom = {
    title: form.title,
    startsAt: startsAt ?? new Date().toISOString(),
    endsAt: endsAt ?? new Date().toISOString(),
    doorsOpenAt: doorsAt ?? new Date().toISOString(),
    phase: 'scheduled',
    capacity: form.capacityMode === 'limit' ? Number(form.capacity) : null,
    access: form.access,
    inviteeCount: form.invitees.length,
    hostName: session?.displayName ?? null,
    relation: 'host',
  };

  return (
    <section className="page rm-page">
      <header className="rm-head">
        <h1>{editing ? 'Edit room' : fromCode ? 'Copy room' : 'New room'}</h1>
        <Link to="/" className="btn btn--tiny">
          Cancel
        </Link>
      </header>

      <form className="rm-editor" onSubmit={submit} noValidate>
        <div className="rm-editor__form">
          <fieldset className="rm-section">
            <legend>What</legend>
            <Field label="Name" error={shown.title} htmlFor="rm-title">
              <input id="rm-title" className="rm-input" value={form.title} maxLength={120} placeholder="e.g. Maths revision" onChange={(e) => set({ title: e.target.value })} autoFocus={!editing} />
            </Field>
            <Field label="Description" hint="Optional. Shown in the invitation and the lobby." htmlFor="rm-desc">
              <textarea id="rm-desc" className="rm-input" rows={2} maxLength={2000} value={form.description} onChange={(e) => set({ description: e.target.value })} />
            </Field>
            <Field label="Agenda" hint="Optional. One point per line; everyone sees it in the lobby." htmlFor="rm-agenda">
              <textarea id="rm-agenda" className="rm-input" rows={3} maxLength={2000} value={form.agenda} onChange={(e) => set({ agenda: e.target.value })} />
            </Field>
          </fieldset>

          <fieldset className="rm-section">
            <legend>When</legend>
            <div className="rm-row">
              <Field label="Starts" error={shown.startsAtLocal} htmlFor="rm-start">
                <input id="rm-start" type="datetime-local" className="rm-input" step={300} value={form.startsAtLocal} onChange={(e) => set({ startsAtLocal: e.target.value })} />
              </Field>
              <Field label="Time zone" htmlFor="rm-zone">
                <select id="rm-zone" className="rm-input" value={form.timeZone} onChange={(e) => set({ timeZone: e.target.value })}>
                  {(allZones.includes(form.timeZone) ? allZones : [form.timeZone, ...allZones]).map((zone) => (
                    <option key={zone} value={zone}>
                      {zone.replace(/_/g, ' ')}
                    </option>
                  ))}
                </select>
              </Field>
            </div>
            <Field label="Length" error={shown.durationMinutes}>
              <div className="rm-chips">
                {config.duration.presets.map((minutes) => (
                  <button key={minutes} type="button" className={Number(form.durationMinutes) === minutes ? 'rm-pill is-on' : 'rm-pill'} onClick={() => set({ durationMinutes: minutes })}>
                    {durationLabel(minutes)}
                  </button>
                ))}
                <input type="number" className="rm-input rm-input--short" min={config.duration.min} max={config.duration.max} step={5} value={form.durationMinutes} onChange={(e) => set({ durationMinutes: e.target.value })} aria-label="Length in minutes" />
                <span className="rm-hint">min</span>
              </div>
            </Field>
            {!editing ? (
              <Field label="Repeat" error={shown.repeat}>
                <div className="rm-row">
                  <select className="rm-input" value={form.repeat} onChange={(e) => set({ repeat: e.target.value })} aria-label="Repeat">
                    {REPEAT_OPTIONS.map((option) => (
                      <option key={option.value} value={option.value}>
                        {option.label}
                      </option>
                    ))}
                  </select>
                  {form.repeat !== 'none' ? (
                    <>
                      <select className="rm-input" value={form.repeatEnd} onChange={(e) => set({ repeatEnd: e.target.value })} aria-label="Series ends">
                        <option value="count">for a number of dates</option>
                        <option value="until">until a date</option>
                      </select>
                      {form.repeatEnd === 'count' ? (
                        <input type="number" className="rm-input rm-input--short" min={2} max={52} value={form.repeatCount} onChange={(e) => set({ repeatCount: e.target.value })} aria-label="Number of dates" />
                      ) : (
                        <input type="date" className="rm-input" value={form.repeatUntil} onChange={(e) => set({ repeatUntil: e.target.value })} aria-label="Last date" />
                      )}
                    </>
                  ) : null}
                </div>
                <p className="rm-hint">Every date is its own room with its own link; change or cancel dates one by one.</p>
              </Field>
            ) : null}
          </fieldset>

          <fieldset className="rm-section">
            <legend>Doors</legend>
            <Field
              label={`Doors open ${form.earlyEntryMinutes} minutes before the start${doorsAt ? ` (${formatTime(doorsAt)})` : ''}`}
              hint="Before that, the link shows a countdown and a camera check. You and your co-hosts can come in 30 minutes early to prepare."
              error={shown.earlyEntryMinutes}
            >
              <input type="range" className="rm-range" min={config.earlyEntry.min} max={config.earlyEntry.max} step={1} value={form.earlyEntryMinutes} onChange={(e) => set({ earlyEntryMinutes: Number(e.target.value) })} aria-label="Minutes before the start" />
              <div className="rm-range__scale" aria-hidden="true">
                <span>{config.earlyEntry.min} min</span>
                <span>{config.earlyEntry.max} min</span>
              </div>
            </Field>
            <Field label="Late arrivals" hint="People who were already in can always come back, e.g. after a dropped connection.">
              <select className="rm-input" value={form.lateJoinMinutes ?? ''} onChange={(e) => set({ lateJoinMinutes: e.target.value === '' ? null : Number(e.target.value) })}>
                <option value="">Welcome until the end</option>
                <option value="0">Not after the start</option>
                {config.lateJoinOptions
                  .filter((minutes) => minutes)
                  .map((minutes) => (
                    <option key={minutes} value={minutes}>
                      Up to {minutes} minutes after the start
                    </option>
                  ))}
              </select>
            </Field>
          </fieldset>

          <fieldset className="rm-section">
            <legend>Who</legend>
            <div className="rm-choice">
              {[
                { value: 'invited', title: 'Only people I invite', hint: 'The link alone does not let anyone in.' },
                { value: 'link', title: 'Anyone in my organisation with the link', hint: 'Invite people as well, to send them a reminder.' },
              ].map((option) => (
                <label key={option.value} className={form.access === option.value ? 'rm-choice__option is-on' : 'rm-choice__option'}>
                  <input type="radio" name="access" value={option.value} checked={form.access === option.value} onChange={() => set({ access: option.value })} />
                  <span>
                    <span className="rm-label">{option.title}</span>
                    <span className="rm-hint">{option.hint}</span>
                  </span>
                </label>
              ))}
            </div>
            <PeoplePicker
              label="Invite"
              hint="They get an invitation and reminders a day and 10 minutes before."
              value={form.invitees}
              onChange={(invitees) => set({ invitees })}
              exclude={[session?.userId, ...form.cohosts.map((p) => p.userId)].filter(Boolean)}
              max={config.limits.invitees}
            />
            {shown.invitees ? <p className="rm-error">{shown.invitees}</p> : null}
            <PeoplePicker
              label="Co-hosts"
              hint="Can come in early, let people in, extend and end the room."
              value={form.cohosts}
              onChange={(cohosts) => set({ cohosts })}
              exclude={[session?.userId, ...form.invitees.map((p) => p.userId)].filter(Boolean)}
              max={config.limits.cohosts}
            />
            <Switch label="Let people in myself" hint="People knock in the lobby; you or a co-host admit them one by one or all at once." checked={form.approval} onChange={(approval) => set({ approval })} />
            <Field label="Seats" hint="Including you. Hosts and co-hosts always get in. When it is full, people can join a waiting list and get the next free seat." error={shown.capacity}>
              <div className="rm-row">
                <select className="rm-input" value={form.capacityMode} onChange={(e) => set({ capacityMode: e.target.value })} aria-label="Seat limit">
                  <option value="limit">Limit to</option>
                  <option value="plan">As many as allowed ({config.capacity.max})</option>
                </select>
                {form.capacityMode === 'limit' ? (
                  <input type="number" className="rm-input rm-input--short" min={config.capacity.min} max={config.capacity.max} value={form.capacity} onChange={(e) => set({ capacity: e.target.value })} aria-label="Number of seats" />
                ) : null}
              </div>
            </Field>
          </fieldset>

          <fieldset className="rm-section">
            <legend>In the room</legend>
            <Switch label="Participants join muted" hint="They can unmute themselves." checked={form.learnersJoinMuted} onChange={(learnersJoinMuted) => set({ learnersJoinMuted })} />
            <Switch label="Emoji reactions" checked={form.reactionsEnabled} onChange={(reactionsEnabled) => set({ reactionsEnabled })} />
            <Switch label="Participants may share their screen" hint="Off: only you and your co-hosts." checked={form.learnersMayShare} onChange={(learnersMayShare) => set({ learnersMayShare })} />
          </fieldset>
        </div>

        <aside className="rm-editor__side">
          <p className="rm-hint">What invitees will see</p>
          <RoomCard room={previewRoom} preview />

          {preview?.error ? <p className="rm-error">{preview.error}</p> : null}
          {preview?.inPast ? <p className="rm-error">That start time is in the past.</p> : null}
          {preview?.adjusted === 'gap' ? <p className="rm-hint">That time does not exist on that day (clock change); the room starts an hour later.</p> : null}
          {preview?.occurrences?.length > 1 ? (
            <details className="rm-dates">
              <summary>{preview.occurrences.length} dates</summary>
              <ul>
                {preview.occurrences.map((o) => (
                  <li key={o.startsAt}>
                    {formatDate(o.startsAt)} · {formatTime(o.startsAt)}
                  </li>
                ))}
              </ul>
            </details>
          ) : null}
          {preview?.conflicts?.length ? (
            <div className="rm-conflict" role="alert">
              <p className="rm-label">This clashes with your other plans</p>
              <ul>
                {preview.conflicts.slice(0, 5).map((c) => (
                  <li key={`${c.at}-${c.title}`}>
                    {formatDate(c.at)}: “{c.title}” {c.startsAt ? `${formatTime(c.startsAt)}–${formatTime(c.endsAt)}` : ''}
                  </li>
                ))}
              </ul>
            </div>
          ) : null}

          {saveError ? <p className="rm-error" role="alert">{saveError}</p> : null}
          <button type="submit" className="btn btn--primary rm-submit" disabled={saving || (touched && (Object.keys(errors).length > 0 || blocking))}>
            {saving ? 'Saving…' : editing ? 'Save changes' : preview?.occurrences?.length > 1 ? `Create ${preview.occurrences.length} rooms` : 'Create room'}
          </button>
          {editing ? <p className="rm-hint">Invitees are told if the time changes.</p> : null}
        </aside>
      </form>
    </section>
  );
}
__RM_EOF__
echo "wrote apps/web/src/pages/RoomEditorPage.jsx"

mkdir -p apps/web/src/pages
cat > apps/web/src/pages/RoomLobbyPage.jsx <<'__RM_EOF__'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Link, Navigate, useLocation, useNavigate, useParams } from 'react-router-dom';
import { createRoomsApi, useCore } from '@classroom/core-client';

import DeviceCheck from '../components/Rooms/DeviceCheck.jsx';
import { countdown, durationLabel, phaseLabel, reasonText, timeInZones } from '../components/Rooms/roomModel.js';
import { formatDate, formatTime } from '../lib/preferences.js';
import { onUserEvent } from '../lib/userEvents.js';
import '../components/Rooms/rooms.css';

/**
 * The lobby of a room  (Rooms)  —  /rooms/<code>/lobby
 *
 * Where a room link lands. Before the doors open: a countdown, what the room
 * is about, and a camera check. When they open: "Enter room". Around that,
 * the lobby handles everything the room's settings ask for — knocking when a
 * host lets people in, the waiting list when every seat is taken (a freed
 * seat is held for you for two minutes) — and, for hosts, sharing, the
 * knock queue, editing and cancelling.
 *
 * What the server allows is the truth (GET /scheduled-rooms/<code>, and the
 * socket join checks again); the clock here is only corrected by the
 * server's time, never trusted on its own.
 */

const viewerZone = () => Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';

const copy = async (text) => {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
};

function useNow(intervalMs = 1_000) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), intervalMs);
    return () => window.clearInterval(timer);
  }, [intervalMs]);
  return now;
}

function SharePanel({ room, rooms, highlight }) {
  const [copied, setCopied] = useState(false);
  const [qr, setQr] = useState(null);

  useEffect(() => {
    let cancelled = false;
    rooms
      .qr(room.code)
      .then((result) => !cancelled && setQr(result.dataUrl))
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, [rooms, room.code]);

  const downloadCalendar = async () => {
    const blob = await rooms.calendarFile(room.code);
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = `${room.title.replace(/[^\w-]+/g, '-').slice(0, 40) || 'room'}.ics`;
    link.click();
    window.setTimeout(() => URL.revokeObjectURL(url), 10_000);
  };

  return (
    <section className={highlight ? 'rm-share is-new' : 'rm-share'} aria-label="Share this room">
      {highlight ? <p className="rm-label">Your room is ready. Share the link:</p> : <p className="rm-label">Link</p>}
      <div className="rm-share__row">
        <code className="rm-share__url">{room.url}</code>
        <button
          type="button"
          className="btn btn--tiny"
          onClick={async () => {
            setCopied(await copy(room.url));
            window.setTimeout(() => setCopied(false), 2_000);
          }}
        >
          {copied ? 'Copied' : 'Copy link'}
        </button>
        <button type="button" className="btn btn--tiny" onClick={() => downloadCalendar().catch(() => undefined)}>
          Add to calendar
        </button>
      </div>
      <p className="rm-hint">
        {room.access === 'link'
          ? 'Anyone in your organisation who has this link can come in.'
          : 'Only invited people can come in; for everyone else the link does nothing.'}{' '}
        Room code <strong>{room.code}</strong>
      </p>
      {qr ? <img className="rm-share__qr" src={qr} alt={`QR code for ${room.url}`} width={132} height={132} /> : null}
    </section>
  );
}

function KnockQueue({ room, rooms, onChange }) {
  const [knocks, setKnocks] = useState([]);

  const load = useCallback(async () => {
    try {
      setKnocks((await rooms.knocks(room.code)).items);
    } catch {
      // Shown again on the next poll.
    }
  }, [rooms, room.code]);

  useEffect(() => {
    load();
    const timer = window.setInterval(load, 5_000);
    return () => window.clearInterval(timer);
  }, [load]);

  if (!room.approval) return null;
  const act = async (fn) => {
    await fn().catch(() => undefined);
    await load();
    onChange();
  };

  return (
    <section className="rm-panel" aria-live="polite">
      <div className="rm-panel__head">
        <p className="rm-label">Waiting to be let in ({knocks.length})</p>
        {knocks.length > 1 ? (
          <button type="button" className="btn btn--tiny" onClick={() => act(() => rooms.admit(room.code, []))}>
            Admit all
          </button>
        ) : null}
      </div>
      {knocks.length === 0 ? <p className="rm-hint">Nobody is knocking.</p> : null}
      <ul className="rm-list">
        {knocks.map((knock) => (
          <li key={knock.userId}>
            <span>{knock.displayName}</span>
            <span className="rm-inline">
              <button type="button" className="btn btn--tiny btn--primary" onClick={() => act(() => rooms.admit(room.code, [knock.userId]))}>
                Admit
              </button>
              <button type="button" className="btn btn--tiny" onClick={() => act(() => rooms.deny(room.code, knock.userId))}>
                Decline
              </button>
            </span>
          </li>
        ))}
      </ul>
    </section>
  );
}

function HostPanel({ room, rooms, navigate, reload }) {
  const [cancelling, setCancelling] = useState(false);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const isHost = room.viewer.relation === 'host';
  const open = room.phase !== 'ended' && room.phase !== 'cancelled';

  const cancel = async (scope) => {
    setBusy(true);
    setError(null);
    try {
      await rooms.cancel(room.code, { scope, reason: reason.trim() || null });
      setCancelling(false);
      reload();
    } catch (cause) {
      setError(cause?.detail ?? 'The room was not cancelled.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="rm-panel">
      <p className="rm-label">{isHost ? 'You host this room' : 'You co-host this room'}</p>
      <p className="rm-hint">
        {room.occupied} in the room
        {room.capacity ? ` of ${room.capacity} seats` : ''}
        {room.invitees ? ` · ${room.invitees.length} invited` : ''}
        {room.cohosts.length ? ` · co-hosts: ${room.cohosts.map((c) => c.displayName).join(', ')}` : ''}
      </p>
      {isHost && open ? (
        <div className="rm-inline">
          <Link className="btn btn--tiny" to={`/rooms/${room.code}/edit`}>
            Edit
          </Link>
          <Link className="btn btn--tiny" to={`/rooms/new?from=${room.code}`}>
            Copy to a new date
          </Link>
          <button type="button" className="btn btn--tiny" onClick={() => setCancelling((v) => !v)}>
            Cancel room…
          </button>
        </div>
      ) : null}
      {isHost && !open ? (
        <Link className="btn btn--tiny" to={`/rooms/new?from=${room.code}`}>
          Plan it again
        </Link>
      ) : null}
      {cancelling ? (
        <div className="rm-confirm">
          <input className="rm-input" placeholder="Reason (optional, sent to invitees)" value={reason} maxLength={300} onChange={(e) => setReason(e.target.value)} />
          <div className="rm-inline">
            <button type="button" className="btn btn--tiny btn--danger" disabled={busy} onClick={() => cancel('this')}>
              Cancel this date
            </button>
            {room.seriesId ? (
              <button type="button" className="btn btn--tiny btn--danger" disabled={busy} onClick={() => cancel('following')}>
                Cancel this and all later dates
              </button>
            ) : null}
            <button type="button" className="btn btn--tiny" onClick={() => setCancelling(false)}>
              Keep it
            </button>
          </div>
          {error ? <p className="rm-error">{error}</p> : null}
        </div>
      ) : null}
      {room.viewer.canEnter ? null : (
        <p className="rm-hint">You can open the room from {formatTime(room.hostOpensAt)}.</p>
      )}
      <button type="button" className="rm-link rm-back" onClick={() => navigate('/')}>
        All my rooms
      </button>
    </section>
  );
}

export default function RoomLobbyPage() {
  const { code } = useParams();
  const navigate = useNavigate();
  const location = useLocation();
  const core = useCore();
  const { http, status } = core;
  const rooms = useMemo(() => createRoomsApi(http), [http]);

  const [room, setRoom] = useState(null);
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);
  const [skew, setSkew] = useState(0);
  const now = useNow();
  const loading = useRef(false);

  const load = useCallback(async () => {
    if (loading.current) return;
    loading.current = true;
    try {
      const next = await rooms.get(code);
      setSkew(new Date(next.serverTime).getTime() - Date.now());
      setRoom(next);
      setError(null);
    } catch (cause) {
      setError(cause?.detail ?? cause?.message ?? 'This room could not be loaded.');
    } finally {
      loading.current = false;
    }
  }, [rooms, code]);

  useEffect(() => {
    if (status !== 'authenticated') return undefined;
    load();
    const timer = window.setInterval(load, 10_000);
    return () => window.clearInterval(timer);
  }, [load, status]);

  // Being let in, a freed seat, a knock: reload at once instead of on the next poll.
  useEffect(() => {
    if (status !== 'authenticated') return undefined;
    const offs = ['room:admitted', 'room:denied', 'room:seat-available', 'room:knock'].map((event) =>
      onUserEvent(core, event, (payload) => {
        if (!payload?.code || payload.code === code) load();
      }),
    );
    return () => offs.forEach((off) => off());
  }, [core, status, code, load]);

  // The doors open while someone watches the countdown: ask the server then, not 10 s later.
  const serverNow = now + skew;
  const opensAt = room?.viewer?.opensAt ? new Date(room.viewer.opensAt).getTime() : null;
  useEffect(() => {
    if (opensAt && serverNow >= opensAt && !room?.viewer?.canEnter) load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [opensAt && serverNow >= opensAt]);

  if (status === 'anonymous') {
    return <Navigate to="/login" replace state={{ from: `/rooms/${code}/lobby` }} />;
  }

  if (error && !room) {
    return (
      <main className="rm-lobby">
        <div className="rm-lobby__card">
          <h1>Room not found</h1>
          <p className="muted">{error}</p>
          <Link className="btn" to="/">
            Back
          </Link>
        </div>
      </main>
    );
  }

  if (!room) {
    return (
      <main className="rm-lobby">
        <p className="muted">Loading…</p>
      </main>
    );
  }

  const { viewer } = room;
  const minutes = Math.round((new Date(room.endsAt) - new Date(room.startsAt)) / 60_000);
  const act = async (fn) => {
    setBusy(true);
    try {
      setRoom(await fn());
    } catch (cause) {
      setError(cause?.detail ?? cause?.message ?? 'That did not work.');
    } finally {
      setBusy(false);
    }
  };

  const enter = () => navigate(`/rooms/${room.code}`);
  const startsIn = new Date(room.startsAt).getTime() - serverNow;
  const endsIn = new Date(room.endsAt).getTime() - serverNow;
  const holdLeft = viewer.holdUntil ? new Date(viewer.holdUntil).getTime() - serverNow : 0;

  let action;
  if (viewer.canEnter) {
    action = (
      <>
        {holdLeft > 0 ? <p className="rm-good">A seat is free and held for you — {countdown(holdLeft).replace('in ', '')} left.</p> : null}
        <button type="button" className="btn btn--primary rm-enter" onClick={enter}>
          {room.phase === 'live' ? 'Enter room' : viewer.moderator ? 'Open the room' : 'Enter room'}
        </button>
        <p className="rm-hint">
          {room.phase === 'live' ? `Running · ends ${countdown(endsIn)}` : `Starts ${countdown(startsIn)}`}
        </p>
      </>
    );
  } else if (viewer.reason === 'room_not_open' && opensAt) {
    action = (
      <>
        <p className="rm-countdown" aria-live="polite">
          Doors open {countdown(opensAt - serverNow)}
        </p>
        <p className="rm-hint">at {formatTime(viewer.opensAt)} · the page opens the doors for you</p>
      </>
    );
  } else if (viewer.reason === 'needs_admission') {
    action = viewer.knocked ? (
      <>
        <p className="rm-countdown">Waiting for a host to let you in…</p>
        <button type="button" className="btn btn--tiny" disabled={busy} onClick={() => act(() => rooms.withdrawKnock(room.code))}>
          Stop asking
        </button>
      </>
    ) : (
      <>
        <p className="rm-hint">A host lets people in.</p>
        <button type="button" className="btn btn--primary rm-enter" disabled={busy} onClick={() => act(() => rooms.knock(room.code))}>
          Ask to join
        </button>
      </>
    );
  } else if (viewer.reason === 'room_full') {
    action = viewer.waitlistPosition ? (
      <>
        <p className="rm-countdown">You are number {viewer.waitlistPosition} on the waiting list.</p>
        <p className="rm-hint">When a seat is free it is held for you for 2 minutes, and you are told at once.</p>
        <button type="button" className="btn btn--tiny" disabled={busy} onClick={() => act(() => rooms.leaveWaitlist(room.code))}>
          Leave the waiting list
        </button>
      </>
    ) : (
      <>
        <p className="rm-hint">All {room.effectiveCapacity} seats are taken.</p>
        <button type="button" className="btn btn--primary rm-enter" disabled={busy} onClick={() => act(() => rooms.joinWaitlist(room.code))}>
          Join the waiting list
        </button>
      </>
    );
  } else {
    action = <p className="rm-countdown">{viewer.message ?? reasonText(viewer.reason, room) ?? 'You cannot enter this room.'}</p>;
  }

  return (
    <main className="rm-lobby">
      <div className="rm-lobby__grid">
        <section className="rm-lobby__card">
          <div className="rm-card__top">
            <span className={`rm-phase rm-phase--${room.phase}`}>{phaseLabel(room.phase)}</span>
            <span className="rm-hint">by {room.host.displayName}</span>
          </div>
          <h1 className="rm-lobby__title">{room.title}</h1>
          <p className="rm-card__when">
            {formatDate(room.startsAt)} · {timeInZones(room.startsAt, room.timeZone, viewerZone())} · {durationLabel(minutes)}
          </p>
          {room.cancelReason && room.phase === 'cancelled' ? <p className="rm-error">Cancelled: {room.cancelReason}</p> : null}
          {room.description ? <p className="rm-lobby__text">{room.description}</p> : null}
          {room.agenda ? (
            <div className="rm-agenda">
              <p className="rm-label">Agenda</p>
              <ol>
                {room.agenda
                  .split('\n')
                  .map((line) => line.replace(/^\s*(\d+[.)]|[-*•])\s*/, '').trim())
                  .filter(Boolean)
                  .map((line, index) => (
                    <li key={`${index}-${line}`}>{line}</li>
                  ))}
              </ol>
            </div>
          ) : null}

          <div className="rm-action">{action}</div>
          {error ? <p className="rm-error">{error}</p> : null}

          <ul className="rm-facts">
            <li>Doors open {room.earlyEntryMinutes} minutes before the start ({formatTime(room.doorsOpenAt)})</li>
            {room.lateUntil ? <li>No new arrivals after {formatTime(room.lateUntil)}</li> : null}
            {room.capacity ? <li>{room.capacity} seats</li> : null}
            {room.approval ? <li>A host lets people in</li> : null}
            {room.settings.learnersJoinMuted ? <li>You join muted</li> : null}
          </ul>
        </section>

        <aside className="rm-lobby__side">
          {viewer.moderator || room.access === 'link' ? (
            <SharePanel room={room} rooms={rooms} highlight={Boolean(location.state?.created)} />
          ) : null}
          {location.state?.created && location.state?.occurrences?.length > 1 ? (
            <p className="rm-hint">
              {location.state.occurrences.length} dates created, each with its own link. Find them all under “My rooms”.
            </p>
          ) : null}
          {viewer.moderator ? <KnockQueue room={room} rooms={rooms} onChange={load} /> : null}
          {viewer.moderator ? <HostPanel room={room} rooms={rooms} navigate={navigate} reload={load} /> : null}
          {room.phase !== 'ended' && room.phase !== 'cancelled' ? (
            <section className="rm-panel">
              <p className="rm-label">Camera and microphone</p>
              <DeviceCheck />
            </section>
          ) : null}
          {!viewer.moderator ? (
            <Link className="rm-link rm-back" to="/">
              All my rooms
            </Link>
          ) : null}
        </aside>
      </div>
    </main>
  );
}
__RM_EOF__
echo "wrote apps/web/src/pages/RoomLobbyPage.jsx"

mkdir -p apps/web/src/components/Rooms
cat > apps/web/src/components/Rooms/roomModel.js <<'__RM_EOF__'
/**
 * Pure helpers for creating, showing and entering rooms  (Rooms)
 *
 * No React, no network: tested in __checks__/roomModel.check.mjs. The server
 * decides who may enter (server/src/rooms/roomRules.js); these only shape the
 * form and the words on screen.
 */

export const WEEKDAYS = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'];
export const WORKDAYS = ['MO', 'TU', 'WE', 'TH', 'FR'];

const pad = (n) => String(n).padStart(2, '0');

/** "2026-10-01T18:00" for a moment, as the wall clock shows it in a time zone. */
export const localInputValue = (value, timeZone) => {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(new Date(value));
  const get = (type) => parts.find((part) => part.type === type)?.value ?? '00';
  return `${get('year')}-${get('month')}-${get('day')}T${get('hour') === '24' ? '00' : get('hour')}:${get('minute')}`;
};

/** The next full quarter hour at least 15 minutes away — a sensible default start. */
export const nextSlot = (now = new Date()) => {
  const next = new Date(now.getTime() + 15 * 60_000);
  next.setSeconds(0, 0);
  next.setMinutes(Math.ceil(next.getMinutes() / 15) * 15);
  return next;
};

/** Weekday code of a local date-time string, e.g. 'TU'. */
export const weekdayOf = (localIso) => {
  const [date] = String(localIso).split('T');
  const [y, m, d] = date.split('-').map(Number);
  return WEEKDAYS[new Date(Date.UTC(y, m - 1, d)).getUTCDay()];
};

export const defaultForm = ({ timeZone, roomDefaults = {}, now = new Date() } = {}) => ({
  title: '',
  description: '',
  agenda: '',
  startsAtLocal: localInputValue(nextSlot(now), timeZone),
  durationMinutes: 60,
  timeZone,
  earlyEntryMinutes: 5,
  lateJoinMinutes: null,
  capacityMode: 'limit',
  capacity: 25,
  access: 'invited',
  approval: false,
  invitees: [],
  cohosts: [],
  learnersJoinMuted: roomDefaults.learnersJoinMuted ?? false,
  reactionsEnabled: roomDefaults.reactionsEnabled ?? true,
  learnersMayShare: false,
  repeat: 'none',
  repeatEnd: 'count',
  repeatCount: 4,
  repeatUntil: '',
});

/** The editor's state for an existing room (one date of it). */
export const roomToForm = (room) => ({
  title: room.title,
  description: room.description ?? '',
  agenda: room.agenda ?? '',
  startsAtLocal: localInputValue(room.startsAt, room.timeZone),
  durationMinutes: Math.round((new Date(room.endsAt) - new Date(room.startsAt)) / 60_000),
  timeZone: room.timeZone,
  earlyEntryMinutes: room.earlyEntryMinutes,
  lateJoinMinutes: room.lateJoinMinutes ?? null,
  capacityMode: room.capacity ? 'limit' : 'plan',
  capacity: room.capacity ?? 25,
  access: room.access,
  approval: room.approval,
  invitees: room.invitees ?? [],
  cohosts: room.cohosts ?? [],
  learnersJoinMuted: room.settings?.learnersJoinMuted ?? false,
  reactionsEnabled: room.settings?.reactionsEnabled ?? true,
  learnersMayShare: room.settings?.learnersMayShare ?? false,
  repeat: 'none',
  repeatEnd: 'count',
  repeatCount: 4,
  repeatUntil: '',
});

export const recurrenceOf = (form) => {
  if (form.repeat === 'none') return null;
  const end = form.repeatEnd === 'until' && form.repeatUntil ? { until: form.repeatUntil } : { count: Number(form.repeatCount) };
  if (form.repeat === 'daily') return { freq: 'DAILY', ...end };
  if (form.repeat === 'weekdays') return { freq: 'WEEKLY', byDay: WORKDAYS, ...end };
  if (form.repeat === 'biweekly') return { freq: 'WEEKLY', interval: 2, byDay: [weekdayOf(form.startsAtLocal)], ...end };
  return { freq: 'WEEKLY', byDay: [weekdayOf(form.startsAtLocal)], ...end };
};

/** The API's input for a form. `editing` leaves the series out: one date is edited at a time. */
export const formToInput = (form, { editing = false } = {}) => {
  const input = {
    title: form.title.trim(),
    description: form.description.trim() || null,
    startsAtLocal: form.startsAtLocal,
    durationMinutes: Number(form.durationMinutes),
    timeZone: form.timeZone,
    earlyEntryMinutes: Number(form.earlyEntryMinutes),
    lateJoinMinutes: form.lateJoinMinutes === null || form.lateJoinMinutes === '' ? null : Number(form.lateJoinMinutes),
    capacity: form.capacityMode === 'plan' ? null : Number(form.capacity),
    access: form.access,
    approval: Boolean(form.approval),
    inviteeIds: form.invitees.map((person) => person.userId),
    cohostIds: form.cohosts.map((person) => person.userId),
    settings: {
      learnersJoinMuted: Boolean(form.learnersJoinMuted),
      reactionsEnabled: Boolean(form.reactionsEnabled),
      learnersMayShare: Boolean(form.learnersMayShare),
      agenda: form.agenda.trim() || null,
    },
  };
  if (!editing) input.recurrence = recurrenceOf(form);
  return input;
};

/** Problems with a form, keyed by field; empty when it can be saved. */
export const validateForm = (form, config) => {
  const errors = {};
  if (!form.title.trim()) errors.title = 'Give the room a name.';
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(form.startsAtLocal)) errors.startsAtLocal = 'Choose a date and time.';
  const duration = Number(form.durationMinutes);
  if (!Number.isInteger(duration) || duration < config.duration.min || duration > config.duration.max) {
    errors.durationMinutes = `Between ${config.duration.min} minutes and ${config.duration.max / 60} hours.`;
  }
  const early = Number(form.earlyEntryMinutes);
  if (early < config.earlyEntry.min || early > config.earlyEntry.max) {
    errors.earlyEntryMinutes = `Between ${config.earlyEntry.min} and ${config.earlyEntry.max} minutes.`;
  }
  if (form.capacityMode === 'limit') {
    const seats = Number(form.capacity);
    if (!Number.isInteger(seats) || seats < config.capacity.min || seats > config.capacity.max) {
      errors.capacity = `Between ${config.capacity.min} and ${config.capacity.max} people.`;
    }
  }
  if (form.repeat !== 'none') {
    if (form.repeatEnd === 'until' && !form.repeatUntil) errors.repeat = 'Choose the last date.';
    if (form.repeatEnd === 'until' && form.repeatUntil && form.repeatUntil < form.startsAtLocal.slice(0, 10)) {
      errors.repeat = 'The last date is before the first.';
    }
    if (form.repeatEnd === 'count' && (Number(form.repeatCount) < 2 || Number(form.repeatCount) > 52)) {
      errors.repeat = 'Between 2 and 52 dates.';
    }
  }
  if (form.access === 'invited' && form.invitees.length === 0 && form.cohosts.length === 0) {
    errors.invitees = 'Invite at least one person, or let anyone with the link in.';
  }
  return errors;
};

// ---------------------------------------------------------------------------
// Words
// ---------------------------------------------------------------------------

/** "in 2 h 5 min", "in 4 min", "in 35 s", "now". */
export const countdown = (ms) => {
  if (ms <= 0) return 'now';
  const seconds = Math.ceil(ms / 1000);
  if (seconds < 60) return `in ${seconds} s`;
  const minutes = Math.ceil(seconds / 60);
  if (minutes < 60) return `in ${minutes} min`;
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  if (hours < 48) return rest ? `in ${hours} h ${rest} min` : `in ${hours} h`;
  return `in ${Math.round(hours / 24)} days`;
};

/** "1 h 30 min", "45 min". */
export const durationLabel = (minutes) => {
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  if (!hours) return `${rest} min`;
  return rest ? `${hours} h ${rest} min` : `${hours} h`;
};

export const PHASE_LABELS = {
  scheduled: 'Upcoming',
  'doors-open': 'Doors open',
  live: 'Live now',
  ended: 'Ended',
  cancelled: 'Cancelled',
};

export const phaseLabel = (phase) => PHASE_LABELS[phase] ?? phase;

/** Why someone cannot enter, in words for the lobby. */
export const reasonText = (reason, room) => {
  switch (reason) {
    case 'room_not_open':
      return 'The doors are not open yet.';
    case 'room_closed_for_entry':
      return `New people could join until ${room?.lateJoinMinutes ?? 0} minutes after the start.`;
    case 'needs_admission':
      return 'A host lets people in.';
    case 'room_full':
      return 'All seats are taken.';
    case 'room_ended':
      return 'This room has ended.';
    case 'room_cancelled':
      return 'This room was cancelled.';
    case 'not_invited':
      return 'This room is for invited people only.';
    default:
      return null;
  }
};

/** The time in the room's zone, plus the viewer's own time when it differs. */
export const timeInZones = (value, roomZone, viewerZone, locale) => {
  const format = (zone) =>
    new Intl.DateTimeFormat(locale, { timeZone: zone, hour: '2-digit', minute: '2-digit' }).format(new Date(value));
  const own = format(viewerZone);
  const theirs = format(roomZone);
  return own === theirs ? own : `${own} your time · ${theirs} ${roomZone.split('/').pop().replace(/_/g, ' ')}`;
};

export const REPEAT_OPTIONS = [
  { value: 'none', label: 'Once' },
  { value: 'weekly', label: 'Every week' },
  { value: 'biweekly', label: 'Every two weeks' },
  { value: 'weekdays', label: 'Every weekday (Mon–Fri)' },
  { value: 'daily', label: 'Every day' },
];

// ---------------------------------------------------------------------------
// Joining by code or link
// ---------------------------------------------------------------------------

const ROOM_CODE = /^[a-hjkmnp-z2-9]{3}-[a-hjkmnp-z2-9]{4}-[a-hjkmnp-z2-9]{3}$/;
const ROOM_ID = /^[A-Za-z0-9._:-]{1,64}$/;

/**
 * Where a pasted code or link leads: a scheduled room's lobby, or — for any
 * other room id — the room itself, as before. null for anything else.
 */
export const destinationFor = (input) => {
  const text = String(input ?? '').trim();
  if (!text) return null;
  const fromLink = /\/rooms\/([^/?#\s]+)/.exec(text)?.[1];
  let raw = fromLink ?? text;
  try {
    raw = decodeURIComponent(raw);
  } catch {
    return null;
  }
  if (ROOM_CODE.test(raw.toLowerCase())) return `/rooms/${raw.toLowerCase()}/lobby`;
  if (ROOM_ID.test(raw)) return `/rooms/${raw}`;
  return null;
};
__RM_EOF__
echo "wrote apps/web/src/components/Rooms/roomModel.js"

mkdir -p apps/web/src/components/Rooms
cat > apps/web/src/components/Rooms/RoomCard.jsx <<'__RM_EOF__'
import { Link } from 'react-router-dom';
import { formatDate, formatTime } from '../../lib/preferences.js';
import { durationLabel, phaseLabel } from './roomModel.js';

/**
 * One room as a card: in "My rooms" and as the live preview while creating one  (Rooms)
 */
export default function RoomCard({ room, to = null, preview = false }) {
  const minutes = Math.round((new Date(room.endsAt) - new Date(room.startsAt)) / 60_000);
  const body = (
    <>
      <div className="rm-card__top">
        <span className={`rm-phase rm-phase--${room.phase ?? 'scheduled'}`}>{phaseLabel(room.phase ?? 'scheduled')}</span>
        {room.relation && room.relation !== 'invitee' ? (
          <span className="rm-hint">{room.relation === 'host' ? 'You host' : 'You co-host'}</span>
        ) : room.hostName ? (
          <span className="rm-hint">by {room.hostName}</span>
        ) : null}
      </div>
      <p className="rm-card__title">{room.title || (preview ? 'Your room' : 'Room')}</p>
      <p className="rm-card__when">
        {formatDate(room.startsAt)} · {formatTime(room.startsAt)}–{formatTime(room.endsAt)} · {durationLabel(minutes)}
      </p>
      <p className="rm-hint">
        Doors open {formatTime(room.doorsOpenAt)}
        {room.capacity ? ` · ${room.capacity} seats` : ''}
        {room.access === 'link' ? ' · anyone with the link' : room.inviteeCount ? ` · ${room.inviteeCount} invited` : ''}
      </p>
    </>
  );
  if (to) {
    return (
      <Link to={to} className="rm-card rm-card--link">
        {body}
      </Link>
    );
  }
  return <div className={preview ? 'rm-card rm-card--preview' : 'rm-card'}>{body}</div>;
}
__RM_EOF__
echo "wrote apps/web/src/components/Rooms/RoomCard.jsx"

mkdir -p apps/web/src/components/Rooms
cat > apps/web/src/components/Rooms/PeoplePicker.jsx <<'__RM_EOF__'
import { useEffect, useId, useMemo, useRef, useState } from 'react';
import { createProfileApi, useCore } from '@classroom/core-client';

/**
 * Pick people by name or @handle  (Rooms)
 *
 * Searches the organisation (GET /profiles/search — blocked people never
 * appear) and shows the chosen ones as removable chips. Keyboard: arrows to
 * move, Enter to add, Backspace on an empty field removes the last chip.
 */
export default function PeoplePicker({ label, hint, value, onChange, exclude = [], max = 300, placeholder = 'Name or @handle' }) {
  const { http } = useCore();
  const profiles = useMemo(() => createProfileApi(http), [http]);
  const inputId = useId();
  const [query, setQuery] = useState('');
  const [results, setResults] = useState([]);
  const [active, setActive] = useState(0);
  const [open, setOpen] = useState(false);
  const request = useRef(null);

  const taken = useMemo(() => new Set([...value.map((p) => p.userId), ...exclude]), [value, exclude]);

  useEffect(() => {
    const q = query.trim().replace(/^@/, '');
    if (q.length < 2) {
      setResults([]);
      return undefined;
    }
    const timer = window.setTimeout(async () => {
      request.current?.abort();
      const controller = new AbortController();
      request.current = controller;
      try {
        const { items } = await profiles.search({ q, limit: 8 }, controller.signal);
        setResults(items.filter((person) => !taken.has(person.userId)));
        setActive(0);
        setOpen(true);
      } catch {
        // A failed search just shows nothing; typing again retries.
      }
    }, 200);
    return () => window.clearTimeout(timer);
  }, [query, profiles, taken]);

  const add = (person) => {
    if (value.length >= max) return;
    onChange([...value, { userId: person.userId, displayName: person.displayName, handle: person.handle ?? null }]);
    setQuery('');
    setResults([]);
    setOpen(false);
  };

  const remove = (userId) => onChange(value.filter((person) => person.userId !== userId));

  const onKeyDown = (event) => {
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      setActive((index) => Math.min(index + 1, results.length - 1));
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      setActive((index) => Math.max(index - 1, 0));
    } else if (event.key === 'Enter' && open && results[active]) {
      event.preventDefault();
      add(results[active]);
    } else if (event.key === 'Backspace' && !query && value.length) {
      remove(value[value.length - 1].userId);
    } else if (event.key === 'Escape') {
      setOpen(false);
    }
  };

  return (
    <div className="rm-field">
      <label className="rm-label" htmlFor={inputId}>
        {label}
      </label>
      {hint ? <p className="rm-hint">{hint}</p> : null}
      <div className="rm-people">
        {value.map((person) => (
          <span key={person.userId} className="rm-chip">
            {person.displayName}
            <button type="button" aria-label={`Remove ${person.displayName}`} onClick={() => remove(person.userId)}>
              ×
            </button>
          </span>
        ))}
        <input
          id={inputId}
          className="rm-people__input"
          value={query}
          placeholder={value.length ? '' : placeholder}
          onChange={(event) => setQuery(event.target.value)}
          onKeyDown={onKeyDown}
          onFocus={() => results.length && setOpen(true)}
          onBlur={() => window.setTimeout(() => setOpen(false), 150)}
          role="combobox"
          aria-expanded={open}
          aria-autocomplete="list"
          disabled={value.length >= max}
        />
      </div>
      {open && results.length > 0 ? (
        <ul className="rm-suggest" role="listbox">
          {results.map((person, index) => (
            <li key={person.userId} role="option" aria-selected={index === active}>
              <button type="button" className={index === active ? 'is-active' : ''} onMouseDown={() => add(person)}>
                <span>{person.displayName}</span>
                {person.handle ? <span className="rm-hint">@{person.handle}</span> : null}
              </button>
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}
__RM_EOF__
echo "wrote apps/web/src/components/Rooms/PeoplePicker.jsx"

mkdir -p apps/web/src/components/Rooms
cat > apps/web/src/components/Rooms/DeviceCheck.jsx <<'__RM_EOF__'
import { useCallback, useEffect, useRef, useState } from 'react';
import { mediaConstraints } from '../../lib/preferences.js';

/**
 * Camera and microphone check before entering  (Rooms)
 *
 * The same capture settings the lesson will use (Settings → Lessons), so a
 * check that works here means the lesson will too. Starts only on request:
 * nobody's camera turns on just because they opened a link.
 */
export default function DeviceCheck() {
  const videoRef = useRef(null);
  const streamRef = useRef(null);
  const audioRef = useRef({ context: null, frame: 0 });
  const [running, setRunning] = useState(false);
  const [level, setLevel] = useState(0);
  const [error, setError] = useState(null);

  const stop = useCallback(() => {
    cancelAnimationFrame(audioRef.current.frame);
    audioRef.current.context?.close().catch(() => undefined);
    audioRef.current = { context: null, frame: 0 };
    streamRef.current?.getTracks().forEach((track) => track.stop());
    streamRef.current = null;
    if (videoRef.current) videoRef.current.srcObject = null;
    setRunning(false);
    setLevel(0);
  }, []);

  const start = useCallback(async () => {
    setError(null);
    try {
      const stream = await navigator.mediaDevices.getUserMedia(mediaConstraints({ audio: true, video: true }));
      streamRef.current = stream;
      if (videoRef.current) videoRef.current.srcObject = stream;
      const AudioContextClass = window.AudioContext ?? window.webkitAudioContext;
      if (AudioContextClass && stream.getAudioTracks().length) {
        const context = new AudioContextClass();
        const analyser = context.createAnalyser();
        analyser.fftSize = 512;
        context.createMediaStreamSource(stream).connect(analyser);
        const data = new Uint8Array(analyser.fftSize);
        const tick = () => {
          analyser.getByteTimeDomainData(data);
          let peak = 0;
          for (const value of data) peak = Math.max(peak, Math.abs(value - 128));
          setLevel(Math.min(1, peak / 64));
          audioRef.current.frame = requestAnimationFrame(tick);
        };
        audioRef.current = { context, frame: requestAnimationFrame(tick) };
      }
      setRunning(true);
    } catch (cause) {
      setError(
        cause?.name === 'NotAllowedError'
          ? 'Your browser was not allowed to use the camera and microphone. Allow it in the address bar.'
          : cause?.name === 'NotFoundError'
            ? 'No camera or microphone was found. You can still join and listen.'
            : 'The check could not start. Is another app using the camera?',
      );
      stop();
    }
  }, [stop]);

  useEffect(() => stop, [stop]);

  return (
    <div className="rm-device">
      <video ref={videoRef} className="rm-device__video" autoPlay playsInline muted aria-label="Camera preview" />
      <div className="rm-device__side">
        <div className="rm-meter" role="meter" aria-label="Microphone level" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(level * 100)}>
          <span style={{ width: `${Math.round(level * 100)}%` }} />
        </div>
        <p className="rm-hint">{running ? 'Say something: the bar should move.' : 'Check your camera and microphone before you go in.'}</p>
        <button type="button" className="btn btn--tiny" onClick={running ? stop : start}>
          {running ? 'Stop check' : 'Check camera and microphone'}
        </button>
        {error ? <p className="rm-error">{error}</p> : null}
      </div>
    </div>
  );
}
__RM_EOF__
echo "wrote apps/web/src/components/Rooms/DeviceCheck.jsx"

mkdir -p apps/web/src/components/Rooms
cat > apps/web/src/components/Rooms/RoomClock.jsx <<'__RM_EOF__'
import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { createRoomsApi, useCore } from '@classroom/core-client';
import { isRoomCode } from '../../lib/useRoomGate.js';
import { countdown } from './roomModel.js';
import './rooms.css';

/**
 * Time and door control inside a scheduled room  (Rooms)
 *
 * A quiet clock in the header; five minutes before the end a notice for
 * everyone, and for hosts: more time, end for everyone, and the people
 * knocking in the lobby. Renders nothing for rooms that were not scheduled.
 */
export default function RoomClock({ roomId, canModerate }) {
  const { http } = useCore();
  const rooms = useMemo(() => createRoomsApi(http), [http]);
  const [room, setRoom] = useState(null);
  const [knocks, setKnocks] = useState([]);
  const [skew, setSkew] = useState(0);
  const [now, setNow] = useState(Date.now());
  const [notice, setNotice] = useState(null);
  const scheduled = isRoomCode(roomId);

  const load = useCallback(async () => {
    if (!scheduled) return;
    try {
      const next = await rooms.get(roomId);
      setSkew(new Date(next.serverTime).getTime() - Date.now());
      setRoom(next);
      if (next.viewer.moderator && next.approval) setKnocks((await rooms.knocks(roomId)).items);
    } catch {
      // Keep the last known state; the next poll tries again.
    }
  }, [rooms, roomId, scheduled]);

  useEffect(() => {
    load();
    const poll = window.setInterval(load, canModerate ? 10_000 : 30_000);
    const tick = window.setInterval(() => setNow(Date.now()), 1_000);
    return () => {
      window.clearInterval(poll);
      window.clearInterval(tick);
    };
  }, [load, canModerate]);

  if (!scheduled || !room) return null;

  const left = new Date(room.endsAt).getTime() - (now + skew);
  const endingSoon = left > 0 && left <= 5 * 60_000;
  const moderator = room.viewer.moderator;

  const extend = async (minutes) => {
    try {
      await rooms.extend(roomId, minutes);
      setNotice(`${minutes} more minutes.`);
      await load();
    } catch (cause) {
      setNotice(cause?.detail ?? 'The room could not be extended.');
    }
    window.setTimeout(() => setNotice(null), 4_000);
  };

  const endNow = async () => {
    if (!window.confirm('End the room for everyone now?')) return;
    await rooms.end(roomId).catch(() => undefined);
  };

  const admit = async (userIds = []) => {
    await rooms.admit(roomId, userIds).catch(() => undefined);
    await load();
  };

  return (
    <>
      <span className={endingSoon ? 'rm-clock is-warn' : 'rm-clock'} title={`Ends at ${new Date(room.endsAt).toLocaleTimeString()}`}>
        {left > 0 ? `Ends ${countdown(left)}` : 'Ended'}
      </span>
      {moderator && knocks.length > 0 ? (
        <span className="rm-knocks" role="status">
          {knocks.length === 1 ? `${knocks[0].displayName} wants to join` : `${knocks.length} people want to join`}
          {knocks.length === 1 ? (
            <button type="button" className="btn btn--tiny btn--primary" onClick={() => admit([knocks[0].userId])}>
              Admit
            </button>
          ) : (
            <button type="button" className="btn btn--tiny btn--primary" onClick={() => admit([])}>
              Admit all
            </button>
          )}
          <Link className="btn btn--tiny" to={`/rooms/${roomId}/lobby`} target="_blank" rel="noreferrer">
            Details
          </Link>
        </span>
      ) : null}
      {endingSoon || (moderator && left <= 10 * 60_000 && left > 0) ? (
        <div className={endingSoon ? 'rm-ending is-warn' : 'rm-ending'} role="status">
          <span>{endingSoon ? `This room closes ${countdown(left)}.` : `The room ends ${countdown(left)}.`}</span>
          {moderator ? (
            <span className="rm-inline">
              {[5, 10, 15].map((minutes) => (
                <button key={minutes} type="button" className="btn btn--tiny" onClick={() => extend(minutes)}>
                  +{minutes} min
                </button>
              ))}
              <button type="button" className="btn btn--tiny btn--danger" onClick={endNow}>
                End for everyone
              </button>
            </span>
          ) : null}
          {notice ? <span className="rm-hint">{notice}</span> : null}
        </div>
      ) : null}
    </>
  );
}
__RM_EOF__
echo "wrote apps/web/src/components/Rooms/RoomClock.jsx"

mkdir -p apps/web/src/components/Rooms
cat > apps/web/src/components/Rooms/rooms.css <<'__RM_EOF__'
/* Rooms — dashboard, room editor, lobby, clock in the classroom.
   Colours follow app.css / @classroom/ui-tokens, with the same fallbacks. */

.rm-page { max-width: 1120px; }
.rm-head { display: flex; flex-wrap: wrap; align-items: flex-start; justify-content: space-between; gap: 16px; margin-bottom: 20px; }
.rm-head h1 { margin: 0 0 4px; }
.rm-subhead { font-size: 13px; text-transform: uppercase; letter-spacing: .08em; color: var(--color-muted, #8b93a1); margin: 20px 0 8px; }

.rm-label { display: block; font-weight: 600; font-size: 14px; }
.rm-hint { display: block; font-size: 12.5px; color: var(--color-muted, #8b93a1); margin: 2px 0 0; }
.rm-error { color: var(--color-danger, #f87171); font-size: 13px; margin: 4px 0 0; }
.rm-good { color: #4ade80; font-size: 13.5px; margin: 0; }
.rm-inline { display: inline-flex; flex-wrap: wrap; gap: 6px; align-items: center; }
.rm-link { border: 0; padding: 0; background: none; color: var(--color-accent, #7c93ff); font: inherit; font-size: 13px; cursor: pointer; text-decoration: underline; }
.rm-back { margin-top: 4px; align-self: flex-start; }

/* ---- form controls ---- */
.rm-field { display: flex; flex-direction: column; gap: 6px; position: relative; }
.rm-input { width: 100%; box-sizing: border-box; padding: 9px 11px; border: 1px solid var(--color-border, #2c3444); border-radius: 8px; background: var(--color-surface-2, #1e2531); color: inherit; font: inherit; font-size: 14px; }
.rm-input:focus-visible { outline: 2px solid var(--color-accent, #4c6fff); outline-offset: 1px; }
.rm-input--short { width: 6.5em; flex: 0 0 auto; }
textarea.rm-input { resize: vertical; }
.rm-row { display: flex; flex-wrap: wrap; gap: 10px; align-items: flex-end; }
.rm-row > .rm-field { flex: 1 1 200px; }
.rm-row > select.rm-input { width: auto; flex: 1 1 160px; }
.rm-chips { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
.rm-pill { padding: 6px 12px; border-radius: 999px; border: 1px solid var(--color-border, #2c3444); background: transparent; color: inherit; font: inherit; font-size: 13px; cursor: pointer; }
.rm-pill.is-on { background: var(--color-accent, #4c6fff); border-color: var(--color-accent, #4c6fff); color: #fff; }
.rm-range { width: 100%; accent-color: var(--color-accent, #4c6fff); }
.rm-range__scale { display: flex; justify-content: space-between; font-size: 12px; color: var(--color-muted, #8b93a1); }

.rm-choice { display: flex; flex-direction: column; gap: 6px; }
.rm-choice__option { display: flex; gap: 10px; align-items: flex-start; padding: 10px 12px; border-radius: 10px; border: 1px solid var(--color-border, #2c3444); cursor: pointer; }
.rm-choice__option.is-on { border-color: var(--color-accent, #4c6fff); background: rgba(76,111,255,.1); }
.rm-choice__option input { margin-top: 3px; }

.rm-switch-row { display: flex; justify-content: space-between; align-items: center; gap: 16px; cursor: pointer; }
.rm-switch { appearance: none; flex: 0 0 auto; width: 40px; height: 22px; border-radius: 11px; background: #3a4252; position: relative; cursor: pointer; transition: background .2s; }
.rm-switch::after { content: ''; position: absolute; top: 3px; left: 3px; width: 16px; height: 16px; border-radius: 50%; background: #fff; transition: transform .2s; }
.rm-switch:checked { background: var(--color-accent, #4c6fff); }
.rm-switch:checked::after { transform: translateX(18px); }
.rm-switch:focus-visible { outline: 2px solid var(--color-accent, #4c6fff); outline-offset: 2px; }

/* ---- people ---- */
.rm-people { display: flex; flex-wrap: wrap; gap: 6px; padding: 6px; border: 1px solid var(--color-border, #2c3444); border-radius: 8px; background: var(--color-surface-2, #1e2531); }
.rm-people__input { flex: 1 1 140px; min-width: 120px; border: 0; background: transparent; color: inherit; font: inherit; font-size: 14px; padding: 4px; outline: none; }
.rm-chip { display: inline-flex; align-items: center; gap: 4px; padding: 3px 4px 3px 10px; border-radius: 999px; background: rgba(76,111,255,.18); font-size: 13px; }
.rm-chip button { border: 0; background: transparent; color: inherit; font-size: 15px; line-height: 1; cursor: pointer; padding: 0 5px; opacity: .7; }
.rm-chip button:hover { opacity: 1; }
.rm-suggest { position: absolute; z-index: 20; top: 100%; left: 0; right: 0; margin: 4px 0 0; padding: 4px; list-style: none; border-radius: 10px; border: 1px solid var(--color-border, #2c3444); background: var(--color-surface, #151a24); box-shadow: 0 12px 28px rgba(0,0,0,.35); }
.rm-suggest button { width: 100%; display: flex; justify-content: space-between; gap: 8px; padding: 8px 10px; border: 0; border-radius: 6px; background: transparent; color: inherit; font: inherit; text-align: start; cursor: pointer; }
.rm-suggest button.is-active, .rm-suggest button:hover { background: rgba(76,111,255,.15); }

/* ---- editor ---- */
.rm-editor { display: grid; grid-template-columns: minmax(0, 1fr) 320px; gap: 28px; align-items: start; }
.rm-editor__form { display: flex; flex-direction: column; gap: 18px; min-width: 0; }
.rm-editor__side { position: sticky; top: 16px; display: flex; flex-direction: column; gap: 12px; }
.rm-section { display: flex; flex-direction: column; gap: 14px; margin: 0; padding: 18px; border: 1px solid var(--color-border, #222936); border-radius: 14px; background: var(--color-surface, #151a24); }
.rm-section legend { padding: 0 6px; font-weight: 700; font-size: 15px; }
.rm-submit { width: 100%; padding: 12px 16px; font-size: 15px; }
.rm-conflict { padding: 10px 12px; border-radius: 10px; background: #3a2f10; color: #fbbf24; font-size: 13px; }
.rm-conflict ul { margin: 6px 0 0; padding-inline-start: 18px; }
.rm-dates { font-size: 13px; }
.rm-dates ul { margin: 6px 0 0; padding-inline-start: 18px; max-height: 180px; overflow: auto; }
@media (max-width: 860px) {
  .rm-editor { grid-template-columns: 1fr; }
  .rm-editor__side { position: static; }
}

/* ---- cards ---- */
.rm-cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 12px; }
.rm-card { display: flex; flex-direction: column; gap: 4px; padding: 16px; border-radius: 14px; border: 1px solid var(--color-border, #222936); background: var(--color-surface, #151a24); color: inherit; text-decoration: none; }
.rm-card--link { transition: border-color .15s, transform .15s; }
.rm-card--link:hover, .rm-card--link:focus-visible { border-color: var(--color-accent, #4c6fff); transform: translateY(-1px); }
.rm-card--preview { border-style: dashed; }
.rm-card__top { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
.rm-card__title { margin: 4px 0 0; font-size: 16px; font-weight: 700; overflow-wrap: anywhere; }
.rm-card__when { margin: 0; font-size: 13.5px; }
.rm-phase { font-size: 11.5px; font-weight: 700; padding: 2px 8px; border-radius: 999px; background: #262e3d; }
.rm-phase--doors-open { background: #10361f; color: #4ade80; }
.rm-phase--live { background: #4c1d1d; color: #fca5a5; }
.rm-phase--live::before { content: '● '; }
.rm-phase--ended, .rm-phase--cancelled { opacity: .7; }

/* ---- dashboard ---- */
.rm-dash { display: grid; grid-template-columns: minmax(0, 1fr) 300px; gap: 24px; align-items: start; }
.rm-dash__main { min-width: 0; }
.rm-join { max-width: none; }
.rm-join h2 { margin: 0 0 4px; font-size: 16px; }
.rm-tabs { display: inline-flex; gap: 2px; padding: 3px; border-radius: 10px; background: var(--color-surface-2, #1e2531); margin-bottom: 12px; }
.rm-tab { padding: 6px 14px; border: 0; border-radius: 8px; background: transparent; color: inherit; font: inherit; font-size: 13.5px; cursor: pointer; }
.rm-tab.is-on { background: var(--color-surface, #151a24); font-weight: 600; }
.rm-empty { display: flex; flex-direction: column; align-items: flex-start; gap: 10px; padding: 28px; border: 1px dashed var(--color-border, #2c3444); border-radius: 14px; }
.rm-empty p { margin: 0; }
@media (max-width: 860px) { .rm-dash { grid-template-columns: 1fr; } }

/* ---- lobby ---- */
.rm-lobby { min-height: 100vh; box-sizing: border-box; padding: 32px 20px; display: flex; justify-content: center; align-items: flex-start; }
.rm-lobby__grid { width: 100%; max-width: 1040px; display: grid; grid-template-columns: minmax(0, 1fr) 340px; gap: 24px; align-items: start; }
.rm-lobby__card { display: flex; flex-direction: column; gap: 10px; padding: 28px; border-radius: 18px; border: 1px solid var(--color-border, #222936); background: var(--color-surface, #151a24); }
.rm-lobby__title { margin: 4px 0 0; font-size: clamp(22px, 3vw, 30px); overflow-wrap: anywhere; }
.rm-lobby__text { margin: 0; white-space: pre-wrap; }
.rm-lobby__side { display: flex; flex-direction: column; gap: 14px; }
.rm-agenda { padding: 12px 14px; border-radius: 12px; background: var(--color-surface-2, #1e2531); }
.rm-agenda ol { margin: 6px 0 0; padding-inline-start: 20px; display: flex; flex-direction: column; gap: 3px; }
.rm-action { display: flex; flex-direction: column; align-items: flex-start; gap: 8px; margin: 10px 0; padding: 18px; border-radius: 14px; background: var(--color-surface-2, #1e2531); }
.rm-enter { padding: 12px 26px; font-size: 16px; }
.rm-countdown { margin: 0; font-size: 20px; font-weight: 700; font-variant-numeric: tabular-nums; }
.rm-facts { margin: 0; padding-inline-start: 18px; font-size: 13px; color: var(--color-muted, #8b93a1); display: flex; flex-direction: column; gap: 2px; }
.rm-panel { display: flex; flex-direction: column; gap: 8px; padding: 16px; border-radius: 14px; border: 1px solid var(--color-border, #222936); background: var(--color-surface, #151a24); }
.rm-panel__head { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
.rm-list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 6px; }
.rm-list li { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
.rm-confirm { display: flex; flex-direction: column; gap: 8px; }
.rm-share { display: flex; flex-direction: column; gap: 8px; padding: 16px; border-radius: 14px; border: 1px solid var(--color-border, #222936); background: var(--color-surface, #151a24); }
.rm-share.is-new { border-color: #4ade80; box-shadow: 0 0 0 3px rgba(74,222,128,.15); }
.rm-share__row { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
.rm-share__url { flex: 1 1 100%; padding: 8px 10px; border-radius: 8px; background: var(--color-surface-2, #1e2531); font-size: 12.5px; overflow-wrap: anywhere; }
.rm-share__qr { align-self: flex-start; border-radius: 8px; background: #fff; padding: 4px; }
@media (max-width: 860px) {
  .rm-lobby { padding: 16px 12px; }
  .rm-lobby__grid { grid-template-columns: 1fr; }
}

/* ---- device check ---- */
.rm-device { display: flex; flex-direction: column; gap: 10px; }
.rm-device__video { width: 100%; aspect-ratio: 16 / 9; border-radius: 10px; background: #0b0e14; object-fit: cover; transform: scaleX(-1); }
.rm-device__side { display: flex; flex-direction: column; gap: 6px; align-items: flex-start; }
.rm-meter { width: 100%; height: 8px; border-radius: 4px; background: #262e3d; overflow: hidden; }
.rm-meter span { display: block; height: 100%; background: #22c55e; transition: width 60ms linear; }

/* ---- in the classroom ---- */
.rm-clock { font-size: 12.5px; padding: 3px 10px; border-radius: 999px; background: #262e3d; font-variant-numeric: tabular-nums; }
.rm-clock.is-warn { background: #3a2f10; color: #fbbf24; }
.rm-knocks { display: inline-flex; align-items: center; gap: 6px; font-size: 13px; padding: 3px 4px 3px 10px; border-radius: 999px; background: rgba(76,111,255,.18); }
.rm-ending { flex: 1 1 100%; display: flex; flex-wrap: wrap; align-items: center; gap: 10px; padding: 8px 12px; border-radius: 10px; background: #262e3d; font-size: 13.5px; }
.rm-ending.is-warn { background: #3a2f10; color: #fbbf24; }

@media (prefers-reduced-motion: reduce) {
  .rm-card--link, .rm-switch, .rm-switch::after { transition: none; }
}

/* The ending notice takes its own line in the classroom header. */
.room__header:has(.rm-ending) { flex-wrap: wrap; }
__RM_EOF__
echo "wrote apps/web/src/components/Rooms/rooms.css"

mkdir -p apps/web/src/components/Rooms/__checks__
cat > apps/web/src/components/Rooms/__checks__/roomModel.check.mjs <<'__RM_EOF__'
// Rooms — the pure parts of the room form and the lobby.
// Run: node --test apps/web/src/components/Rooms/__checks__/*.check.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  countdown,
  defaultForm,
  destinationFor,
  durationLabel,
  formToInput,
  localInputValue,
  nextSlot,
  recurrenceOf,
  roomToForm,
  validateForm,
  weekdayOf,
} from '../roomModel.js';

const config = {
  earlyEntry: { min: 3, max: 10, default: 5 },
  duration: { min: 10, max: 480, presets: [30, 45, 60, 90] },
  capacity: { min: 2, max: 300, default: 25 },
};

test('local input values follow the time zone', () => {
  const moment = '2026-03-10T17:30:00Z';
  assert.equal(localInputValue(moment, 'UTC'), '2026-03-10T17:30');
  assert.equal(localInputValue(moment, 'Europe/Berlin'), '2026-03-10T18:30');
  assert.equal(localInputValue(moment, 'America/New_York'), '2026-03-10T13:30');
});

test('the default start is the next quarter hour at least 15 minutes away', () => {
  const slot = nextSlot(new Date('2026-03-10T10:07:12Z'));
  assert.equal(slot.toISOString(), '2026-03-10T10:30:00.000Z');
  assert.equal(nextSlot(new Date('2026-03-10T10:45:00Z')).toISOString(), '2026-03-10T11:00:00.000Z');
});

test('weekdays and series', () => {
  assert.equal(weekdayOf('2026-10-06T18:00'), 'TU');
  const form = { ...defaultForm({ timeZone: 'UTC' }), startsAtLocal: '2026-10-06T18:00' };
  assert.equal(recurrenceOf(form), null);
  assert.deepEqual(recurrenceOf({ ...form, repeat: 'weekly', repeatCount: 6 }), { freq: 'WEEKLY', byDay: ['TU'], count: 6 });
  assert.deepEqual(recurrenceOf({ ...form, repeat: 'biweekly', repeatEnd: 'until', repeatUntil: '2026-12-01' }), {
    freq: 'WEEKLY', interval: 2, byDay: ['TU'], until: '2026-12-01',
  });
  assert.deepEqual(recurrenceOf({ ...form, repeat: 'weekdays', repeatCount: 10 }).byDay, ['MO', 'TU', 'WE', 'TH', 'FR']);
});

test('a form becomes the API input, and an edit carries no series', () => {
  const form = {
    ...defaultForm({ timeZone: 'Europe/Berlin' }),
    title: '  Maths revision ',
    startsAtLocal: '2026-10-06T18:00',
    invitees: [{ userId: 'u1', displayName: 'Anna' }],
    capacityMode: 'plan',
    repeat: 'weekly',
    agenda: ' 1. Fractions ',
  };
  const input = formToInput(form);
  assert.equal(input.title, 'Maths revision');
  assert.equal(input.capacity, null);
  assert.deepEqual(input.inviteeIds, ['u1']);
  assert.equal(input.settings.agenda, '1. Fractions');
  assert.equal(input.recurrence.freq, 'WEEKLY');
  assert.equal('recurrence' in formToInput(form, { editing: true }), false);
});

test('validation explains what is missing', () => {
  const base = { ...defaultForm({ timeZone: 'UTC' }), title: 'Room', access: 'link' };
  assert.deepEqual(validateForm(base, config), {});
  assert.ok(validateForm({ ...base, title: ' ' }, config).title);
  assert.ok(validateForm({ ...base, earlyEntryMinutes: 15 }, config).earlyEntryMinutes);
  assert.ok(validateForm({ ...base, earlyEntryMinutes: 2 }, config).earlyEntryMinutes);
  assert.ok(validateForm({ ...base, capacity: 1 }, config).capacity);
  assert.ok(validateForm({ ...base, access: 'invited' }, config).invitees);
  assert.ok(validateForm({ ...base, repeat: 'weekly', repeatEnd: 'until', repeatUntil: '2000-01-01' }, config).repeat);
});

test('an existing room fills the editor', () => {
  const form = roomToForm({
    title: 'T', description: null, agenda: 'A', startsAt: '2026-10-06T16:00:00Z', endsAt: '2026-10-06T17:30:00Z',
    timeZone: 'Europe/Berlin', earlyEntryMinutes: 7, lateJoinMinutes: 10, capacity: null, access: 'link', approval: true,
    invitees: [], cohosts: [], settings: { learnersJoinMuted: true },
  });
  assert.equal(form.startsAtLocal, '2026-10-06T18:00');
  assert.equal(form.durationMinutes, 90);
  assert.equal(form.capacityMode, 'plan');
  assert.equal(form.learnersJoinMuted, true);
});

test('countdowns and durations read naturally', () => {
  assert.equal(countdown(0), 'now');
  assert.equal(countdown(35_000), 'in 35 s');
  assert.equal(countdown(4 * 60_000 + 1), 'in 5 min');
  assert.equal(countdown((2 * 60 + 5) * 60_000), 'in 2 h 5 min');
  assert.equal(countdown(3 * 24 * 3_600_000), 'in 3 days');
  assert.equal(durationLabel(45), '45 min');
  assert.equal(durationLabel(90), '1 h 30 min');
  assert.equal(durationLabel(120), '2 h');
});

test('a pasted code or link leads to the right place', () => {
  assert.equal(destinationFor('kqz-7hfd-2mx'), '/rooms/kqz-7hfd-2mx/lobby');
  assert.equal(destinationFor(' KQZ-7HFD-2MX '), '/rooms/kqz-7hfd-2mx/lobby');
  assert.equal(destinationFor('https://app.example/rooms/kqz-7hfd-2mx/lobby'), '/rooms/kqz-7hfd-2mx/lobby');
  assert.equal(destinationFor('https://app.example/rooms/kqz-7hfd-2mx'), '/rooms/kqz-7hfd-2mx/lobby');
  assert.equal(destinationFor('00000000-0000-0000-0000-000000000000'), '/rooms/00000000-0000-0000-0000-000000000000');
  assert.equal(destinationFor('not a room!'), null);
  assert.equal(destinationFor(''), null);
});
__RM_EOF__
echo "wrote apps/web/src/components/Rooms/__checks__/roomModel.check.mjs"

cat > .rooms-patch.mjs <<'__RM_EOF__'
import { existsSync, readFileSync, writeFileSync } from 'node:fs';

/*
 * Rooms — edits to files that stay otherwise untouched.
 * Every anchor must be found exactly once; if one is not, nothing is written
 * to any of these files and the installer stops.
 */

const plan = [
  {
    file: 'server/src/app.js',
    marker: 'scheduledRoomsRoutes',
    edits: [
      {
        name: 'import the room planning routes',
        regex: /^import\s+classroomRoutes\s+from\s+['"]([^'"]*)classroom\.routes\.js['"];?[ \t]*\r?\n/m,
        replace: (m, dir) => `${m}import scheduledRoomsRoutes from '${dir}scheduledRooms.routes.js';\n`,
      },
      {
        name: 'mount them under /scheduled-rooms',
        regex: /^([ \t]*)app\.use\(\s*['"]\/classroom['"],\s*classroomRoutes\s*\);[^\n]*\r?\n/m,
        replace: (m, indent) => `${m}${indent}app.use('/scheduled-rooms', scheduledRoomsRoutes); // Rooms\n`,
      },
    ],
  },
  {
    file: 'server/src/signaling/socketHandlers.js',
    marker: 'ScheduledRooms.admissionFor',
    edits: [
      {
        name: 'import the scheduled rooms',
        find: "import * as CapacityGuard from '../capacity/CapacityGuard.js';\n",
        replace:
          "import * as CapacityGuard from '../capacity/CapacityGuard.js';\n" +
          "import * as ScheduledRooms from '../rooms/ScheduledRooms.js';\n",
      },
      {
        name: 'rooms close at their end time; freed seats go to the waiting list',
        find: "  namespace.on('connection', (socket) => registerSocket(namespace, socket));\n  return namespace;\n",
        replace:
          "  namespace.on('connection', (socket) => registerSocket(namespace, socket));\n" +
          '\n' +
          '  // Scheduled rooms: closed at their end time, freed seats handed to the\n' +
          '  // waiting list (rooms/ScheduledRooms.js).\n' +
          '  ScheduledRooms.startEnforcer({ listRoomIds: RoomManager.listRoomIds, closeRoom: RoomManager.closeRoom });\n' +
          '  return namespace;\n',
      },
      {
        name: 'doors, guest list and seat limit of a scheduled room',
        find:
          '  const seat = await CapacityGuard.reserveSeat({ tenantId, roomId, userId });\n' +
          "  if (!seat.granted) fail('room_full', 'The room is full for this plan');\n",
        replace:
          '  // A room someone scheduled (rooms/ScheduledRooms.js): when its doors open,\n' +
          '  // who is on the guest list, whether a host lets people in, how many seats.\n' +
          '  // null for every other room, whose join is unchanged.\n' +
          '  const scheduled = await ScheduledRooms.admissionFor({ roomId, userId, tenantId });\n' +
          '  if (scheduled && !scheduled.allowed) fail(scheduled.code, scheduled.message);\n' +
          '\n' +
          '  const seat = await CapacityGuard.reserveSeat({ tenantId, roomId, userId, limit: scheduled?.capacity ?? 0 });\n' +
          "  if (!seat.granted) fail('room_full', 'The room is full. Join the waiting list from the lobby.');\n",
      },
      {
        name: "the scheduled host owns the room, whoever opens it",
        find:
          '      (await RoomManager.createRoom({\n' +
          '        roomId,\n' +
          '        lessonId: payload.lessonId ?? null,\n' +
          '        hostUserId: userId, // whoever opens the room owns it\n' +
          '      }));\n',
        replace:
          '      (await RoomManager.createRoom({\n' +
          '        roomId,\n' +
          '        lessonId: payload.lessonId ?? null,\n' +
          '        // A scheduled room belongs to its host; any other room to whoever opens it.\n' +
          '        hostUserId: scheduled?.hostId ?? userId,\n' +
          '      }));\n' +
          '    ScheduledRooms.applyToRoom(room, scheduled);\n',
      },
      {
        name: 'hosts and co-hosts of a scheduled room skip the classroom waiting room',
        find: '    const knocked = ModerationControls.knock(room, { peerId: socket.id, user });\n',
        replace:
          "    const knocked = scheduled?.role === 'host' || scheduled?.role === 'cohost'\n" +
          '      ? { admitted: true }\n' +
          '      : ModerationControls.knock(room, { peerId: socket.id, user });\n',
      },
      {
        name: 'co-hosts join as co-hosts',
        find: "        role: room.hostUserId === userId ? 'host' : 'learner',\n",
        replace: "        role: scheduled?.role ?? (room.hostUserId === userId ? 'host' : 'learner'),\n",
      },
    ],
  },
  {
    file: 'server/src/queues/workers/notificationWorker.js',
    marker: 'reminderUrl',
    edits: [
      {
        name: 'reminders for a scheduled room link to its lobby',
        find: "const redis = utilityConnection('notify');\n",
        replace:
          "const redis = utilityConnection('notify');\n" +
          '\n' +
          '/** Where a reminder leads: a scheduled room\'s lobby, a lesson, or the dashboard. */\n' +
          'const reminderUrl = async (session, sessionId) => {\n' +
          '  try {\n' +
          "    const { pool } = await import('../../db/pool.js');\n" +
          "    const { rows } = await pool.query('SELECT room_code FROM scheduled_sessions WHERE id = $1', [sessionId]);\n" +
          '    if (rows[0]?.room_code) return `/rooms/${rows[0].room_code}/lobby`;\n' +
          '  } catch {\n' +
          '    // Before migration 024 there is no room_code; fall through.\n' +
          '  }\n' +
          "  return session.lessonId ? `/lessons/${session.lessonId}/live` : '/';\n" +
          '};\n',
      },
      {
        name: 'use it',
        find: "      url: session.lessonId ? `/lessons/${session.lessonId}/live` : '/',\n",
        replace: '      url: await reminderUrl(session, sessionId),\n',
      },
    ],
  },
  {
    file: 'packages/core-client/src/index.ts',
    marker: 'roomsApi',
    edits: [
      {
        name: 'export the rooms API',
        find: "export * from './api/profileApi.js';\n",
        replace: "export * from './api/profileApi.js';\nexport * from './api/roomsApi.js';\n",
      },
    ],
  },
  {
    file: 'apps/web/src/main.jsx',
    marker: 'RoomLobbyPage',
    edits: [
      {
        name: 'the new pages, loaded on demand',
        find: "const NotFoundPage = lazy(() => import('./pages/NotFoundPage.jsx'));\n",
        replace:
          "const NotFoundPage = lazy(() => import('./pages/NotFoundPage.jsx'));\n" +
          "const RoomEditorPage = lazy(() => import('./pages/RoomEditorPage.jsx'));\n" +
          "const RoomLobbyPage = lazy(() => import('./pages/RoomLobbyPage.jsx'));\n",
      },
      {
        name: 'create and edit inside the app layout',
        find: '                <Route path="settings/:tab" element={<SettingsPage />} />\n',
        replace:
          '                <Route path="settings/:tab" element={<SettingsPage />} />\n' +
          '                <Route path="rooms/new" element={<RoomEditorPage />} />\n' +
          '                <Route path="rooms/:code/edit" element={<RoomEditorPage />} />\n',
      },
      {
        name: 'the lobby, full screen like the classroom',
        find: '              <Route path="/rooms/:roomId" element={<ClassroomPage />} />\n',
        replace:
          '              <Route path="/rooms/:code/lobby" element={<RoomLobbyPage />} />\n' +
          '              <Route path="/rooms/:roomId" element={<ClassroomPage />} />\n',
      },
    ],
  },
  {
    file: 'apps/web/src/pages/ClassroomPage.jsx',
    marker: 'useRoomGate',
    edits: [
      {
        name: 'imports',
        find: "import { lessonJoinDefaults, withMediaPreferences } from '../lib/preferences.js';\n",
        replace:
          "import { lessonJoinDefaults, withMediaPreferences } from '../lib/preferences.js';\n" +
          "import { useRoomGate } from '../lib/useRoomGate.js';\n" +
          "import RoomClock from '../components/Rooms/RoomClock.jsx';\n",
      },
      {
        name: 'ask whether this person may enter before opening a socket',
        find: '  const { session, status } = useCore();\n',
        replace:
          '  const { session, status } = useCore();\n' +
          '  // Scheduled rooms: too early, not invited or no seat → the lobby, not an error.\n' +
          '  const gate = useRoomGate(roomId);\n',
      },
      {
        name: 'join only once the gate says so',
        find: "      autoJoin: status === 'authenticated',\n",
        replace: "      autoJoin: status === 'authenticated' && gate.ready && gate.canEnter,\n",
      },
      {
        name: 'dependencies',
        find: '    [sfu, deviceAdapter, roomId, status, onReaction],\n',
        replace: '    [sfu, deviceAdapter, roomId, status, onReaction, gate.ready, gate.canEnter],\n',
      },
      {
        name: 'not yet, not invited or full: to the lobby',
        find: "  if (status === 'restoring') {\n",
        replace:
          '  if (gate.ready && !gate.canEnter) {\n' +
          '    return <Navigate to={`/rooms/${roomId}/lobby`} replace />;\n' +
          '  }\n' +
          '\n' +
          "  if (status === 'restoring') {\n",
      },
      {
        name: 'time left, more time and knocks in the header',
        find: '        <h1 className="room__title">Lesson</h1>\n',
        replace:
          '        <h1 className="room__title">Lesson</h1>\n' +
          '        <RoomClock roomId={roomId} canModerate={canModerate} />\n',
      },
    ],
  },
];

const count = (src, edit) => {
  if (edit.regex) {
    const global = new RegExp(edit.regex.source, edit.regex.flags.includes('g') ? edit.regex.flags : `${edit.regex.flags}g`);
    return [...src.matchAll(global)].length;
  }
  return src.split(edit.find).length - 1;
};

const apply = (src, edit) =>
  edit.regex ? src.replace(edit.regex, edit.replace) : src.replace(edit.find, () => edit.replace);

const results = [];
for (const entry of plan) {
  if (!existsSync(entry.file)) {
    console.error(`${entry.file}: not found. Nothing was changed in any patched file.`);
    process.exit(1);
  }
  let src = readFileSync(entry.file, 'utf8');
  if (src.includes(entry.marker)) {
    console.log(`${entry.file}: already patched, nothing to do`);
    continue;
  }
  for (const edit of entry.edits) {
    const n = count(src, edit);
    if (n !== 1) {
      console.error(`${entry.file}: "${edit.name}": expected the anchor exactly once, found ${n}. Nothing was changed in any patched file.`);
      process.exit(1);
    }
  }
  for (const edit of entry.edits) src = apply(src, edit);
  results.push({ ...entry, src });
}

for (const entry of results) {
  writeFileSync(entry.file, entry.src);
  console.log('patched', entry.file);
  for (const edit of entry.edits) console.log('  -', edit.name);
}
__RM_EOF__
node .rooms-patch.mjs
rm -f .rooms-patch.mjs

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
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
  echo
  echo "A file did not pass its check (see above). Undo with: bash rooms-install.sh --restore" >&2
  exit 1
fi

echo "--- rules (node --test)"
CHECKS=$(ls server/test/settings/*.check.mjs server/test/rooms/*.check.mjs \
  apps/web/src/components/Settings/__checks__/*.check.mjs apps/web/src/components/Rooms/__checks__/*.check.mjs 2>/dev/null || true)
if node --test $CHECKS > .rooms-test.log 2>&1; then
  # Node 22 prints "# pass N", Node 24 "ℹ pass N".
  PASSED=$(grep -E '^(# |ℹ )pass [0-9]+' .rooms-test.log | tail -1 | awk '{print $NF}')
  echo "ok  ${PASSED:-all} rule tests passed"
  rm -f .rooms-test.log
else
  cat .rooms-test.log
  rm -f .rooms-test.log
  echo "The rule checks failed (see above). Undo with: bash rooms-install.sh --restore" >&2
  exit 1
fi

if ! (cd server && node --input-type=module -e "await import('qrcode')") >/dev/null 2>&1; then
  echo "NOTE qrcode is not installed: the lobby shows the link without a QR code."
fi

# ---------------------------------------------------------------------------
# Database and restart
# ---------------------------------------------------------------------------
echo "--- database"
if SERVICE_ROLE=api npm run db:migrate; then
  # node --watch waits for a file change after a failed start; this is one.
  touch server/src/server.js
  [ -f server/src/worker.js ] && touch server/src/worker.js
  echo
  echo "Rooms installed and migration 024 applied. The API restarts on its own;"
  echo "reload the browser tabs with Ctrl+Shift+R. \"+ New room\" is on the dashboard."
  if command -v pgrep >/dev/null 2>&1 && ! pgrep -f "src/worker.js" >/dev/null 2>&1; then
    echo
    echo "Note: the worker is not running. Invitations, reminders and \"a seat is free\""
    echo "are delivered by it. Start it in a second terminal:"
    echo "  npm run dev:worker -w $(node -p "require('./server/package.json').name" 2>/dev/null || echo @classroom/server)"
  fi
else
  echo
  echo "The files are installed, but the migration did not run. Start the containers"
  echo "(./dev-up.sh), then: SERVICE_ROLE=api npm run db:migrate && touch server/src/server.js"
  exit 1
fi