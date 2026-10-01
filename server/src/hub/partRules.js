// classroom-app/server/src/hub/partRules.js
/**
 * Community, part 3 — rules  (Community)
 *
 * Pure, like hubRules.js: no database, no clock of its own.
 *
 *   study partners   who might study well together, and why — in words a
 *                    person can check ("both in Year 7 maths", "both free
 *                    Tuesday evenings"), never a mystery score
 *   helper badges    recognition for answers others accepted, without points
 *                    or leaderboards
 *   late-night nudge "send at 8:00" for posts written late at night
 *   calm mode        one reply per person every few minutes in a heated thread
 */

import { z } from 'zod';

// ---------------------------------------------------------------------------
// Study partners
// ---------------------------------------------------------------------------

export const DAYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
export const PARTS = ['morning', 'afternoon', 'evening'];
export const SLOTS = DAYS.flatMap((day) => PARTS.map((part) => `${day}-${part}`));
const DAY_NAMES = { mon: 'Monday', tue: 'Tuesday', wed: 'Wednesday', thu: 'Thursday', fri: 'Friday', sat: 'Saturday', sun: 'Sunday' };

export const slotLabel = (slot) => {
  const [day, part] = String(slot).split('-');
  return `${DAY_NAMES[day] ?? day} ${part}s`;
};

export const StudyProfileSchema = z
  .object({
    active: z.boolean().default(true),
    subjects: z.array(z.string().trim().toLowerCase().min(1).max(30)).max(8).default([]),
    availability: z.array(z.enum(SLOTS)).max(SLOTS.length).default([]),
    note: z.string().trim().max(200).nullish(),
  })
  .strict();

export const StudyRequestSchema = z.object({ message: z.string().trim().max(300).nullish() }).strict();

/**
 * How well two people might study together, and the reasons in words.
 * Shared spaces weigh most (they already learn the same thing), then shared
 * subjects, then times both are free. Nothing in common: null, no suggestion.
 */
export const scoreMatch = ({ me, other, sharedSpaces = [] }) => {
  const reasons = [];
  let score = 0;

  if (sharedSpaces.length) {
    score += 3 * Math.min(sharedSpaces.length, 3);
    reasons.push(`Both in ${sharedSpaces.slice(0, 2).join(' and ')}${sharedSpaces.length > 2 ? ` and ${sharedSpaces.length - 2} more` : ''}`);
  }
  const subjects = me.subjects.filter((subject) => other.subjects.includes(subject));
  if (subjects.length) {
    score += 2 * Math.min(subjects.length, 3);
    reasons.push(`Both study ${subjects.slice(0, 3).join(', ')}`);
  }
  const times = me.availability.filter((slot) => other.availability.includes(slot));
  if (times.length) {
    score += Math.min(times.length, 4);
    reasons.push(`Both free ${times.slice(0, 2).map(slotLabel).join(' and ')}`);
  }
  return score > 0 ? { score, reasons, sharedSubjects: subjects, sharedTimes: times } : null;
};

// ---------------------------------------------------------------------------
// Helper badges
// ---------------------------------------------------------------------------

export const HELPER_AT = 3;
export const MENTOR_AT = 10;

/** Accepted answers in one space → a quiet badge, or nothing. */
export const helperLevel = (acceptedAnswers) => {
  if (acceptedAnswers >= MENTOR_AT) return { level: 'mentor', label: 'Mentor' };
  if (acceptedAnswers >= HELPER_AT) return { level: 'helper', label: 'Helper' };
  return null;
};

// ---------------------------------------------------------------------------
// Late-night nudge
// ---------------------------------------------------------------------------

export const NIGHT_FROM = 22;
export const MORNING_AT = 8;

const partsIn = (date, timeZone) => {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat('en-US', {
      timeZone, year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', second: 'numeric', hourCycle: 'h23',
    })
      .formatToParts(date)
      .filter((part) => part.type !== 'literal')
      .map((part) => [part.type, Number(part.value)]),
  );
  return { ...parts, hour: parts.hour === 24 ? 0 : parts.hour };
};

/** The UTC instant of a wall-clock time in a zone (handles daylight-saving changes). */
const zonedToUtc = ({ year, month, day, hour, minute = 0 }, timeZone) => {
  let guess = Date.UTC(year, month - 1, day, hour, minute);
  for (let i = 0; i < 3; i += 1) {
    const local = partsIn(new Date(guess), timeZone);
    const asUtc = Date.UTC(local.year, local.month - 1, local.day, local.hour, local.minute);
    const diff = Date.UTC(year, month - 1, day, hour, minute) - asUtc;
    if (diff === 0) break;
    guess += diff;
  }
  return new Date(guess);
};

/** Late at night where the writer is: from 22:00 until 7:59. */
export const isLateNight = (now, timeZone) => {
  const { hour } = partsIn(now, timeZone);
  return hour >= NIGHT_FROM || hour < MORNING_AT;
};

/** The next 8:00 in the writer's time zone: today if it is before 8, else tomorrow. */
export const nextMorning = (now, timeZone, hour = MORNING_AT) => {
  const local = partsIn(now, timeZone);
  let target = zonedToUtc({ year: local.year, month: local.month, day: local.day, hour }, timeZone);
  if (target.getTime() <= now.getTime()) {
    const tomorrow = new Date(Date.UTC(local.year, local.month - 1, local.day + 1));
    target = zonedToUtc({ year: tomorrow.getUTCFullYear(), month: tomorrow.getUTCMonth() + 1, day: tomorrow.getUTCDate(), hour }, timeZone);
  }
  return target;
};

export const ScheduleSchema = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('reply'), targetId: z.string().uuid(), body: z.string().trim().min(1).max(10000), hiddenSolution: z.boolean().default(false) }).strict(),
  z.object({
    kind: z.literal('thread'),
    targetId: z.string().uuid(),
    title: z.string().trim().min(3).max(160),
    body: z.string().trim().min(1).max(10000),
    threadKind: z.enum(['discussion', 'question']).default('discussion'),
    anonymous: z.boolean().default(false),
  }).strict(),
  z.object({ kind: z.literal('chat'), targetId: z.string().uuid(), body: z.string().trim().min(1).max(2000) }).strict(),
]);

// ---------------------------------------------------------------------------
// Calm mode
// ---------------------------------------------------------------------------

export const CALM_OPTIONS = [0, 120, 300, 900];

/** Seconds until this person may write again, or 0. */
export const calmWait = ({ slowSeconds, lastPostAt, now = Date.now() }) => {
  if (!slowSeconds || !lastPostAt) return 0;
  const left = Math.ceil((new Date(lastPostAt).getTime() + slowSeconds * 1000 - now) / 1000);
  return Math.max(0, left);
};

export const calmMessage = (seconds) => {
  const minutes = Math.ceil(seconds / 60);
  return `Calm mode is on here. You can write again in ${minutes} ${minutes === 1 ? 'minute' : 'minutes'}.`;
};

// ---------------------------------------------------------------------------
// Notifications per space, and the log
// ---------------------------------------------------------------------------

export const NOTIFY_MODES = ['each', 'daily', 'off'];
export const DIGEST_HOUR = 17;

export const LOG_LABELS = {
  'member.role': 'changed a role',
  'member.pause': 'paused posting',
  'member.unpause': 'ended a pause',
  'member.remove': 'removed someone',
  'member.invite': 'added people',
  'request.approve': 'let someone in',
  'request.decline': 'declined a request',
  'report.remove': 'removed reported content',
  'report.dismiss': 'dismissed a report',
  'thread.pin': 'pinned a thread',
  'thread.unpin': 'unpinned a thread',
  'thread.lock': 'locked a thread',
  'thread.unlock': 'unlocked a thread',
  'thread.remove': 'removed a thread',
  'post.remove': 'removed a reply',
  'thread.calm': 'changed calm mode',
  'chat.calm': 'changed calm mode in the chat',
  'chat.remove': 'removed a chat message',
  'card.remove': 'removed a knowledge card',
  'material.remove': 'removed a material',
  'space.update': 'changed the space settings',
  'space.archive': 'archived the space',
};

export default {
  DAYS, PARTS, SLOTS, slotLabel, StudyProfileSchema, StudyRequestSchema, scoreMatch, HELPER_AT, MENTOR_AT, helperLevel,
  isLateNight, nextMorning, ScheduleSchema, CALM_OPTIONS, calmWait, calmMessage, NOTIFY_MODES, DIGEST_HOUR, LOG_LABELS,
};
