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
