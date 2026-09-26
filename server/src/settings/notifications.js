// classroom-app/server/src/settings/notifications.js
/**
 * Notification settings  (Settings, Phase B)
 *
 * The one definition of which notification reaches whom, where and when. Pure:
 * no database, no Redis, no env — the worker, the API and the tests call the
 * same functions, so the matrix in Settings and the delivery cannot disagree.
 *
 * Storage is notification_preferences (004 + 022). A person without a row has
 * the defaults below.
 *
 *   categories          type × channel matrix: in the app, push, email
 *   quietHours          no push in a window of the person's own time zone;
 *                       a lesson that starts now may pass
 *   focusDuringLessons  while someone is in a live lesson, private messages
 *                       and mentions are held and summarised when they leave
 *   showPreviews        push and email say who wrote, and only if on, what
 *   digest              community digest by email: off · daily · weekly
 *
 * Account and security messages (sign-in links, password resets) are not a
 * category anyone can switch off.
 */

import { z } from 'zod';

export const CATEGORIES = Object.freeze([
  'directMessages',
  'mentions',
  'channelMessages',
  'lessonReminders',
  'community',
  'coursework',
]);

export const CHANNELS = Object.freeze(['inApp', 'push', 'email']);
export const DIGESTS = Object.freeze(['off', 'daily', 'weekly']);

/** Categories that come from chat; focus mode and message previews apply to these. */
export const CHAT_CATEGORIES = new Set(['directMessages', 'mentions', 'channelMessages']);

/** A lesson that starts now is worth breaking quiet hours for, if the person allows it. */
export const TIME_CRITICAL_KINDS = new Set([
  'session.reminder.starting_soon',
  'lesson.starting',
  'session.cancelled',
]);

const flags = (inApp, push, email) => ({ inApp, push, email });

export const DEFAULT_NOTIFICATION_SETTINGS = Object.freeze({
  categories: {
    directMessages: flags(true, true, false),
    mentions: flags(true, true, false),
    // The default chatroom is everyone in the organisation: opt-in only.
    channelMessages: flags(false, false, false),
    lessonReminders: flags(true, true, true),
    community: flags(true, false, false),
    coursework: flags(true, true, true),
  },
  quietHours: { enabled: false, start: '22:00', end: '07:00', allowLessonReminders: true },
  focusDuringLessons: true,
  showPreviews: true,
  digest: 'daily',
});

const HHMM = /^([01]\d|2[0-3]):[0-5]\d$/;

/** Which category a notification kind belongs to. Unknown kinds count as community. */
export const categoryOf = (kind = '') => {
  const k = String(kind ?? '');
  if (k === 'chat.mention' || k.startsWith('chat.mention.')) return 'mentions';
  if (k.startsWith('chat.channel')) return 'channelMessages';
  if (k.startsWith('chat.')) return 'directMessages';
  if (k.startsWith('session.') || k.startsWith('lesson.')) return 'lessonReminders';
  if (/^(assignment|course|grade|asset|submission)\./.test(k)) return 'coursework';
  if (/^(security|email|password|system|account)\./.test(k)) return 'security';
  return 'community';
};

/** The worker has always said 'in-app'; the settings say 'inApp'. */
export const normalizeChannel = (channel) =>
  channel === 'in-app' || channel === 'inapp' ? 'inApp' : channel;

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

const time = z.string().regex(HHMM, 'a time such as 22:00');
const channelFlags = z.object({ inApp: z.boolean(), push: z.boolean(), email: z.boolean() });

/** A patch: any part, any subset of its keys. Unknown keys are refused. */
export const NotificationPatchSchema = z
  .object({
    categories: z
      .object(
        Object.fromEntries(CATEGORIES.map((name) => [name, channelFlags.partial().strict().optional()])),
      )
      .strict()
      .optional(),
    quietHours: z
      .object({ enabled: z.boolean(), start: time, end: time, allowLessonReminders: z.boolean() })
      .partial()
      .strict()
      .optional(),
    focusDuringLessons: z.boolean().optional(),
    showPreviews: z.boolean().optional(),
    digest: z.enum(DIGESTS).optional(),
  })
  .strict();

const clone = (value) => JSON.parse(JSON.stringify(value));

/** Stored values over defaults; anything stored that is not valid falls back. */
export const withNotificationDefaults = (stored = {}) => {
  const result = clone(DEFAULT_NOTIFICATION_SETTINGS);
  const categories = stored?.categories ?? {};
  for (const category of CATEGORIES) {
    for (const channel of CHANNELS) {
      const value = categories?.[category]?.[channel];
      if (typeof value === 'boolean') result.categories[category][channel] = value;
    }
  }

  const quiet = stored?.quietHours ?? {};
  if (typeof quiet.enabled === 'boolean') result.quietHours.enabled = quiet.enabled;
  if (typeof quiet.start === 'string' && HHMM.test(quiet.start)) result.quietHours.start = quiet.start;
  if (typeof quiet.end === 'string' && HHMM.test(quiet.end)) result.quietHours.end = quiet.end;
  if (typeof quiet.allowLessonReminders === 'boolean') {
    result.quietHours.allowLessonReminders = quiet.allowLessonReminders;
  }

  if (typeof stored?.focusDuringLessons === 'boolean') result.focusDuringLessons = stored.focusDuringLessons;
  if (typeof stored?.showPreviews === 'boolean') result.showPreviews = stored.showPreviews;
  if (DIGESTS.includes(stored?.digest)) result.digest = stored.digest;
  return result;
};

/**
 * Validates a patch and merges it into the current settings. Throws with code
 * 'validation_failed' for anything the schema refuses, and for quiet hours
 * that start and end at the same minute.
 */
export const mergeNotificationPatch = (current, patch) => {
  const parsed = NotificationPatchSchema.safeParse(patch ?? {});
  if (!parsed.success) {
    throw Object.assign(new Error('Unknown or invalid notification setting.'), { code: 'validation_failed' });
  }

  const next = withNotificationDefaults(current);
  const { categories, quietHours, ...rest } = parsed.data;

  for (const [category, values] of Object.entries(categories ?? {})) {
    if (values) next.categories[category] = { ...next.categories[category], ...values };
  }
  if (quietHours) next.quietHours = { ...next.quietHours, ...quietHours };
  for (const [key, value] of Object.entries(rest)) {
    if (value !== undefined) next[key] = value;
  }

  if (next.quietHours.start === next.quietHours.end) {
    throw Object.assign(new Error('Quiet hours need a start and an end that differ.'), {
      code: 'validation_failed',
    });
  }
  return next;
};

// ---------------------------------------------------------------------------
// Rows (notification_preferences)
// ---------------------------------------------------------------------------

const hhmm = (value) => (value ? String(value).slice(0, 5) : undefined);

/** A notification_preferences row, or null for someone who never changed anything. */
export const fromRow = (row) =>
  row
    ? withNotificationDefaults({
        categories: row.channels ?? {},
        quietHours: {
          enabled: row.quiet_enabled,
          start: hhmm(row.quiet_start),
          end: hhmm(row.quiet_end),
          allowLessonReminders: row.quiet_allow_lessons,
        },
        focusDuringLessons: row.focus_in_lessons,
        showPreviews: row.show_previews,
        digest: row.digest,
      })
    : withNotificationDefaults({});

export const toRow = (settings) => ({
  channels: settings.categories,
  quiet_enabled: settings.quietHours.enabled,
  quiet_start: settings.quietHours.start,
  quiet_end: settings.quietHours.end,
  quiet_allow_lessons: settings.quietHours.allowLessonReminders,
  focus_in_lessons: settings.focusDuringLessons,
  show_previews: settings.showPreviews,
  digest: settings.digest,
});

// ---------------------------------------------------------------------------
// Rules
// ---------------------------------------------------------------------------

/** "HH:MM" in a time zone. An unknown zone reads as UTC rather than failing. */
export const localClock = (now = new Date(), timeZone = 'UTC') => {
  const read = (zone) => {
    const parts = new Intl.DateTimeFormat('en-GB', {
      timeZone: zone,
      hour: '2-digit',
      minute: '2-digit',
      hourCycle: 'h23',
    }).formatToParts(now);
    const part = (type) => parts.find((entry) => entry.type === type)?.value ?? '00';
    return `${part('hour')}:${part('minute')}`;
  };
  try {
    return read(timeZone || 'UTC');
  } catch {
    return read('UTC');
  }
};

/** Inclusive start, exclusive end; a window may run past midnight. */
export const isWithinQuietHours = (quietHours, now = new Date(), timeZone = 'UTC') => {
  if (!quietHours?.enabled) return false;
  const { start, end } = quietHours;
  if (!HHMM.test(start ?? '') || !HHMM.test(end ?? '') || start === end) return false;
  const local = localClock(now, timeZone);
  return start < end ? local >= start && local < end : local >= start || local < end;
};

/**
 * Which channels a notification uses for one person, in this order:
 *
 *   1. account and security messages go out as requested
 *   2. the matrix: a channel switched off for this category is dropped
 *   3. focus: in a lesson, chat is held for the summary afterwards
 *   4. someone looking at the app gets no push on top
 *   5. quiet hours drop push, unless a lesson is starting and they allow it
 *
 * @param {{ kind: string, settings?: object, presence?: string,
 *           requested?: string[], now?: Date, timeZone?: string }} input
 * @returns {{ category: string, channels: string[], hold: boolean, reason: string|null }}
 */
export const decide = ({
  kind,
  settings,
  presence = 'offline',
  requested = CHANNELS,
  now = new Date(),
  timeZone = 'UTC',
}) => {
  const category = categoryOf(kind);
  const wanted = new Set(requested.map(normalizeChannel));

  if (category === 'security') {
    return { category, channels: CHANNELS.filter((c) => wanted.has(c)), hold: false, reason: 'security' };
  }

  const current = withNotificationDefaults(settings ?? {});
  const switched = current.categories[category];
  let channels = CHANNELS.filter((channel) => wanted.has(channel) && switched[channel]);
  let reason = null;

  if (channels.length === 0) return { category, channels, hold: false, reason: 'switched off' };

  if (presence === 'in-class' && CHAT_CATEGORIES.has(category) && current.focusDuringLessons) {
    return { category, channels: [], hold: true, reason: 'in a lesson' };
  }

  if ((presence === 'online' || presence === 'in-class') && channels.includes('push')) {
    channels = channels.filter((channel) => channel !== 'push');
    reason = 'looking at the app';
  }

  const lessonException = current.quietHours.allowLessonReminders && TIME_CRITICAL_KINDS.has(kind);
  if (channels.includes('push') && !lessonException && isWithinQuietHours(current.quietHours, now, timeZone)) {
    channels = channels.filter((channel) => channel !== 'push');
    reason = 'quiet hours';
  }

  return { category, channels, hold: false, reason };
};

export default {
  CATEGORIES,
  CHANNELS,
  DIGESTS,
  DEFAULT_NOTIFICATION_SETTINGS,
  NotificationPatchSchema,
  categoryOf,
  normalizeChannel,
  withNotificationDefaults,
  mergeNotificationPatch,
  fromRow,
  toRow,
  isWithinQuietHours,
  decide,
};
