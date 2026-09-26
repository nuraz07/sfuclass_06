#!/usr/bin/env bash
# phaseB-install.sh — Settings, Phase B: notifications, sign-in & devices, recent changes.
#
# Run from the project folder (the one containing server/, packages/ and apps/):
#   bash phaseB-install.sh
#
# Writes 34 files, patches 7 more, keeps a backup of every file it touches
# in .phaseB-backup/<timestamp>/, installs web-push, puts web push (VAPID) keys
# into .env, checks everything, applies migration 022 and restarts API and worker.
# Undo: bash phaseB-install.sh --restore   (back to the state before the first install;
#       the columns and the table added by 022 stay — they are unused without these files)
set -euo pipefail

if [ ! -d server/src/messaging ] || [ ! -d packages/core-client/src ] || [ ! -d apps/web/src ]; then
  echo "Run this from the project folder (the one that contains server/, packages/ and apps/)." >&2
  exit 1
fi

TOUCHED=(
  server/src/db/migrations/022_notification_settings.sql
  server/src/settings/notifications.js
  server/src/settings/fieldPaths.js
  server/src/settings/changeLog.js
  server/src/security/userAgent.js
  server/src/security/sessionActivity.js
  server/src/middleware/authenticate.js
  server/src/identity/deviceSessions.js
  server/src/notifications/config.js
  server/src/notifications/delivery.js
  server/src/notifications/webPushSubscriptions.js
  server/src/notifications/focus.js
  server/src/notifications/focusSummary.js
  server/src/realtime/liveState.js
  server/src/realtime/userEvents.js
  server/src/realtime/presenceGateway.js
  server/src/community/NotificationService.js
  server/src/queues/workers/notificationWorker.js
  server/src/queues/workers/chatFanoutWorker.js
  server/src/routes/account.routes.js
  server/test/settings/notifications.check.mjs
  packages/core-client/src/api/accountApi.ts
  apps/web/public/sw.js
  apps/web/src/lib/pushClient.js
  apps/web/src/lib/userEvents.js
  apps/web/src/pages/AppLayout.jsx
  apps/web/src/pages/SettingsPage.jsx
  apps/web/src/components/Settings/notificationsModel.js
  apps/web/src/components/Settings/NotificationSettings.jsx
  apps/web/src/components/Settings/SecuritySettings.jsx
  apps/web/src/components/Settings/ActivitySettings.jsx
  apps/web/src/components/Settings/__checks__/notificationsModel.check.mjs
  apps/web/src/components/system/NotificationToasts.jsx
  apps/web/src/components/system/notifications.css
  server/src/app.js
  server/src/identity/Profile.js
  server/src/routes/profile.routes.js
  server/src/realtime/index.js
  packages/core-client/src/index.ts
  apps/web/src/components/Settings/settingsIndex.js
  apps/web/src/components/Settings/settings.css
  server/package.json
  package.json
  package-lock.json
  .env
  server/.env
)

if [ "${1:-}" = "--restore" ]; then
  FIRST=$(ls -1d .phaseB-backup/* 2>/dev/null | head -1 || true)
  [ -n "$FIRST" ] || { echo "No backup found." >&2; exit 1; }
  for f in "${TOUCHED[@]}"; do
    if [ -f "$FIRST/$f" ]; then mkdir -p "$(dirname "$f")"; cp "$FIRST/$f" "$f"; echo "restored $f";
    elif [ -f "$f" ] && [ "$f" != "server/src/db/migrations/022_notification_settings.sql" ]; then rm "$f"; echo "removed $f (did not exist before)"; fi
  done
  touch server/src/server.js 2>/dev/null || true
  [ -f server/src/worker.js ] && touch server/src/worker.js || true
  echo "Restored from $FIRST. The migration file 022 stays, because the database already has it."
  echo "web-push stays in node_modules until the next npm install; it is unused without these files."
  exit 0
fi

# ---------------------------------------------------------------------------
# Is this the tree Phase B was written for? Nothing is changed if not.
# ---------------------------------------------------------------------------
MISSING=()
need() { # need <file> <text> <why>
  if [ ! -f "$1" ]; then MISSING+=("$1 is missing ($3)");
  elif ! grep -q -- "$2" "$1"; then MISSING+=("$1 has no '$2' ($3)"); fi
}
need server/src/settings/preferences.js "withDefaults" "Settings Phase A"
need apps/web/src/pages/SettingsPage.jsx "savePreferences" "Settings Phase A"
need apps/web/src/components/Settings/fields.jsx "export function Toggle" "Settings Phase A"
need server/src/queues/queues.js "defineWorker" "worker queues"
need server/src/queues/queues.js "PermanentJobError" "worker queues"
need server/src/queues/queues.js "QUEUE_NAMES" "worker queues"
need server/src/queues/queues.js "enqueue" "worker queues"
need server/src/queues/connection.js "utilityConnection" "worker Redis connection"
need server/src/security/auditLog.js "auditFromRequest" "change and sign-in history"
need server/src/db/redis.js "stateRedis" "live state on the state cluster"
need server/src/identity/AuthService.js "verifyAccessToken" "sign-in check"
need server/src/identity/User.js "findById" "sign-in check"
need server/src/messaging/models/Participant.js "setMuted" "muted chats"
need server/src/messaging/models/Participant.js "isParticipant" "muted chats"
need server/src/scheduling/ReminderRules.js "markSent" "lesson reminders"
need server/src/scheduling/ScheduleService.js "getSession" "lesson reminders"
need server/src/routes/_helpers.js "requireAuth" "routes"
need server/src/app.js "profileRoutes" "route mounting"
if ! ls server/src/db/migrations/*audit*.sql >/dev/null 2>&1; then MISSING+=("no audit_log migration (011_audit.sql)"); fi
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "This tree does not match what Phase B expects. Nothing was changed:" >&2
  for m in "${MISSING[@]}"; do echo "  - $m" >&2; done
  exit 1
fi

BACKUP=".phaseB-backup/$(date +%Y%m%d-%H%M%S)"
for f in "${TOUCHED[@]}"; do
  if [ -f "$f" ]; then mkdir -p "$BACKUP/$(dirname "$f")"; cp "$f" "$BACKUP/$f"; fi
done
echo "backup: $BACKUP"

mkdir -p server/src/db/migrations
cat > server/src/db/migrations/022_notification_settings.sql <<'__PB_EOF__'
-- 022_notification_settings.sql  (Settings, Phase B)
--
-- Notification settings get real storage, browsers can receive push, and the
-- account history reads quickly.
--
--   notification_preferences   exists since 004 with the type × channel matrix
--                              (channels jsonb) and quiet_start / quiet_end.
--                              Phase B adds the switches that go with them.
--   web_push_subscriptions     one row per browser that allowed push. Bound to
--                              the sign-in session that registered it, so
--                              signing that device out stops its notifications.
--   audit_log index            "Recent changes" and "Sign-in history" read one
--                              person's events by action, newest first.
--
-- Additive only.

alter table notification_preferences add column if not exists quiet_enabled       boolean not null default false;
alter table notification_preferences add column if not exists quiet_allow_lessons boolean not null default true;
alter table notification_preferences add column if not exists focus_in_lessons    boolean not null default true;
alter table notification_preferences add column if not exists show_previews       boolean not null default true;

create table if not exists web_push_subscriptions (
  id              uuid        primary key default gen_random_uuid(),
  user_id         uuid        not null references users (id) on delete cascade,
  -- The Redis sign-in session (SessionStore) that registered it. Text, not a
  -- foreign key: sessions do not live in Postgres.
  session_id      text,
  endpoint        text        not null,
  p256dh          text        not null,
  auth            text        not null,
  user_agent      text,
  failures        integer     not null default 0,
  last_success_at timestamptz,
  created_at      timestamptz not null default now(),
  constraint web_push_subscriptions_endpoint_key unique (endpoint)
);

create index if not exists web_push_subscriptions_user_idx on web_push_subscriptions (user_id);
create index if not exists web_push_subscriptions_session_idx
  on web_push_subscriptions (session_id) where session_id is not null;

create index if not exists audit_log_actor_action_idx on audit_log (actor_id, action, id desc);
__PB_EOF__
echo "wrote server/src/db/migrations/022_notification_settings.sql"

mkdir -p server/src/settings
cat > server/src/settings/notifications.js <<'__PB_EOF__'
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
__PB_EOF__
echo "wrote server/src/settings/notifications.js"

mkdir -p server/src/settings
cat > server/src/settings/fieldPaths.js <<'__PB_EOF__'
// classroom-app/server/src/settings/fieldPaths.js
/**
 * The dotted names of what a settings patch touched, for the change history:
 * { lesson: { joinCamera: 'off' } } → ['lesson.joinCamera']. Values are never
 * recorded: "Private messages changed" is history, the new value is not
 * something an audit trail needs to keep for years. Pure.
 */
export const fieldPaths = (value, prefix = '', depth = 0) => {
  if (value === undefined) return [];
  if (value === null || typeof value !== 'object' || Array.isArray(value) || depth >= 3) {
    return prefix ? [prefix] : [];
  }
  return Object.entries(value).flatMap(([key, entry]) =>
    fieldPaths(entry, prefix ? `${prefix}.${key}` : key, depth + 1),
  );
};

export default fieldPaths;
__PB_EOF__
echo "wrote server/src/settings/fieldPaths.js"

mkdir -p server/src/settings
cat > server/src/settings/changeLog.js <<'__PB_EOF__'
// classroom-app/server/src/settings/changeLog.js
/**
 * Every settings change, recorded and announced  (Settings, Phase B)
 *
 * One call after a successful change does two things:
 *
 *   audit   'settings.changed' in audit_log with the section and the names of
 *           the fields (never the values), the device and the IP. Settings →
 *           Recent changes reads it, so someone can see a change they did not
 *           make and sign that device out.
 *
 *   live    'settings:changed' to every other tab and device of the person, so
 *           a change on the laptop shows on the phone without a reload.
 *
 * Neither may fail the change that already happened.
 */

import { auditFromRequest } from '../security/auditLog.js';
import { pushToUser } from '../realtime/userEvents.js';
import { logger } from '../observability/logger.js';
import { fieldPaths } from './fieldPaths.js';

const log = logger.child({ component: 'settings-change-log' });

export const SETTINGS_CHANGED = 'settings.changed';

export const recordChange = async (req, section, patch, { action = SETTINGS_CHANGED, metadata = {} } = {}) => {
  const userId = req.user?.id;
  if (!userId) return;
  const fields = fieldPaths(patch ?? {});
  if (fields.length === 0 && action === SETTINGS_CHANGED) return;

  try {
    await auditFromRequest(req, {
      action,
      targetType: 'user',
      targetId: userId,
      metadata: { section, fields, ...metadata },
    });
  } catch (cause) {
    log.warn({ err: cause, section }, 'settings change not audited');
  }

  await pushToUser(userId, 'settings:changed', { section, fields });
};

export default recordChange;
__PB_EOF__
echo "wrote server/src/settings/changeLog.js"

mkdir -p server/src/security
cat > server/src/security/userAgent.js <<'__PB_EOF__'
// classroom-app/server/src/security/userAgent.js
/**
 * "Chrome on Windows" from a User-Agent string, for the device list and the
 * sign-in history. Deliberately coarse: a version number helps nobody decide
 * whether a sign-in was theirs, and a precise fingerprint is not something to
 * show back. Pure.
 */

const BROWSERS = [
  [/EdgA?\/|EdgiOS\//, 'Edge'],
  [/OPR\/|Opera/, 'Opera'],
  [/SamsungBrowser/, 'Samsung Internet'],
  [/FxiOS|Firefox\//, 'Firefox'],
  [/CriOS|Chrome\//, 'Chrome'],
  [/Version\/[\d.]+.*Safari\//, 'Safari'],
];

const SYSTEMS = [
  [/iPhone/, 'iPhone'],
  [/iPad/, 'iPad'],
  [/Android/, 'Android'],
  [/Windows/, 'Windows'],
  [/CrOS/, 'ChromeOS'],
  [/Mac OS X|Macintosh/, 'macOS'],
  [/Linux/, 'Linux'],
];

export const describeUserAgent = (userAgent = '', platform = null) => {
  if (platform === 'ios') return 'Classroom app on iPhone or iPad';
  if (platform === 'android') return 'Classroom app on Android';

  const ua = String(userAgent ?? '');
  if (!ua.trim()) return 'Unknown device';

  const browser = BROWSERS.find(([pattern]) => pattern.test(ua))?.[1] ?? null;
  const system = SYSTEMS.find(([pattern]) => pattern.test(ua))?.[1] ?? null;

  if (browser && system) return `${browser} on ${system}`;
  if (browser) return browser;
  if (system) return `A browser on ${system}`;
  return 'Unknown device';
};

export default describeUserAgent;
__PB_EOF__
echo "wrote server/src/security/userAgent.js"

mkdir -p server/src/security
cat > server/src/security/sessionActivity.js <<'__PB_EOF__'
// classroom-app/server/src/security/sessionActivity.js
/**
 * What each sign-in session is doing  (Settings, Phase B)
 *
 * Kept next to the sessions in SessionStore rather than inside them, so the
 * session format itself does not change:
 *
 *   device-session:{<id>}:revoked   signed out from another device. Checked on
 *                                   every request (middleware/authenticate.js):
 *                                   its access token stops working at once
 *                                   instead of when it expires.
 *   device-session:{<id>}:seen      browser, IP, first and last activity. The
 *                                   device list reads it; the first request of
 *                                   a session is its sign-in, recorded for the
 *                                   sign-in history.
 *   device-session:{<id>}:touch     at most one write per minute per session
 *
 * Failed sign-in attempts are recorded when POST /auth/login answers 401 or
 * 429, against the account whose address was typed in, so its owner sees
 * them.
 *
 * Every Redis failure is fail-open: an outage must not sign everyone out.
 */

import { stateRedis as redis } from '../db/redis.js';
import { pool } from '../db/pool.js';
import { logger } from '../observability/logger.js';

const log = logger.child({ component: 'session-activity' });

const KEEP_SEC = 31 * 24 * 3_600;
const TOUCH_SEC = 60;

const keys = {
  revoked: (sessionId) => `device-session:{${sessionId}}:revoked`,
  seen: (sessionId) => `device-session:{${sessionId}}:seen`,
  touch: (sessionId) => `device-session:{${sessionId}}:touch`,
};

export const SIGN_IN_SUCCEEDED = 'auth.login.succeeded';
export const SIGN_IN_FAILED = 'auth.login.failed';

const audit = async (req, event) => {
  try {
    const { auditFromRequest } = await import('./auditLog.js');
    await auditFromRequest(req, event);
  } catch (cause) {
    log.warn({ err: cause, action: event.action }, 'sign-in not recorded');
  }
};

const userAgentOf = (req) => String(req.get?.('user-agent') ?? '').slice(0, 300) || null;

// ---------------------------------------------------------------------------
// Revocation
// ---------------------------------------------------------------------------

export const markRevoked = async (sessionId) => {
  await redis.set(keys.revoked(sessionId), '1', 'EX', KEEP_SEC);
};

export const isRevoked = async (sessionId) => {
  if (!sessionId) return false;
  try {
    return (await redis.exists(keys.revoked(sessionId))) === 1;
  } catch (cause) {
    log.error({ err: cause }, 'session revocation check unavailable; allowing the request');
    return false;
  }
};

// ---------------------------------------------------------------------------
// Activity
// ---------------------------------------------------------------------------

/**
 * After a request authenticated: remembers browser, IP and time for its
 * session, at most once a minute, and records the sign-in the first time a
 * session is seen. Never awaited by the request.
 */
export const touch = async (req) => {
  const sessionId = req.user?.sessionId;
  if (!sessionId) return;
  try {
    const fresh = (await redis.set(keys.touch(sessionId), '1', 'EX', TOUCH_SEC, 'NX')) === 'OK';
    if (!fresh) return;

    const now = new Date().toISOString();
    const results = await redis
      .multi()
      .hsetnx(keys.seen(sessionId), 'firstSeenAt', now)
      .hset(keys.seen(sessionId), 'lastSeenAt', now, 'ip', String(req.ip ?? ''), 'userAgent', userAgentOf(req) ?? '')
      .expire(keys.seen(sessionId), KEEP_SEC)
      .exec();

    if (results?.[0]?.[1] === 1) {
      await audit(req, {
        action: SIGN_IN_SUCCEEDED,
        targetType: 'user',
        targetId: req.user.id,
        metadata: { platform: req.get?.('x-client-platform') ?? 'web' },
      });
    }
  } catch (cause) {
    log.debug({ err: cause }, 'session activity not written');
  }
};

/** Browser, IP and activity per session id; missing ones are left out. */
export const seenFor = async (sessionIds) => {
  const result = new Map();
  await Promise.all(
    sessionIds.map(async (sessionId) => {
      try {
        const [seen, revoked] = await Promise.all([
          redis.hgetall(keys.seen(sessionId)),
          redis.exists(keys.revoked(sessionId)),
        ]);
        result.set(sessionId, { ...(seen ?? {}), revoked: revoked === 1 });
      } catch {
        // Listed without the extra detail.
      }
    }),
  );
  return result;
};

// ---------------------------------------------------------------------------
// Failed sign-ins
// ---------------------------------------------------------------------------

const LOGIN_PATH = /\/auth\/login\/?$/;

/**
 * Watches POST /auth/login. A rejected attempt for an address that belongs to
 * an account is recorded on that account; attempts for unknown addresses are
 * not recorded anywhere a person could read them.
 */
export const observeSignInAttempt = (req, res) => {
  if (req.method !== 'POST' || !LOGIN_PATH.test(req.path ?? '')) return;
  res.on('finish', () => {
    if (res.statusCode !== 401 && res.statusCode !== 429) return;
    const email = typeof req.body?.email === 'string' ? req.body.email.trim() : '';
    if (!email) return;
    void (async () => {
      try {
        const { rows } = await pool.query(
          `SELECT id, tenant_id, role FROM users WHERE lower(email) = lower($1) AND deleted_at IS NULL LIMIT 1`,
          [email],
        );
        const account = rows[0];
        if (!account) return;
        const asAccount = Object.create(req);
        asAccount.user = { id: account.id, userId: account.id, tenantId: account.tenant_id, role: account.role };
        await audit(asAccount, {
          action: SIGN_IN_FAILED,
          targetType: 'user',
          targetId: account.id,
          metadata: { reason: res.statusCode === 429 ? 'too-many-attempts' : 'wrong-password' },
        });
      } catch (cause) {
        log.debug({ err: cause }, 'failed sign-in not recorded');
      }
    })();
  });
};

export default { markRevoked, isRevoked, touch, seenFor, observeSignInAttempt, SIGN_IN_SUCCEEDED, SIGN_IN_FAILED };
__PB_EOF__
echo "wrote server/src/security/sessionActivity.js"

mkdir -p server/src/middleware
cat > server/src/middleware/authenticate.js <<'__PB_EOF__'
import { ApiError } from '@classroom/contracts';
import { verifyAccessToken } from '../identity/AuthService.js';
import * as Users from '../identity/User.js';
import * as SessionActivity from '../security/sessionActivity.js';

/**
 * Who is asking  (F5 · Settings Phase B)
 *
 * Verifies the bearer token and puts the account on req.user. Phase B adds
 * three things around it (security/sessionActivity.js):
 *
 *   - a session signed out from another device is refused at once, with the
 *     same token_revoked answer as any other revoked token
 *   - browser, IP and last activity of the session are kept for the device
 *     list, and the first request of a session is recorded as its sign-in
 *   - a rejected POST /auth/login is recorded on the account it tried
 */

const bearerToken = (req) => {
  const value = req.get('authorization');
  if (!value) return null;
  if (!value.startsWith('Bearer ')) {
    throw new ApiError('unauthenticated', { detail: 'Invalid authorization header.' });
  }
  const token = value.slice(7).trim();
  if (!token) throw new ApiError('unauthenticated', { detail: 'No access token presented.' });
  return token;
};

export const authenticate = () => async (req, res, next) => {
  SessionActivity.observeSignInAttempt(req, res);
  try {
    const token = bearerToken(req);
    if (!token) return next();

    const claims = await verifyAccessToken(token);

    if (await SessionActivity.isRevoked(claims.sessionId)) {
      // Same answer as an expired token: the client tries to refresh, the
      // refresh is refused (the session is revoked) and it signs out.
      return next(new ApiError('unauthenticated', { detail: 'This device was signed out.' }));
    }

    const user = await Users.findById(claims.userId);

    if (!user || user.status !== 'active') {
      return next(new ApiError('unauthenticated', { detail: 'Sign in to continue.' }));
    }

    req.user = {
      ...user,
      id: user.userId,
      sessionId: claims.sessionId,
      jti: claims.jti,
      issuedAt: claims.issuedAt,
      expiresAt: claims.expiresAt,
    };

    void SessionActivity.touch(req);
    return next();
  } catch (error) {
    return next(error);
  }
};

export default authenticate;
__PB_EOF__
echo "wrote server/src/middleware/authenticate.js"

mkdir -p server/src/identity
cat > server/src/identity/deviceSessions.js <<'__PB_EOF__'
// classroom-app/server/src/identity/deviceSessions.js
/**
 * Signed-in devices  (Settings, Phase B)
 *
 * The sign-in sessions of one person, as Settings → Sign-in & devices shows
 * them, and signing them out from another device.
 *
 * Sessions live in SessionStore (Redis). This module does not change their
 * format; it reads them with listSessions, adds what security/sessionActivity
 * saw (browser, IP, last activity) and, to sign one out:
 *
 *   1. marks it revoked, so its access token is refused on the next request
 *   2. revokes it in SessionStore, so its refresh token is refused
 *   3. removes the browser push registrations it made
 *   4. tells its open tabs (session:revoked), which sign themselves out
 */

import * as Sessions from './SessionStore.js';
import * as Activity from '../security/sessionActivity.js';
import * as Subscriptions from '../notifications/webPushSubscriptions.js';
import { publishSessionRevoked } from '../realtime/userEvents.js';
import { describeUserAgent } from '../security/userAgent.js';
import { logger } from '../observability/logger.js';

const log = logger.child({ component: 'device-sessions' });

const iso = (value) => {
  if (!value) return null;
  const date = new Date(typeof value === 'number' && value < 1e12 ? value * 1000 : value);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
};

/** SessionStore's records, whatever shape listSessions returns them in; null when unknown. */
const readSessions = async (userId) => {
  if (typeof Sessions.listSessions !== 'function') return null;
  const asList = (raw) => (Array.isArray(raw) ? raw : Array.isArray(raw?.items) ? raw.items : null);
  let list;
  try {
    list = asList(await Sessions.listSessions(userId));
    // Some versions take an options object instead of the id.
    if (!list || list.length === 0) list = asList(await Promise.resolve().then(() => Sessions.listSessions({ userId })).catch(() => null)) ?? list;
  } catch (cause) {
    log.warn({ err: cause }, 'sessions could not be listed');
    return null;
  }
  if (!list) return null;
  return list
    .map((session) => ({
      sessionId: session.sessionId ?? session.id ?? null,
      userId: session.userId ?? userId,
      device: session.device ?? {},
      createdAt: iso(session.createdAt ?? session.created_at),
      lastUsedAt: iso(session.lastUsedAt ?? session.last_used_at ?? session.updatedAt),
    }))
    .filter((session) => session.sessionId && (!session.userId || session.userId === userId));
};

/**
 * @returns {Promise<Array<{ sessionId, label, platform, ip, createdAt, lastActiveAt }>>}
 */
export const list = async (userId) => {
  const sessions = (await readSessions(userId)) ?? [];
  const seen = await Activity.seenFor(sessions.map((session) => session.sessionId));

  return sessions
    .filter((session) => !seen.get(session.sessionId)?.revoked)
    .map((session) => {
      const activity = seen.get(session.sessionId) ?? {};
      const userAgent = activity.userAgent || session.device.userAgent || '';
      const lastActiveAt = [activity.lastSeenAt, session.lastUsedAt]
        .filter(Boolean)
        .sort()
        .at(-1) ?? session.createdAt;
      return {
        sessionId: session.sessionId,
        label: describeUserAgent(userAgent, session.device.platform),
        platform: session.device.platform ?? null,
        ip: activity.ip || session.device.ip || null,
        createdAt: session.createdAt ?? activity.firstSeenAt ?? null,
        lastActiveAt: lastActiveAt ?? null,
      };
    })
    .sort((a, b) => String(b.lastActiveAt ?? '').localeCompare(String(a.lastActiveAt ?? '')));
};

/** Ids of the sessions still signed in, or null when SessionStore cannot say. */
export const liveSessionIds = async (userId) => {
  const sessions = await readSessions(userId);
  if (!sessions) return null;
  const seen = await Activity.seenFor(sessions.map((session) => session.sessionId));
  return new Set(sessions.filter((s) => !seen.get(s.sessionId)?.revoked).map((s) => s.sessionId));
};

/**
 * Signs one of this person's sessions out.
 * @returns {Promise<null | { sessionId: string, label: string }>} null when it is not theirs
 */
export const revoke = async ({ userId, sessionId, reason = 'signed-out-remotely' }) => {
  const own = (await list(userId)).find((session) => session.sessionId === sessionId);
  if (!own) return null;

  await Activity.markRevoked(sessionId);
  try {
    await Sessions.revokeSession({ sessionId, reason });
  } catch (cause) {
    // The mark above already refuses its tokens; the refresh token expires on its own.
    log.warn({ err: cause, sessionId }, 'session store did not revoke the session');
  }
  await Subscriptions.removeForSession({ userId, sessionId }).catch(() => undefined);
  await publishSessionRevoked({ userId, sessionId, reason });

  log.info({ userId, reason }, 'session signed out from another device');
  return { sessionId, label: own.label };
};

/** Every session except the one asking. */
export const revokeOthers = async ({ userId, currentSessionId }) => {
  const others = (await list(userId)).filter((session) => session.sessionId !== currentSessionId);
  let revoked = 0;
  for (const session of others) {
    if (await revoke({ userId, sessionId: session.sessionId, reason: 'signed-out-everywhere-else' })) revoked += 1;
  }
  return { revoked };
};

export default { list, liveSessionIds, revoke, revokeOthers };
__PB_EOF__
echo "wrote server/src/identity/deviceSessions.js"

mkdir -p server/src/notifications
cat > server/src/notifications/config.js <<'__PB_EOF__'
// classroom-app/server/src/notifications/config.js
/**
 * Delivery settings, read in one place  (Settings, Phase B)
 *
 * The API sends test notifications itself and the worker sends the rest, so
 * both need the mail and web-push settings. env.js hands some of them to the
 * worker role only, and the web-push keys are new; this reads each value from
 * the validated env first and falls back to the process environment (filled
 * from .env by `node --env-file`), then to a development default.
 *
 * For production, add WEB_PUSH_PUBLIC_KEY, WEB_PUSH_PRIVATE_KEY (secret) and
 * WEB_PUSH_SUBJECT to the api and worker roles in config/env.js.
 */

import { env } from '../config/env.js';

const read = (name, fallback = undefined) => {
  let value;
  try {
    value = env?.[name];
  } catch {
    value = undefined;
  }
  if (value === undefined || value === null || value === '') value = process.env[name];
  return value === undefined || value === null || value === '' ? fallback : value;
};

export const deliveryConfig = () => ({
  appUrl: String(read('APP_URL', 'http://localhost:5173')).replace(/\/$/, ''),
  mailTransport: read('MAIL_TRANSPORT', 'smtp'),
  smtpHost: read('SMTP_HOST', 'localhost'),
  smtpPort: Number(read('SMTP_PORT', 1025)),
  mailFrom: read('SES_FROM', 'noreply@classroom.local'),
  sesRegion: read('SES_REGION', read('AWS_REGION', 'eu-central-1')),
  webPushPublicKey: read('WEB_PUSH_PUBLIC_KEY', ''),
  webPushPrivateKey: read('WEB_PUSH_PRIVATE_KEY', ''),
  webPushSubject: read('WEB_PUSH_SUBJECT', 'mailto:admin@classroom.local'),
});

export default deliveryConfig;
__PB_EOF__
echo "wrote server/src/notifications/config.js"

mkdir -p server/src/notifications
cat > server/src/notifications/delivery.js <<'__PB_EOF__'
// classroom-app/server/src/notifications/delivery.js
/**
 * Delivery channels  (Settings, Phase B)
 *
 * How a notification physically leaves the platform, once the rules
 * (settings/notifications.js) have decided that it should:
 *
 *   push    Web Push to every browser the person allowed it in (VAPID keys
 *           WEB_PUSH_*), only while the sign-in session that registered the
 *           browser is still active
 *   email   SMTP (Mailpit in development) or SES, by MAIL_TRANSPORT
 *
 * Used by the notification worker for real notifications and by the API for
 * "Send test notification", so a successful test proves the same path.
 *
 * Push never throws: one dead browser must not stop delivery to the others,
 * and a retried job would notify everyone twice. Email throws, so a caller can
 * decide whether a retry is worth it.
 */

import { deliveryConfig } from './config.js';
import { logger } from '../observability/logger.js';
import * as Subscriptions from './webPushSubscriptions.js';

const log = logger.child({ component: 'delivery' });

const truncate = (text, max) => {
  const value = String(text ?? '');
  if (value.length <= max) return value;
  const cut = value.slice(0, max - 1);
  const space = cut.lastIndexOf(' ');
  return `${space > max * 0.6 ? cut.slice(0, space) : cut}…`;
};

export const absoluteUrl = (url) => {
  const { appUrl } = deliveryConfig();
  if (!url) return appUrl;
  if (/^https?:\/\//i.test(url)) return url;
  return `${appUrl}${url.startsWith('/') ? url : `/${url}`}`;
};

// ---------------------------------------------------------------------------
// Push
// ---------------------------------------------------------------------------

export const webPushConfigured = () => {
  const config = deliveryConfig();
  return Boolean(config.webPushPublicKey && config.webPushPrivateKey);
};

export const webPushPublicKey = () => (webPushConfigured() ? deliveryConfig().webPushPublicKey : null);

let webPushModule = null;
const getWebPush = async () => {
  if (!webPushModule) {
    const imported = await import('web-push');
    webPushModule = imported.default ?? imported;
  }
  return webPushModule;
};

const HIGH_URGENCY = /^(chat\.|session\.reminder\.starting_soon|lesson\.starting|security\.|system\.test)/;

const sendWebPush = async ({ userId, title, body, url, kind, tag }) => {
  const result = { delivered: 0, failed: 0, targets: 0 };
  if (!webPushConfigured()) return result;

  // A browser whose sign-in session ended (signed out, expired, signed out
  // from another device) must not keep receiving this person's notifications.
  const { liveSessionIds } = await import('../identity/deviceSessions.js');
  const live = await liveSessionIds(userId).catch(() => null);
  const subscriptions = [];
  for (const subscription of await Subscriptions.listForUser(userId)) {
    // An empty answer is treated as "unknown" rather than "signed out everywhere":
    // pruning on a wrong empty list would silently switch push off for good.
    if (live && live.size > 0 && subscription.session_id && !live.has(subscription.session_id)) {
      await Subscriptions.removeById(subscription.id).catch(() => undefined);
    } else {
      subscriptions.push(subscription);
    }
  }
  result.targets = subscriptions.length;
  if (subscriptions.length === 0) return result;

  const webpush = await getWebPush();
  const payload = JSON.stringify({
    title: truncate(title, 80) || 'Classroom',
    body: truncate(body ?? '', 180),
    url: url ?? '/',
    tag: tag ?? kind ?? null,
    kind: kind ?? null,
  });
  const config = deliveryConfig();
  const options = {
    vapidDetails: {
      subject: config.webPushSubject,
      publicKey: config.webPushPublicKey,
      privateKey: config.webPushPrivateKey,
    },
    TTL: 24 * 3_600,
    urgency: HIGH_URGENCY.test(kind ?? '') ? 'high' : 'normal',
  };

  await Promise.all(
    subscriptions.map(async (subscription) => {
      try {
        await webpush.sendNotification(
          { endpoint: subscription.endpoint, keys: { p256dh: subscription.p256dh, auth: subscription.auth } },
          payload,
          options,
        );
        result.delivered += 1;
        await Subscriptions.recordSuccess(subscription.id).catch(() => undefined);
      } catch (cause) {
        result.failed += 1;
        // 404 and 410: the browser dropped the subscription (site data cleared,
        // permission revoked). It will never work again.
        if (cause?.statusCode === 404 || cause?.statusCode === 410) {
          await Subscriptions.removeById(subscription.id).catch(() => undefined);
        } else {
          await Subscriptions.recordFailure(subscription.id).catch(() => undefined);
        }
        log.warn({ userId, statusCode: cause?.statusCode ?? null, message: cause?.message }, 'web push failed');
      }
    }),
  );

  return result;
};

/**
 * @returns {Promise<{ delivered: number, failed: number, targets: number }>}
 */
export const sendPush = async (input) => {
  try {
    return await sendWebPush(input);
  } catch (cause) {
    log.warn({ err: cause, userId: input.userId }, 'web push unavailable');
    return { delivered: 0, failed: 0, targets: 0 };
  }
};

// ---------------------------------------------------------------------------
// Email
// ---------------------------------------------------------------------------

const escapeHtml = (value) =>
  String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

/**
 * Subject, HTML and text for one notification. Plain on purpose: it has to
 * read the same in every mail client, including the ones that block images.
 */
export const renderEmail = ({ title, body = null, url = null, recipientName = null, actionLabel = 'Open in Classroom', footer = null }) => {
  const link = absoluteUrl(url);
  const settingsLink = absoluteUrl('/settings/notifications');
  const greeting = recipientName ? `Hi ${recipientName},` : 'Hi,';
  const note = footer ?? `You get this email because of your notification settings: ${settingsLink}`;

  const text = [greeting, '', title, body ? `\n${body}` : '', '', `${actionLabel}: ${link}`, '', '—', note]
    .filter((line) => line !== null)
    .join('\n');

  const html = `<!doctype html>
<html><body style="margin:0;padding:24px;background:#f4f5f7;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;color:#1f2933">
  <div style="max-width:520px;margin:0 auto;background:#ffffff;border-radius:12px;padding:28px">
    <p style="margin:0 0 16px">${escapeHtml(greeting)}</p>
    <p style="margin:0 0 8px;font-size:18px;font-weight:700">${escapeHtml(title)}</p>
    ${body ? `<p style="margin:0 0 20px;line-height:1.5;white-space:pre-wrap">${escapeHtml(body)}</p>` : ''}
    <p style="margin:0 0 24px"><a href="${escapeHtml(link)}" style="display:inline-block;padding:10px 18px;border-radius:8px;background:#2563eb;color:#ffffff;text-decoration:none;font-weight:600">${escapeHtml(actionLabel)}</a></p>
    <p style="margin:0;font-size:12px;color:#6b7280">${escapeHtml(note)}</p>
  </div>
</body></html>`;

  return { subject: truncate(title, 120), html, text };
};

let smtpTransport = null;
const getSmtp = async () => {
  if (!smtpTransport) {
    const imported = await import('nodemailer');
    const nodemailer = imported.default ?? imported;
    const config = deliveryConfig();
    smtpTransport = nodemailer.createTransport({
      host: config.smtpHost,
      port: config.smtpPort,
      secure: false,
      connectionTimeout: 10_000,
    });
  }
  return smtpTransport;
};

let sesClient = null;
const getSes = async () => {
  if (!sesClient) {
    const { SESv2Client } = await import('@aws-sdk/client-sesv2');
    sesClient = new SESv2Client({ region: deliveryConfig().sesRegion });
  }
  return sesClient;
};

/**
 * @param {{ to: string, subject: string, html: string, text: string, kind?: string }} message
 * @returns {Promise<{ delivered: number, transport: string }>}
 */
export const sendEmail = async ({ to, subject, html, text, kind = 'notification' }) => {
  if (!to) return { delivered: 0, transport: null };
  const config = deliveryConfig();
  const from = config.mailFrom;

  if (config.mailTransport === 'ses') {
    const { SendEmailCommand } = await import('@aws-sdk/client-sesv2');
    const ses = await getSes();
    await ses.send(
      new SendEmailCommand({
        FromEmailAddress: from,
        Destination: { ToAddresses: [to] },
        Content: { Simple: { Subject: { Data: subject }, Body: { Html: { Data: html }, Text: { Data: text } } } },
        EmailTags: [{ Name: 'kind', Value: String(kind).replace(/[^\w-]/g, '_') }],
      }),
    );
    return { delivered: 1, transport: 'ses' };
  }

  const smtp = await getSmtp();
  await smtp.sendMail({ from, to, subject, html, text, headers: { 'X-Classroom-Kind': String(kind) } });
  return { delivered: 1, transport: 'smtp' };
};

export default { webPushConfigured, webPushPublicKey, sendPush, sendEmail, renderEmail, absoluteUrl };
__PB_EOF__
echo "wrote server/src/notifications/delivery.js"

mkdir -p server/src/notifications
cat > server/src/notifications/webPushSubscriptions.js <<'__PB_EOF__'
// classroom-app/server/src/notifications/webPushSubscriptions.js
/**
 * Browsers that receive push  (Settings, Phase B)
 *
 * One row per browser. The endpoint is unique: the same browser registering
 * again after a change of account moves to the new account instead of
 * delivering one person's messages to another.
 *
 * A subscription belongs to the sign-in session that created it. Signing that
 * device out — here, or from another device in Settings — removes it.
 */

import { pool } from '../db/pool.js';

export const listForUser = async (userId) => {
  const { rows } = await pool.query(
    `SELECT id, endpoint, p256dh, auth, session_id, user_agent, created_at, last_success_at
       FROM web_push_subscriptions WHERE user_id = $1 ORDER BY created_at DESC`,
    [userId],
  );
  return rows;
};

export const countForUser = async (userId) => {
  const { rows } = await pool.query(
    `SELECT count(*)::int AS n FROM web_push_subscriptions WHERE user_id = $1`,
    [userId],
  );
  return rows[0]?.n ?? 0;
};

export const upsert = async ({ userId, sessionId = null, endpoint, p256dh, auth, userAgent = null }) => {
  await pool.query(
    `INSERT INTO web_push_subscriptions (user_id, session_id, endpoint, p256dh, auth, user_agent)
     VALUES ($1, $2, $3, $4, $5, $6)
     ON CONFLICT (endpoint) DO UPDATE
        SET user_id = EXCLUDED.user_id,
            session_id = EXCLUDED.session_id,
            p256dh = EXCLUDED.p256dh,
            auth = EXCLUDED.auth,
            user_agent = EXCLUDED.user_agent,
            failures = 0`,
    [userId, sessionId, endpoint, p256dh, auth, userAgent ? String(userAgent).slice(0, 300) : null],
  );
};

export const removeByEndpoint = async ({ userId, endpoint }) => {
  const { rowCount } = await pool.query(
    `DELETE FROM web_push_subscriptions WHERE user_id = $1 AND endpoint = $2`,
    [userId, endpoint],
  );
  return rowCount;
};

export const removeForSession = async ({ userId, sessionId }) => {
  if (!sessionId) return 0;
  const { rowCount } = await pool.query(
    `DELETE FROM web_push_subscriptions WHERE user_id = $1 AND session_id = $2`,
    [userId, sessionId],
  );
  return rowCount;
};

export const removeForUser = async (userId) => {
  const { rowCount } = await pool.query(`DELETE FROM web_push_subscriptions WHERE user_id = $1`, [userId]);
  return rowCount;
};

export const removeById = async (id) => {
  await pool.query(`DELETE FROM web_push_subscriptions WHERE id = $1`, [id]);
};

export const recordSuccess = async (id) => {
  await pool.query(
    `UPDATE web_push_subscriptions SET failures = 0, last_success_at = now() WHERE id = $1`,
    [id],
  );
};

/** Five failures in a row and a subscription is dead weight. */
export const recordFailure = async (id) => {
  const { rows } = await pool.query(
    `UPDATE web_push_subscriptions SET failures = failures + 1 WHERE id = $1 RETURNING failures`,
    [id],
  );
  if ((rows[0]?.failures ?? 0) >= 5) await removeById(id);
};

export default {
  listForUser,
  countForUser,
  upsert,
  removeByEndpoint,
  removeForSession,
  removeForUser,
  removeById,
  recordSuccess,
  recordFailure,
};
__PB_EOF__
echo "wrote server/src/notifications/webPushSubscriptions.js"

mkdir -p server/src/notifications
cat > server/src/notifications/focus.js <<'__PB_EOF__'
// classroom-app/server/src/notifications/focus.js
/**
 * Focus during lessons  (Settings, Phase B)
 *
 * While someone is in a live lesson, private messages and mentions from
 * outside it do not notify them. They are held here and, once the person has
 * left the lesson, delivered as one summary ("While you were in your lesson:
 * 4 new messages from Anna and Ben").
 *
 * State, on the state cluster, all with a TTL:
 *
 *   focus:{<user>}:held        the held items, newest last, capped at 200
 *   focus:{<user>}:scheduled   a summary check is already queued
 *
 * Whether someone is in a lesson is realtime/liveState.js, written by the
 * presence gateway. The summary is a queued job (notification.focus.flush)
 * rather than a timer, so it survives a restart and runs in the worker like
 * every other notification.
 */

import { stateRedis as redis } from '../db/redis.js';
import { logger } from '../observability/logger.js';
import * as LiveState from '../realtime/liveState.js';

export { summarizeHeld } from './focusSummary.js';

const log = logger.child({ component: 'focus' });

const HELD_TTL_SEC = 24 * 3_600;
const MAX_HELD = 200;
/** How often a waiting summary looks again while the lesson is still running. */
const RECHECK_MS = 60_000;
/** After leaving: long enough for a network blip to reconnect, short enough to feel immediate. */
const AFTER_LEAVE_MS = 5_000;

const keys = {
  held: (userId) => `focus:{${userId}}:held`,
  scheduled: (userId) => `focus:{${userId}}:scheduled`,
};

export const isInLesson = async (userId) => {
  try {
    return await LiveState.isInLesson(userId);
  } catch {
    return false;
  }
};

/**
 * Queues a summary check. At most one waits per person unless `force`, which
 * a departure uses to jump ahead of a check that is still a minute out.
 */
export const scheduleFlush = async (userId, { delayMs = RECHECK_MS, force = false } = {}) => {
  const ttl = delayMs + 30_000;
  const fresh = (await redis.set(keys.scheduled(userId), '1', 'PX', ttl, 'NX')) === 'OK';
  if (!fresh && !force) return false;
  if (!fresh) await redis.set(keys.scheduled(userId), '1', 'PX', ttl);

  const { enqueue, QUEUE_NAMES } = await import('../queues/queues.js');
  await enqueue(
    QUEUE_NAMES.NOTIFY,
    'notification.focus.flush',
    { userId },
    // Unique per attempt: BullMQ keeps completed job ids for a while and would
    // silently drop a second job with the same id.
    { jobId: `focus-flush.${userId}.${Date.now()}`, delay: delayMs },
  );
  return true;
};

export const clearSchedule = (userId) => redis.del(keys.scheduled(userId));

/** Called by the presence gateway when someone's last lesson connection closes. */
export const leftLesson = async (userId) => {
  if ((await redis.llen(keys.held(userId))) > 0) {
    await scheduleFlush(userId, { delayMs: AFTER_LEAVE_MS, force: true });
  }
};

/** Holds one item and makes sure a summary will follow. */
export const hold = async (userId, item) => {
  const entry = JSON.stringify({ ...item, at: item.at ?? new Date().toISOString() });
  await redis
    .multi()
    .rpush(keys.held(userId), entry)
    .ltrim(keys.held(userId), -MAX_HELD, -1)
    .expire(keys.held(userId), HELD_TTL_SEC)
    .exec();
  await scheduleFlush(userId).catch((cause) => log.warn({ err: cause, userId }, 'focus summary not scheduled'));
};

/** Everything held, removed in the same step, so two checks cannot both send it. */
export const takeHeld = async (userId) => {
  const results = await redis.multi().lrange(keys.held(userId), 0, -1).del(keys.held(userId)).exec();
  const raw = results?.[0]?.[1] ?? [];
  return raw
    .map((entry) => {
      try {
        return JSON.parse(entry);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
};

export default { isInLesson, leftLesson, hold, takeHeld, scheduleFlush, clearSchedule };
__PB_EOF__
echo "wrote server/src/notifications/focus.js"

mkdir -p server/src/notifications
cat > server/src/notifications/focusSummary.js <<'__PB_EOF__'
// classroom-app/server/src/notifications/focusSummary.js
/**
 * The summary someone gets after a lesson, from what was held back while they
 * were in it. Pure, so the wording is tested rather than discovered.
 *
 * Held items: { type: 'message' | 'mention', from, conversationId?, channelId? }
 */

const plural = (count, one, many) => `${count} ${count === 1 ? one : many}`;

const names = (list) => {
  if (list.length === 0) return '';
  if (list.length === 1) return list[0];
  if (list.length === 2) return `${list[0]} and ${list[1]}`;
  return `${list[0]}, ${list[1]} and ${plural(list.length - 2, 'other', 'others')}`;
};

export const summarizeHeld = (items = []) => {
  const valid = items.filter((item) => item && (item.type === 'message' || item.type === 'mention'));
  if (valid.length === 0) return null;

  const messages = valid.filter((item) => item.type === 'message');
  const mentions = valid.filter((item) => item.type === 'mention');
  const chats = new Set(valid.map((item) => item.conversationId ?? `channel:${item.channelId ?? ''}`));
  const senders = [...new Set(valid.map((item) => item.from).filter(Boolean))];
  const from = senders.length ? ` from ${names(senders)}` : '';

  const parts = [];
  if (messages.length > 0) {
    const where = chats.size > 1 ? ` in ${plural(chats.size, 'chat', 'chats')}` : '';
    parts.push(`${plural(messages.length, 'new message', 'new messages')}${where}${from}`);
    if (mentions.length > 0) parts.push(plural(mentions.length, 'mention', 'mentions'));
  } else {
    parts.push(`${plural(mentions.length, 'mention', 'mentions')}${from}`);
  }

  const onlyConversation = chats.size === 1 && valid[0].conversationId ? valid[0].conversationId : null;

  return {
    title: 'While you were in your lesson',
    body: parts.join(', '),
    url: onlyConversation ? `/messages/${onlyConversation}` : '/messages',
    count: valid.length,
    mentions: mentions.length,
  };
};

export default summarizeHeld;
__PB_EOF__
echo "wrote server/src/notifications/focusSummary.js"

mkdir -p server/src/realtime
cat > server/src/realtime/liveState.js <<'__PB_EOF__'
// classroom-app/server/src/realtime/liveState.js
/**
 * Is this person looking at the app, or in a lesson?  (Settings, Phase B)
 *
 * Written by the presence gateway while a person has open sockets, refreshed
 * every 25 seconds and gone 60 seconds after the last one closes:
 *
 *   live:{<user>}:app      an open /chat connection (every tab has one)
 *   live:{<user>}:lesson   an open /classroom connection
 *
 * (The braces keep both keys in one cluster slot, so they are read together.)
 *
 * Read by the notification rules: no push to someone looking at the app, and
 * — with focus on — no chat notifications during a lesson. On the state
 * cluster, so every task and the worker see the same answer. The v6 presence
 * keys (presenceCompat.js) are written as well; these two are what the
 * notification rules rely on.
 */

import { stateRedis as redis } from '../db/redis.js';

const TTL_SEC = 60;

const keys = {
  app: (userId) => `live:{${userId}}:app`,
  lesson: (userId) => `live:{${userId}}:lesson`,
};

export const markApp = (userId) => redis.set(keys.app(userId), '1', 'EX', TTL_SEC);
export const markLesson = (userId) => redis.set(keys.lesson(userId), '1', 'EX', TTL_SEC);
export const clearApp = (userId) => redis.del(keys.app(userId));
export const clearLesson = (userId) => redis.del(keys.lesson(userId));

export const isInLesson = async (userId) => (await redis.exists(keys.lesson(userId))) === 1;

/** 'in-class' · 'online' · 'offline'. A Redis problem reads as offline: notify rather than stay silent. */
export const stateOf = async (userId) => {
  try {
    const [[, lesson], [, app]] = await redis.multi().exists(keys.lesson(userId)).exists(keys.app(userId)).exec();
    if (lesson === 1) return 'in-class';
    if (app === 1) return 'online';
    return 'offline';
  } catch {
    return 'offline';
  }
};

export default { markApp, markLesson, clearApp, clearLesson, isInLesson, stateOf };
__PB_EOF__
echo "wrote server/src/realtime/liveState.js"

mkdir -p server/src/realtime
cat > server/src/realtime/userEvents.js <<'__PB_EOF__'
// classroom-app/server/src/realtime/userEvents.js
/**
 * Events addressed to one person, from any process  (Settings, Phase B)
 *
 * The API, the worker and the SFU all need to tell a person something live —
 * "a notification arrived", "your settings changed on another device", "this
 * session was signed out" — but only the realtime process holds sockets. So
 * every process publishes here, on the state Redis cluster, and each realtime
 * task delivers to the sockets it holds (realtime/presenceGateway.js).
 *
 * Publishing never throws: a live update that does not arrive is a missed
 * refresh, not a failed action.
 */

import { env } from '../config/env.js';
import { stateRedis } from '../db/redis.js';
import { logger } from '../observability/logger.js';

const log = logger.child({ component: 'user-events' });

/** Channel names are not keys, so they carry the prefix explicitly. */
export const USER_EVENTS_CHANNEL = `${env.REDIS_PREFIX}:user-events`;

const publish = async (message) => {
  try {
    await stateRedis.publish(USER_EVENTS_CHANNEL, JSON.stringify(message));
    return true;
  } catch (cause) {
    log.warn({ err: cause, type: message.type }, 'user event not published');
    return false;
  }
};

/** An event on every socket of this person, in the /chat namespace (every tab has one). */
export const pushToUser = (userId, event, payload = {}) =>
  userId && event ? publish({ type: 'event', userId, event, payload }) : Promise.resolve(false);

/** Tells the sockets of one sign-in session that it ended, then closes them. */
export const publishSessionRevoked = ({ userId, sessionId, reason = 'signed-out' }) =>
  sessionId ? publish({ type: 'session-revoked', userId, sessionId, reason }) : Promise.resolve(false);

export default { USER_EVENTS_CHANNEL, pushToUser, publishSessionRevoked };
__PB_EOF__
echo "wrote server/src/realtime/userEvents.js"

mkdir -p server/src/realtime
cat > server/src/realtime/presenceGateway.js <<'__PB_EOF__'
// classroom-app/server/src/realtime/presenceGateway.js
/**
 * Presence and per-person delivery  (F2, F6, Settings Phase B)
 *
 * Registered by realtime/index.js (attachPresenceGateway) in every process that
 * holds sockets. Two jobs:
 *
 *   Presence. Whoever has an open /chat connection is looking at the app;
 *   whoever has an open /classroom connection is in a lesson. The
 *   notification rules depend on it: no push to someone looking at the app,
 *   and — with focus on — no chat notifications during a lesson, but a
 *   summary afterwards. Written to realtime/liveState.js (and the v6 presence
 *   keys), refreshed every 25 seconds.
 *
 *   Delivery. Other processes publish events for one person
 *   (realtime/userEvents.js); every realtime task delivers them to the
 *   sockets it holds, in /chat and the root namespace (clients dedupe). Emits are local on purpose: each task receives the
 *   publication itself, so going through the Socket.IO Redis adapter as well
 *   would deliver everything once per task.
 *
 * A sign-in session that was ended elsewhere gets `session:revoked` on its own
 * sockets and is then disconnected; the web client signs out on that event.
 */

import { stateRedis } from '../db/redis.js';
import { logger } from '../observability/logger.js';
import * as Presence from './presenceCompat.js';
import * as LiveState from './liveState.js';
import * as Focus from '../notifications/focus.js';
import { USER_EVENTS_CHANNEL, pushToUser, publishSessionRevoked } from './userEvents.js';

export { pushToUser, publishSessionRevoked };

const log = logger.child({ component: 'presence-gateway' });

const HEARTBEAT_MS = 25_000;

/** Joined by every /chat socket here, so delivery does not depend on another gateway's room names. */
const personalRoom = (userId) => `user-events:${userId}`;
const NAMESPACES = ['/', '/chat', '/classroom', '/community'];

export const attachPresenceGateway = (io) => {
  /** userId → { app: open /chat sockets, lesson: open /classroom sockets } on this task */
  const counts = new Map();

  const bump = (userId, kind, delta) => {
    const entry = counts.get(userId) ?? { app: 0, lesson: 0 };
    entry[kind] = Math.max(0, entry[kind] + delta);
    if (entry.app === 0 && entry.lesson === 0) counts.delete(userId);
    else counts.set(userId, entry);
  };

  const refresh = async (userId, { leftLesson = false } = {}) => {
    const entry = counts.get(userId);
    try {
      if (entry?.lesson > 0) {
        await LiveState.markLesson(userId);
      } else if (leftLesson) {
        // Another task with a lesson socket marks it again within one heartbeat.
        await LiveState.clearLesson(userId);
        await Focus.leftLesson(userId);
      }
      if (entry?.app > 0) await LiveState.markApp(userId);
      else if (!entry) await LiveState.clearApp(userId);
    } catch (cause) {
      log.warn({ err: cause, userId }, 'live state not updated');
    }

    // The v6 presence keys, for everything that still reads them. Best effort.
    try {
      if (!entry) {
        await Presence.clear({ userId });
      } else {
        const inLesson = entry.lesson > 0 || (await LiveState.isInLesson(userId).catch(() => false));
        await Presence.heartbeat({ userId, state: inLesson ? 'in-class' : 'online' });
      }
    } catch {
      // presenceCompat is optional for Phase B.
    }
  };

  for (const [name, kind] of [
    ['/chat', 'app'],
    ['/classroom', 'lesson'],
  ]) {
    io.of(name).on('connection', (socket) => {
      const userId = socket.data?.userId ?? socket.data?.auth?.userId;
      if (!userId) return;
      // Personal room for per-person events (see deliver below).
      if (kind === 'app') socket.join(personalRoom(userId));
      bump(userId, kind, 1);
      void refresh(userId);
      socket.on('disconnect', () => {
        bump(userId, kind, -1);
        void refresh(userId, { leftLesson: kind === 'lesson' && !(counts.get(userId)?.lesson > 0) });
      });
    });
  }

  // The root namespace joins the personal room too: some clients listen there.
  io.of('/').on('connection', (socket) => {
    const userId = socket.data?.userId ?? socket.data?.auth?.userId;
    if (userId) socket.join(personalRoom(userId));
  });

  const timer = setInterval(() => {
    for (const userId of counts.keys()) void refresh(userId);
  }, HEARTBEAT_MS);
  timer.unref?.();

  // -------------------------------------------------------------------------
  // Events for one person, from any process
  // -------------------------------------------------------------------------

  const deliver = (message) => {
    if (message?.type === 'session-revoked') {
      for (const name of NAMESPACES) {
        for (const socket of io.of(name).sockets.values()) {
          const sessionId = socket.data?.sessionId ?? socket.data?.auth?.sessionId ?? null;
          if (sessionId !== message.sessionId) continue;
          socket.emit('session:revoked', { reason: message.reason ?? 'signed-out' });
          // Give the event a moment to leave before the connection closes.
          setTimeout(() => socket.disconnect(true), 250).unref?.();
        }
      }
      return;
    }

    if (message?.type === 'event' && message.userId && message.event) {
      for (const name of ['/chat', '/']) {
        io.of(name).local.to(personalRoom(message.userId)).emit(message.event, message.payload ?? {});
      }
    }
  };

  let subscriber = null;
  try {
    subscriber = stateRedis.duplicate();
    subscriber.on('message', (channel, raw) => {
      if (channel !== USER_EVENTS_CHANNEL) return;
      try {
        deliver(JSON.parse(raw));
      } catch (cause) {
        log.warn({ err: cause }, 'malformed user event');
      }
    });
    subscriber.subscribe(USER_EVENTS_CHANNEL).catch((cause) => {
      log.error({ err: cause }, 'user events not subscribed; live updates will not arrive');
    });
  } catch (cause) {
    log.error({ err: cause }, 'user events subscriber could not be created');
  }

  log.info('presence and per-person delivery attached');

  return {
    close: async () => {
      clearInterval(timer);
      await subscriber?.quit().catch(() => undefined);
    },
  };
};

export default attachPresenceGateway;

/** Other names a realtime entrypoint may call it by. */
export const attach = attachPresenceGateway;
export const registerPresenceGateway = attachPresenceGateway;
__PB_EOF__
echo "wrote server/src/realtime/presenceGateway.js"

mkdir -p server/src/community
cat > server/src/community/NotificationService.js <<'__PB_EOF__'
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
__PB_EOF__
echo "wrote server/src/community/NotificationService.js"

mkdir -p server/src/queues/workers
cat > server/src/queues/workers/notificationWorker.js <<'__PB_EOF__'
/**
 * notificationWorker — in-app · push · email  (F2, F6 · Settings Phase B)
 *
 * Every notification in the product ends here: a thread reply, a mention, a
 * chat message to someone who is away, a lesson reminder, the digest, the
 * summary after a lesson. One worker, because the rules that decide are the
 * same every time — settings/notifications.js#decide — and they must see the
 * settings as they are at delivery, not as they were when the job was queued.
 *
 * Per person:
 *   1. settings        the type × channel matrix from Settings → Notifications
 *   2. focus           in a lesson, chat is held and summarised afterwards
 *   3. presence        someone looking at the app gets no push on top
 *   4. quiet hours     no push, unless a lesson starts and they allow it
 *   5. dedupe          three replies in two minutes are one push, not three
 *
 * Jobs (queue 'notify'):
 *   notification.fanout         one notification, many people
 *   notification.push           v6: push only (the bell entry already exists)
 *   notification.email          one email; account emails always go out
 *   notify.inApp                v6 jobs.notify()
 *   session.reminder            ReminderRules, T-24h and T-10m
 *   digest.daily                community digest by email
 *   notification.focus.flush    the summary after a lesson
 *
 * Push delivery never throws, so a retried job cannot notify everyone twice.
 * An email that fails is logged per person for the same reason; only a
 * single-recipient account email is retried.
 */

import { defineWorker, QUEUE_NAMES, PermanentJobError } from '../queues.js';
import { utilityConnection } from '../connection.js';
import * as NotificationService from '../../community/NotificationService.js';
import * as LiveState from '../../realtime/liveState.js';
import * as ScheduleService from '../../scheduling/ScheduleService.js';
import * as ReminderRules from '../../scheduling/ReminderRules.js';
import * as Rules from '../../settings/notifications.js';
import * as Delivery from '../../notifications/delivery.js';
import * as Focus from '../../notifications/focus.js';

const redis = utilityConnection('notify');

const DEDUPE_TTL_SECONDS = 120;

/* ------------------------------------------------------------------ *
 * Job types
 * ------------------------------------------------------------------ */

const handlers = {
  'notification.fanout': (job, log) => deliver(normalize(job.data), log),
  'notification.push': (job, log) => deliver(normalize({ ...job.data, channels: ['push'] }), log),
  'notification.email': emailJob,
  'notify.inApp': (job, log) =>
    deliver(
      normalize({
        kind: job.data.kind,
        recipientIds: [job.data.userId],
        title: job.data.payload?.title ?? job.data.title,
        body: job.data.payload?.body ?? job.data.body,
        url: job.data.payload?.url ?? job.data.url,
        dedupeKey: job.data.dedupeKey,
      }),
      log,
    ),
  'session.reminder': sessionReminder,
  'digest.daily': digest,
  'notification.focus.flush': focusFlush,
};

export function createNotificationWorker() {
  return defineWorker(QUEUE_NAMES.NOTIFY, async (job, log) => {
    const handler = handlers[job.name];
    if (!handler) throw new PermanentJobError(`Unknown notification job: ${job.name}`);
    return handler(job, log);
  });
}

/* ------------------------------------------------------------------ *
 * Fan-out
 * ------------------------------------------------------------------ */

/** Both payload shapes in use: v7 (kind, recipientIds, url) and v6 (type, userIds, href). */
const normalize = (data = {}) => ({
  kind: data.kind ?? data.type ?? null,
  recipientIds: [...new Set(data.recipientIds ?? data.userIds ?? (data.userId ? [data.userId] : []))],
  title: data.title ?? '',
  body: data.body ?? null,
  url: data.url ?? data.href ?? null,
  actorId: data.actorId ?? null,
  dedupeKey: data.dedupeKey ?? null,
  channels: (data.channels ?? ['in-app', 'push', 'email']).map(Rules.normalizeChannel),
  data: data.data ?? {},
  skipHold: Boolean(data.skipHold),
});

/** 'in-class', 'online' or 'offline', from the presence gateway (realtime/liveState.js). */
const presenceOf = (userId) => LiveState.stateOf(userId);

const heldItem = (n, category) => ({
  type: category === 'mentions' ? 'mention' : 'message',
  from: n.data.from ?? n.title ?? null,
  conversationId: n.data.conversationId ?? null,
  channelId: n.data.channelId ?? null,
});

async function deliver(n, log) {
  if (!n.kind || n.recipientIds.length === 0) {
    throw new PermanentJobError('a notification needs a kind and recipients', { kind: n.kind });
  }

  const result = { delivered: 0, suppressed: 0, held: 0, byChannel: { inApp: 0, push: 0, email: 0 } };

  for (const recipientId of n.recipientIds) {
    // Never tell someone about their own action.
    if (recipientId === n.actorId) continue;

    const context = await NotificationService.getDeliveryContext(recipientId);
    if (!context?.active) {
      result.suppressed += 1;
      continue;
    }

    const presence = await presenceOf(recipientId);
    let decision = Rules.decide({
      kind: n.kind,
      settings: context.settings,
      presence,
      requested: n.channels,
      timeZone: context.timeZone,
    });

    if (decision.hold) {
      if (!n.skipHold) {
        await Focus.hold(recipientId, heldItem(n, decision.category));
        result.held += 1;
        continue;
      }
      decision = Rules.decide({
        kind: n.kind,
        settings: context.settings,
        presence: 'online',
        requested: n.channels,
        timeZone: context.timeZone,
      });
    }

    let { channels } = decision;

    if (n.dedupeKey && channels.some((channel) => channel !== 'inApp')) {
      const fresh = await redis.set(`notify:dedupe:${recipientId}:${n.dedupeKey}`, '1', 'EX', DEDUPE_TTL_SECONDS, 'NX');
      if (!fresh) channels = channels.filter((channel) => channel === 'inApp');
    }

    if (channels.length === 0) {
      result.suppressed += 1;
      continue;
    }

    // "Show message text" off: lock screens and inboxes say who, not what.
    const hideText = Rules.CHAT_CATEGORIES.has(decision.category) && !context.settings.showPreviews;
    const outsideBody = hideText ? 'Open Classroom to read it.' : n.body;

    if (channels.includes('inApp')) {
      await NotificationService.createInApp({
        userId: recipientId,
        kind: n.kind,
        title: n.title,
        body: n.body,
        url: n.url,
        actorId: n.actorId,
        data: n.data,
      });
      result.byChannel.inApp += 1;
    }

    if (channels.includes('push')) {
      const sent = await Delivery.sendPush({ userId: recipientId, title: n.title, body: outsideBody, url: n.url, kind: n.kind });
      result.byChannel.push += sent.delivered;
    }

    if (channels.includes('email') && context.email && !context.emailSuppressed) {
      try {
        const rendered = Delivery.renderEmail({
          title: n.title,
          body: outsideBody,
          url: n.url,
          recipientName: context.displayName,
        });
        await Delivery.sendEmail({ to: context.email, ...rendered, kind: n.kind });
        result.byChannel.email += 1;
      } catch (cause) {
        log.error({ err: cause, recipientId, kind: n.kind }, 'notify: email not sent');
      }
    }

    result.delivered += 1;
  }

  log.info({ kind: n.kind, ...result }, 'notify: delivered');
  return result;
}

/* ------------------------------------------------------------------ *
 * Email
 * ------------------------------------------------------------------ */

const ACCOUNT_EMAIL = {
  'email.verify': { actionLabel: 'Confirm email address', body: 'Confirm that this address is yours. The link works for 24 hours.' },
  'password.reset': { actionLabel: 'Choose a new password', body: 'Someone asked to reset your password. If that was not you, ignore this email. The link works for one hour.' },
};

/**
 * One email. Account emails (confirm address, reset password) go out whatever
 * the settings say, and are retried when the mail server is unavailable.
 * Anything else follows the settings like every other notification.
 */
async function emailJob(job, log) {
  const kind = job.data.kind ?? job.data.type ?? 'system.email';
  const userId = job.data.userId;
  if (!userId) throw new PermanentJobError('an email needs a userId');

  if (Rules.categoryOf(kind) !== 'security') {
    return deliver(normalize({ ...job.data, kind, recipientIds: [userId], channels: ['email'] }), log);
  }

  const context = await NotificationService.getDeliveryContext(userId);
  if (!context?.email) return { skipped: 'no address' };
  if (context.emailSuppressed) return { skipped: 'address suppressed after a bounce' };

  const account = ACCOUNT_EMAIL[kind] ?? { actionLabel: 'Open Classroom', body: null };
  const rendered = Delivery.renderEmail({
    title: job.data.title ?? 'Classroom',
    body: job.data.body ?? account.body,
    url: job.data.url ?? job.data.href,
    recipientName: context.displayName,
    actionLabel: account.actionLabel,
    footer: 'You get this email because of an action on your Classroom account.',
  });
  // Throws on a mail server problem: BullMQ retries with backoff.
  await Delivery.sendEmail({ to: context.email, ...rendered, kind });
  log.info({ userId, kind }, 'notify: account email sent');
  return { sent: 1 };
}

/* ------------------------------------------------------------------ *
 * Lesson reminders (F1, F3)
 * ------------------------------------------------------------------ */

/**
 * Enqueued by ReminderRules.enqueueDue(). The reminder row is the source of
 * truth, so the audience is resolved at send time.
 */
async function sessionReminder(job, log) {
  const { reminderId, sessionId, ruleKey, template } = job.data;

  const session = await ScheduleService.getSession(sessionId);
  if (!session) {
    await ReminderRules.markSent(reminderId, { recipients: 0 });
    throw new PermanentJobError('Session no longer exists', { sessionId });
  }
  if (session.status !== 'scheduled') {
    await ReminderRules.markSent(reminderId, { recipients: 0 });
    return { skipped: session.status };
  }

  const recipientIds = await ScheduleService.listAudience(sessionId);
  const when = ScheduleService.formatLocal(session);

  const result = await deliver(
    normalize({
      kind: template,
      recipientIds,
      title: session.title,
      body: ruleKey === 'T-10m' ? 'Starts in 10 minutes' : `Starts ${when}`,
      url: session.lessonId ? `/lessons/${session.lessonId}/live` : '/',
      dedupeKey: `session:${sessionId}:${ruleKey}`,
      channels: ruleKey === 'T-10m' ? ['push', 'in-app'] : ['email', 'push', 'in-app'],
      data: { sessionId, lessonId: session.lessonId ?? null },
    }),
    log,
  );

  await ReminderRules.markSent(reminderId, { recipients: result.delivered });
  return result;
}

/* ------------------------------------------------------------------ *
 * Digest (F2)
 * ------------------------------------------------------------------ */

async function digest(job, log) {
  const { userId, date } = job.data;
  const content = await NotificationService.buildDigest({ userId, date });
  if (!content || content.items.length === 0) return { skipped: 'nothing to send' };

  const context = await NotificationService.getDeliveryContext(userId);
  if (!context?.email || context.emailSuppressed) return { skipped: 'no address' };

  const rendered = Delivery.renderEmail({
    title: content.subject,
    body: content.summary,
    url: content.url,
    recipientName: context.displayName,
    actionLabel: 'Open the community',
  });
  await Delivery.sendEmail({ to: context.email, ...rendered, kind: 'digest.daily' });
  log.info({ userId, items: content.items.length }, 'notify: digest sent');
  return { sent: 1, items: content.items.length };
}

/* ------------------------------------------------------------------ *
 * Focus: the summary after a lesson
 * ------------------------------------------------------------------ */

async function focusFlush(job, log) {
  const { userId } = job.data;
  if (!userId) throw new PermanentJobError('focus flush needs a userId');

  await Focus.clearSchedule(userId);

  if (await Focus.isInLesson(userId)) {
    // Still teaching or learning: look again in a minute.
    await Focus.scheduleFlush(userId);
    return { waiting: true };
  }

  const items = await Focus.takeHeld(userId);
  const summary = Focus.summarizeHeld(items);
  if (!summary) return { empty: true };

  return deliver(
    normalize({
      kind: 'chat.focus.summary',
      recipientIds: [userId],
      title: summary.title,
      body: summary.body,
      url: summary.url,
      channels: ['in-app', 'push'],
      skipHold: true,
      data: { held: summary.count, mentions: summary.mentions },
    }),
    log,
  );
}

export default createNotificationWorker;
__PB_EOF__
echo "wrote server/src/queues/workers/notificationWorker.js"

mkdir -p server/src/queues/workers
cat > server/src/queues/workers/chatFanoutWorker.js <<'__PB_EOF__'
/**
 * chatFanoutWorker — who hears about a chat message  (F6 · Settings Phase B)
 *
 * The send path does the minimum: store the message, put it on everyone's
 * screen, count it unread (DirectMessageService). Deciding who else should
 * hear about it happens here, a beat later, so a slow push provider never
 * delays a message that is already visible.
 *
 * For each message:
 *
 *   recipients   a private chat: its participants, minus the author and
 *                anyone who muted it. A channel (the lesson's default
 *                chatroom): only people who opted in under Settings →
 *                Notifications, since the audience is the whole organisation.
 *                Mentioned people always count, unless a block stands between.
 *
 *   presence     looking at the app → nothing more (the badge moves).
 *                In a lesson → held for the summary afterwards, if they have
 *                focus on. Away or offline → a notification job, where the
 *                settings, quiet hours and dedupe decide the channels.
 *
 * The job loads the message itself, so the producer only needs its id, and a
 * message deleted before the job runs notifies nobody.
 */

import { defineWorker, enqueue, QUEUE_NAMES, PermanentJobError } from '../queues.js';
import { pool } from '../../db/pool.js';
import * as LiveState from '../../realtime/liveState.js';
import * as NotificationService from '../../community/NotificationService.js';
import * as Focus from '../../notifications/focus.js';

const handlers = {
  'chat.message.fanout': fanoutMessage,
  'chat.message.index': indexMessage,
  'chat.read.sync': syncRead,
};

export function createChatFanoutWorker() {
  return defineWorker(QUEUE_NAMES.CHAT, async (job, log) => {
    const handler = handlers[job.name];
    if (!handler) throw new PermanentJobError(`Unknown chat job: ${job.name}`);
    return handler(job, log);
  });
}

/* ------------------------------------------------------------------ *
 * Loading
 * ------------------------------------------------------------------ */

const loadMessage = async (messageId) => {
  const { rows } = await pool.query(
    `SELECT m.message_id, m.author_id, m.body, m.mentions, m.conversation_id, m.channel_id,
            m.deleted_at, u.display_name AS author_name, ch.name AS channel_name
       FROM messages m
       JOIN users u ON u.id = m.author_id
       LEFT JOIN channels ch ON ch.channel_id = m.channel_id
      WHERE m.message_id = $1`,
    [messageId],
  );
  return rows[0] ?? null;
};

/** The other people in a private chat who have not left it or muted it. */
const conversationRecipients = async (conversationId, authorId) => {
  const { rows } = await pool.query(
    `SELECT cp.user_id
       FROM conversation_participants cp
       JOIN users u ON u.id = cp.user_id AND u.deleted_at IS NULL
      WHERE cp.conversation_id = $1
        AND cp.user_id <> $2
        AND cp.left_at IS NULL
        AND NOT (coalesce(cp.muted, false) AND (cp.muted_until IS NULL OR cp.muted_until > now()))`,
    [conversationId, authorId],
  );
  return rows.map((row) => row.user_id);
};

/** People who asked to hear about the channel, minus mutes and blocks. */
const channelOptIns = async (channelId, authorId) => {
  const { rows } = await pool.query(
    `SELECT np.user_id
       FROM notification_preferences np
       JOIN users u ON u.id = np.user_id AND u.deleted_at IS NULL AND u.status = 'active'
       JOIN channels ch ON ch.channel_id = $1 AND ch.archived_at IS NULL AND ch.tenant_id = u.tenant_id
      WHERE np.user_id <> $2
        AND (coalesce((np.channels -> 'channelMessages' ->> 'inApp')::boolean, false)
          OR coalesce((np.channels -> 'channelMessages' ->> 'push')::boolean, false)
          OR coalesce((np.channels -> 'channelMessages' ->> 'email')::boolean, false))
        AND NOT EXISTS (SELECT 1 FROM channel_members cm
                         WHERE cm.channel_id = $1 AND cm.user_id = np.user_id AND cm.muted
                           AND (cm.muted_until IS NULL OR cm.muted_until > now()))
        AND NOT EXISTS (SELECT 1 FROM blocks b
                         WHERE (b.user_id = np.user_id AND b.blocked_id = $2)
                            OR (b.user_id = $2 AND b.blocked_id = np.user_id))
        AND (ch.scope = 'public'
          OR (ch.scope = 'space' AND EXISTS (SELECT 1 FROM space_memberships s
                                              WHERE s.space_id = ch.scope_ref_id AND s.user_id = np.user_id))
          OR (ch.scope = 'course' AND EXISTS (SELECT 1 FROM enrollments e
                                               WHERE e.course_id = ch.scope_ref_id AND e.user_id = np.user_id
                                                 AND e.status = 'active')))
      LIMIT 5000`,
    [channelId, authorId],
  );
  return rows.map((row) => row.user_id);
};

/** Mentioned people the author is not blocked with, either way. */
const unblocked = async (authorId, userIds) => {
  if (userIds.length === 0) return [];
  const { rows } = await pool.query(
    `SELECT DISTINCT CASE WHEN user_id = $1 THEN blocked_id ELSE user_id END AS other
       FROM blocks
      WHERE (user_id = $1 AND blocked_id = ANY($2::uuid[]))
         OR (blocked_id = $1 AND user_id = ANY($2::uuid[]))`,
    [authorId, userIds],
  );
  const blocked = new Set(rows.map((row) => row.other));
  return userIds.filter((id) => !blocked.has(id));
};

/** 'in-class', 'online' or 'offline', from the presence gateway (realtime/liveState.js). */
const presenceOf = (userId) => LiveState.stateOf(userId);

const preview = (text) => {
  const value = String(text ?? '').replace(/\s+/g, ' ').trim();
  return value.length > 160 ? `${value.slice(0, 159)}…` : value || 'Sent an attachment';
};

/* ------------------------------------------------------------------ *
 * Fan-out
 * ------------------------------------------------------------------ */

async function fanoutMessage(job, log) {
  // The producer's payload has changed shape over time; accept every one of them.
  const messageId =
    job.data?.messageId ?? job.data?.message?.messageId ?? job.data?.message?.id ?? job.data?.id ?? null;
  if (!messageId) throw new PermanentJobError('chat fan-out needs a messageId');

  const message = await loadMessage(messageId);
  if (!message || message.deleted_at) return { skipped: 'message gone' };
  if (!message.conversation_id && !message.channel_id) return { skipped: 'lesson chat' };

  const authorId = message.author_id;
  const sender = message.author_name ?? 'Someone';
  const conversationId = message.conversation_id ?? null;
  const channelId = message.channel_id ?? null;
  const url = conversationId ? `/messages/${conversationId}` : '/messages';

  const recipients = conversationId
    ? await conversationRecipients(conversationId, authorId)
    : await channelOptIns(channelId, authorId);

  const mentioned = await unblocked(
    authorId,
    [...new Set((message.mentions ?? []).map(String))].filter((id) => id !== authorId),
  );
  const mentionSet = new Set(mentioned);

  const away = { message: [], mention: [] };
  let looking = 0;
  let held = 0;

  for (const userId of new Set([...recipients, ...mentioned])) {
    const type = mentionSet.has(userId) ? 'mention' : 'message';
    const presence = await presenceOf(userId);

    if (presence === 'in-class') {
      const settings = await NotificationService.getSettings(userId);
      const category = type === 'mention' ? 'mentions' : conversationId ? 'directMessages' : 'channelMessages';
      const anyChannel = Object.values(settings.categories[category]).some(Boolean);
      if (settings.focusDuringLessons && anyChannel) {
        await Focus.hold(userId, { type, from: sender, conversationId, channelId });
        held += 1;
      }
      continue;
    }

    if (presence === 'online') {
      looking += 1;
      continue;
    }

    away[type].push(userId);
  }

  const data = { conversationId, channelId, messageId, from: sender };

  if (away.message.length > 0) {
    await enqueue(
      QUEUE_NAMES.NOTIFY,
      'notification.fanout',
      {
        kind: conversationId ? 'chat.direct.message' : 'chat.channel.message',
        recipientIds: away.message,
        actorId: authorId,
        title: conversationId ? sender : `${sender} in # ${message.channel_name ?? 'chat'}`,
        body: preview(message.body),
        url,
        // Three messages in two minutes are one push, not three.
        dedupeKey: `chat:${conversationId ?? channelId}`,
        channels: ['in-app', 'push', 'email'],
        data,
      },
      { jobId: `chat-push:${messageId}` },
    );
  }

  if (away.mention.length > 0) {
    await enqueue(
      QUEUE_NAMES.NOTIFY,
      'notification.fanout',
      {
        kind: 'chat.mention',
        recipientIds: away.mention,
        actorId: authorId,
        title: `${sender} mentioned you`,
        body: preview(message.body),
        url,
        dedupeKey: `mention:${messageId}`,
        channels: ['in-app', 'push', 'email'],
        data,
      },
      { jobId: `chat-mention:${messageId}` },
    );
  }

  const outcome = {
    recipients: recipients.length,
    mentioned: mentioned.length,
    looking,
    held,
    notified: away.message.length + away.mention.length,
  };
  log.debug({ messageId, ...outcome }, 'chat: fan-out done');
  return outcome;
}

/* ------------------------------------------------------------------ *
 * Search index and read sync — run only where their services exist
 * ------------------------------------------------------------------ */

async function indexMessage(job, log) {
  const Search = await import('../../messaging/ChatSearchService.js');
  const message = await loadMessage(job.data?.messageId ?? job.data?.message?.messageId);
  if (!message || message.deleted_at) {
    const remove = Search.removeFromIndex ?? Search.remove;
    if (typeof remove === 'function') await remove(job.data.messageId);
    return { removed: true };
  }
  const index = Search.indexMessage ?? Search.index;
  if (typeof index !== 'function') {
    log.debug('chat: no search index configured');
    return { skipped: 'no index' };
  }
  await index({
    messageId: message.message_id,
    authorId: message.author_id,
    body: message.body,
    target: message.conversation_id
      ? { kind: 'conversation', conversationId: message.conversation_id }
      : { kind: 'channel', channelId: message.channel_id },
  });
  return { indexed: true };
}

async function syncRead(job) {
  const { scopeId, userId } = job.data;
  const Unread = await import('../../messaging/UnreadService.js');
  if (typeof Unread.rebuild === 'function' && userId) await Unread.rebuild({ userId });
  return { synced: true, scopeId };
}

export default createChatFanoutWorker;
__PB_EOF__
echo "wrote server/src/queues/workers/chatFanoutWorker.js"

mkdir -p server/src/routes
cat > server/src/routes/account.routes.js <<'__PB_EOF__'
/**
 * account.routes — notifications · signed-in devices · history  (Settings, Phase B)
 *
 * Mounted under /account (app.js). Everything here is about the person asking;
 * no route takes someone else's id.
 *
 *   GET    /notifications                 settings, push and email status
 *   PATCH  /notifications                 any part of the settings
 *   POST   /notifications/test            { channel: inApp | push | email }
 *   PUT    /push-subscriptions            this browser receives push
 *   POST   /push-subscriptions/remove     this browser stops
 *   GET    /muted-chats                   every chat muted right now
 *   POST   /muted-chats/:kind/:id/unmute  ends one mute
 *   POST   /muted-chats/:kind/:id/mute    mutes again (the undo of unmute)
 *   GET    /sessions                      signed-in devices, this one marked
 *   DELETE /sessions/:sessionId           sign one device out
 *   POST   /sessions/sign-out-others      sign out everywhere else
 *   GET    /login-history                 sign-ins and failed attempts
 *   GET    /activity                      recent settings changes
 *
 * A test notification is sent from here directly rather than through the
 * queue, so the answer says what actually happened ("sent to 2 browsers",
 * "the mail server refused it") and a test works while the worker is down.
 */

import { Router } from 'express';
import { z } from 'zod';

import { pool } from '../db/pool.js';
import * as NotificationService from '../community/NotificationService.js';
import * as Rules from '../settings/notifications.js';
import * as Subscriptions from '../notifications/webPushSubscriptions.js';
import * as Delivery from '../notifications/delivery.js';
import { deliveryConfig } from '../notifications/config.js';
import * as DeviceSessions from '../identity/deviceSessions.js';
import * as Participant from '../messaging/models/Participant.js';
import { auditFromRequest } from '../security/auditLog.js';
import { SIGN_IN_FAILED, SIGN_IN_SUCCEEDED } from '../security/sessionActivity.js';
import { describeUserAgent } from '../security/userAgent.js';
import { recordChange } from '../settings/changeLog.js';
import { pushToUser } from '../realtime/userEvents.js';
import { rateLimit } from '../middleware/rateLimit.js';
import { route, validate, requireAuth, q, notFound, badRequest, forbidden } from './_helpers.js';

const router = Router();
router.use(requireAuth);

/** Errors the services raise with a code, as the HTTP answers clients understand. */
const asHttp = (fn) => async (req, res) => {
  try {
    return await fn(req, res);
  } catch (error) {
    switch (error?.code) {
      case 'validation_failed':
        throw badRequest(error.message);
      case 'forbidden':
        throw forbidden(error.message);
      case 'not_found':
        throw notFound(error.message);
      default:
        throw error;
    }
  }
};

const iso = (value) => (value ? new Date(value).toISOString() : null);

/* ------------------------------------------------------------------ *
 * Notifications
 * ------------------------------------------------------------------ */

const notificationsView = async (userId) => {
  const context = await NotificationService.getDeliveryContext(userId);
  if (!context) throw notFound('No account');
  return {
    settings: context.settings,
    timeZone: context.timeZone,
    quietNow: Rules.isWithinQuietHours(context.settings.quietHours, new Date(), context.timeZone),
    push: {
      configured: Delivery.webPushConfigured(),
      publicKey: Delivery.webPushPublicKey(),
      devices: await Subscriptions.countForUser(userId),
    },
    email: { address: context.email, suppressed: context.emailSuppressed },
  };
};

router.get('/notifications', route(async (req) => notificationsView(req.user.id)));

router.patch(
  '/notifications',
  route(
    asHttp(async (req) => {
      await NotificationService.updateSettings({ userId: req.user.id, patch: req.body ?? {} });
      await recordChange(req, 'notifications', req.body);
      return notificationsView(req.user.id);
    }),
  ),
);

const TEST_TEXT = {
  title: 'Test notification',
  body: 'If you can read this, notifications reach you here.',
  url: '/settings/notifications',
};

router.post(
  '/notifications/test',
  rateLimit({ key: 'account:notify-test', points: 10, durationSec: 60, by: ['user'] }),
  validate({ body: z.object({ channel: z.enum(['inApp', 'push', 'email']) }) }),
  route(async (req) => {
    const userId = req.user.id;
    const { channel } = req.body;

    if (channel === 'inApp') {
      await NotificationService.createInApp({ userId, kind: 'system.test', ...TEST_TEXT });
      return { channel, delivered: 1, detail: 'Sent. It appears on screen in every open tab of the app.' };
    }

    if (channel === 'push') {
      if (!Delivery.webPushConfigured()) {
        return { channel, delivered: 0, detail: 'Push is not set up on the server: the web push keys are missing.' };
      }
      const result = await Delivery.sendPush({ userId, kind: 'system.test', ...TEST_TEXT });
      if (result.targets === 0) {
        return {
          channel,
          delivered: 0,
          detail: 'No browser receives push on this account yet. Turn on push for this browser first.',
        };
      }
      return {
        channel,
        delivered: result.delivered,
        detail:
          result.failed === 0
            ? `Sent to ${result.delivered} ${result.delivered === 1 ? 'browser' : 'browsers'}.`
            : `Sent to ${result.delivered} of ${result.targets}. Browsers that no longer accept push were removed.`,
      };
    }

    const context = await NotificationService.getDeliveryContext(userId);
    if (!context?.email) return { channel, delivered: 0, detail: 'This account has no email address.' };
    if (context.emailSuppressed) {
      return { channel, delivered: 0, detail: 'Email to this address is paused because an earlier one bounced.' };
    }
    try {
      const rendered = Delivery.renderEmail({ ...TEST_TEXT, recipientName: context.displayName });
      const sent = await Delivery.sendEmail({ to: context.email, ...rendered, kind: 'system.test' });
      const where =
        sent.transport === 'smtp' && deliveryConfig().smtpPort === 1025
          ? ' In development it lands in Mailpit (port 8025).'
          : '';
      return { channel, delivered: 1, detail: `Sent to ${context.email}.${where}` };
    } catch (cause) {
      return {
        channel,
        delivered: 0,
        detail: `The mail server did not accept it (${cause?.code ?? cause?.message ?? 'unknown error'}).`,
      };
    }
  }),
);

/* ------------------------------------------------------------------ *
 * Push registrations (this browser)
 * ------------------------------------------------------------------ */

const subscriptionBody = z
  .object({
    endpoint: z
      .string()
      .url()
      .max(2048)
      .refine((value) => value.startsWith('https://'), 'push endpoints are https'),
    keys: z.object({ p256dh: z.string().min(16).max(256), auth: z.string().min(8).max(64) }).passthrough(),
  })
  .passthrough();

router.put(
  '/push-subscriptions',
  rateLimit({ key: 'account:push-register', points: 20, durationSec: 3600, by: ['user'] }),
  validate({ body: subscriptionBody }),
  route(async (req) => {
    if (!Delivery.webPushConfigured()) throw badRequest('Push is not set up on the server.');
    await Subscriptions.upsert({
      userId: req.user.id,
      sessionId: req.user.sessionId ?? null,
      endpoint: req.body.endpoint,
      p256dh: req.body.keys.p256dh,
      auth: req.body.keys.auth,
      userAgent: req.get('user-agent'),
    });
    return { registered: true, devices: await Subscriptions.countForUser(req.user.id) };
  }),
);

router.post(
  '/push-subscriptions/remove',
  validate({ body: z.object({ endpoint: z.string().max(2048) }) }),
  route(async (req) => {
    await Subscriptions.removeByEndpoint({ userId: req.user.id, endpoint: req.body.endpoint });
    return { registered: false, devices: await Subscriptions.countForUser(req.user.id) };
  }),
);

/* ------------------------------------------------------------------ *
 * Muted chats
 * ------------------------------------------------------------------ */

router.get('/muted-chats', route(async (req) => NotificationService.mutedChats(req.user.id)));

const muteParams = z.object({ kind: z.enum(['conversation', 'channel']), id: z.string().uuid() });

const setChatMute = async ({ userId, kind, id, muted, until = null }) => {
  if (kind === 'conversation') {
    if (!(await Participant.isParticipant({ conversationId: id, userId }))) throw notFound('Chat not found');
    await Participant.setMuted({ conversationId: id, userId, muted, until: muted ? until : null });
    return;
  }
  const { rowCount } = await pool.query(
    `UPDATE channel_participants SET muted = $3, muted_until = $4
      WHERE channel_id = $1 AND user_id = $2`,
    [id, userId, muted, muted ? until : null],
  );
  if (rowCount === 0) throw notFound('Chat not found');
};

router.post(
  '/muted-chats/:kind/:id/unmute',
  validate({ params: muteParams }),
  route(async (req) => {
    await setChatMute({ userId: req.user.id, kind: req.params.kind, id: req.params.id, muted: false });
    await pushToUser(req.user.id, 'settings:changed', { section: 'muted', fields: [] });
    return { muted: false };
  }),
);

router.post(
  '/muted-chats/:kind/:id/mute',
  validate({
    params: muteParams,
    body: z.object({ until: z.string().nullish() }).passthrough().default({}),
  }),
  route(async (req) => {
    const requested = req.body?.until ? new Date(req.body.until) : null;
    const until = requested && !Number.isNaN(requested.getTime()) && requested > new Date() ? requested.toISOString() : null;
    await setChatMute({ userId: req.user.id, kind: req.params.kind, id: req.params.id, muted: true, until });
    await pushToUser(req.user.id, 'settings:changed', { section: 'muted', fields: [] });
    return { muted: true, mutedUntil: until };
  }),
);

/* ------------------------------------------------------------------ *
 * Signed-in devices
 * ------------------------------------------------------------------ */

router.get(
  '/sessions',
  route(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    const sessions = await DeviceSessions.list(req.user.id);
    return {
      items: sessions.map((session) => ({ ...session, current: session.sessionId === req.user.sessionId })),
    };
  }),
);

router.delete(
  '/sessions/:sessionId',
  rateLimit({ key: 'account:sessions', points: 30, durationSec: 300, by: ['user'] }),
  validate({ params: z.object({ sessionId: z.string().min(8).max(128) }) }),
  route(async (req) => {
    if (req.params.sessionId === req.user.sessionId) {
      throw badRequest('This is the device you are using. Use Sign out instead.');
    }
    const result = await DeviceSessions.revoke({ userId: req.user.id, sessionId: req.params.sessionId });
    if (!result) throw notFound('No such device');
    await auditFromRequest(req, {
      action: 'auth.session.revoked',
      targetType: 'user',
      targetId: req.user.id,
      metadata: { device: result.label, count: 1 },
    });
    await pushToUser(req.user.id, 'settings:changed', { section: 'sessions', fields: [] });
    return null;
  }),
);

router.post(
  '/sessions/sign-out-others',
  rateLimit({ key: 'account:sessions', points: 30, durationSec: 300, by: ['user'] }),
  route(async (req) => {
    const { revoked } = await DeviceSessions.revokeOthers({
      userId: req.user.id,
      currentSessionId: req.user.sessionId,
    });
    if (revoked > 0) {
      await auditFromRequest(req, {
        action: 'auth.session.revoked',
        targetType: 'user',
        targetId: req.user.id,
        metadata: { device: null, count: revoked },
      });
      await pushToUser(req.user.id, 'settings:changed', { section: 'sessions', fields: [] });
    }
    return { revoked };
  }),
);

/* ------------------------------------------------------------------ *
 * History (audit_log)
 * ------------------------------------------------------------------ */

const pageQuery = z
  .object({
    cursor: z.string().regex(/^\d+$/).optional(),
    limit: z.coerce.number().int().min(1).max(50).optional(),
  })
  .passthrough();

const readHistory = async ({ userId, actions, cursor, limit }) => {
  const { rows } = await pool.query(
    `SELECT id, action, metadata, host(ip) AS ip, user_agent, created_at
       FROM audit_log
      WHERE actor_id = $1 AND action = ANY($2::text[])
        AND ($3::bigint IS NULL OR id < $3::bigint)
      ORDER BY id DESC
      LIMIT $4`,
    [userId, actions, cursor ?? null, limit + 1],
  );
  const page = rows.slice(0, limit);
  return {
    items: page.map((row) => ({
      id: String(row.id),
      action: row.action,
      at: iso(row.created_at),
      device: describeUserAgent(row.user_agent ?? ''),
      ip: row.ip ?? null,
      section: row.metadata?.section ?? null,
      fields: Array.isArray(row.metadata?.fields) ? row.metadata.fields : [],
      detail: row.metadata?.device ?? row.metadata?.reason ?? null,
      count: typeof row.metadata?.count === 'number' ? row.metadata.count : null,
    })),
    nextCursor: rows.length > limit && page.length ? String(page.at(-1).id) : null,
  };
};

router.get(
  '/login-history',
  validate({ query: pageQuery }),
  route(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    return readHistory({
      userId: req.user.id,
      actions: [SIGN_IN_SUCCEEDED, SIGN_IN_FAILED],
      cursor: q(req).cursor,
      limit: Number(q(req).limit ?? 20),
    });
  }),
);

router.get(
  '/activity',
  validate({ query: pageQuery }),
  route(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    return readHistory({
      userId: req.user.id,
      actions: ['settings.changed', 'auth.session.revoked'],
      cursor: q(req).cursor,
      limit: Number(q(req).limit ?? 20),
    });
  }),
);

export default router;
__PB_EOF__
echo "wrote server/src/routes/account.routes.js"

mkdir -p server/test/settings
cat > server/test/settings/notifications.check.mjs <<'__PB_EOF__'
// Settings, Phase B — the pure rules behind notifications, devices and history.
// Run: node --test server/test/settings/*.check.mjs
// (.check.mjs rather than .test.js, so no other test runner picks these up.)

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  categoryOf,
  decide,
  isWithinQuietHours,
  mergeNotificationPatch,
  withNotificationDefaults,
  fromRow,
  toRow,
  DEFAULT_NOTIFICATION_SETTINGS,
} from '../../src/settings/notifications.js';
import { describeUserAgent } from '../../src/security/userAgent.js';
import { summarizeHeld } from '../../src/notifications/focusSummary.js';
import { fieldPaths } from '../../src/settings/fieldPaths.js';

const at = (hhmm) => new Date(`2026-03-10T${hhmm}:00Z`);

test('kinds map to the categories people see', () => {
  assert.equal(categoryOf('chat.direct.message'), 'directMessages');
  assert.equal(categoryOf('chat.mention'), 'mentions');
  assert.equal(categoryOf('chat.channel.message'), 'channelMessages');
  assert.equal(categoryOf('session.reminder.starting_soon'), 'lessonReminders');
  assert.equal(categoryOf('asset.ready'), 'coursework');
  assert.equal(categoryOf('password.reset'), 'security');
  assert.equal(categoryOf('thread.reply'), 'community');
});

test('defaults: private messages push, chatroom messages stay silent', () => {
  const settings = withNotificationDefaults({});
  assert.equal(settings.categories.directMessages.push, true);
  assert.deepEqual(settings.categories.channelMessages, { inApp: false, push: false, email: false });
  assert.equal(decide({ kind: 'chat.channel.message', settings }).channels.length, 0);
});

test('invalid stored values fall back to defaults', () => {
  const settings = withNotificationDefaults({ digest: 'hourly', quietHours: { start: '25:00' } });
  assert.equal(settings.digest, DEFAULT_NOTIFICATION_SETTINGS.digest);
  assert.equal(settings.quietHours.start, '22:00');
});

test('patches merge, unknown keys and equal quiet hours are refused', () => {
  const next = mergeNotificationPatch({}, { categories: { mentions: { email: true } }, digest: 'weekly' });
  assert.equal(next.categories.mentions.email, true);
  assert.equal(next.categories.mentions.push, true);
  assert.equal(next.digest, 'weekly');
  assert.throws(() => mergeNotificationPatch({}, { categories: { spam: { push: true } } }), { code: 'validation_failed' });
  assert.throws(() => mergeNotificationPatch({}, { quietHours: { start: '07:00', end: '07:00' } }), { code: 'validation_failed' });
});

test('rows round-trip', () => {
  const settings = mergeNotificationPatch({}, { quietHours: { enabled: true, start: '21:30' }, showPreviews: false });
  const row = { ...toRow(settings), quiet_start: '21:30:00', quiet_end: '07:00:00' };
  assert.deepEqual(fromRow(row), settings);
});

test('quiet hours run past midnight in the person\'s time zone', () => {
  const quiet = { enabled: true, start: '22:00', end: '07:00' };
  assert.equal(isWithinQuietHours(quiet, at('23:30'), 'UTC'), true);
  assert.equal(isWithinQuietHours(quiet, at('06:59'), 'UTC'), true);
  assert.equal(isWithinQuietHours(quiet, at('07:00'), 'UTC'), false);
  // 21:30 UTC is 22:30 in Berlin in March.
  assert.equal(isWithinQuietHours(quiet, at('21:30'), 'Europe/Berlin'), true);
  assert.equal(isWithinQuietHours({ ...quiet, enabled: false }, at('23:30'), 'UTC'), false);
  assert.equal(isWithinQuietHours(quiet, at('23:30'), 'Not/AZone'), true);
});

test('decide: switched off, focus, presence, quiet hours, lesson exception, security', () => {
  const base = withNotificationDefaults({});
  const quiet = mergeNotificationPatch({}, { quietHours: { enabled: true } });

  assert.deepEqual(
    decide({ kind: 'chat.direct.message', settings: base, presence: 'offline' }).channels,
    ['inApp', 'push'],
  );
  assert.equal(decide({ kind: 'chat.direct.message', settings: base, presence: 'in-class' }).hold, true);
  assert.equal(
    decide({ kind: 'chat.direct.message', settings: { ...base, focusDuringLessons: false }, presence: 'in-class' }).hold,
    false,
  );
  assert.deepEqual(decide({ kind: 'chat.direct.message', settings: base, presence: 'online' }).channels, ['inApp']);

  const night = decide({ kind: 'chat.direct.message', settings: quiet, now: at('23:00') });
  assert.deepEqual(night.channels, ['inApp']);
  assert.equal(night.reason, 'quiet hours');

  assert.ok(decide({ kind: 'session.reminder.starting_soon', settings: quiet, now: at('23:00') }).channels.includes('push'));

  const off = mergeNotificationPatch({}, { categories: { directMessages: { inApp: false, push: false, email: false } } });
  assert.equal(decide({ kind: 'chat.direct.message', settings: off }).reason, 'switched off');
  assert.deepEqual(decide({ kind: 'password.reset', settings: off, requested: ['email'] }).channels, ['email']);
});

test('user agents read as a browser on a system', () => {
  const chrome = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';
  const safari = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';
  const edge = `${chrome} Edg/126.0`;
  assert.equal(describeUserAgent(chrome), 'Chrome on Windows');
  assert.equal(describeUserAgent(safari), 'Safari on iPhone');
  assert.equal(describeUserAgent(edge), 'Edge on Windows');
  assert.equal(describeUserAgent(''), 'Unknown device');
  assert.equal(describeUserAgent('', 'android'), 'Classroom app on Android');
});

test('the summary after a lesson', () => {
  assert.equal(summarizeHeld([]), null);
  const one = summarizeHeld([{ type: 'message', from: 'Anna', conversationId: 'c1' }]);
  assert.equal(one.body, '1 new message from Anna');
  assert.equal(one.url, '/messages/c1');

  const many = summarizeHeld([
    { type: 'message', from: 'Anna', conversationId: 'c1' },
    { type: 'message', from: 'Ben', conversationId: 'c2' },
    { type: 'mention', from: 'Cleo', channelId: 'x' },
  ]);
  assert.equal(many.body, '2 new messages in 3 chats from Anna, Ben and 1 other, 1 mention');
  assert.equal(many.url, '/messages');
  assert.equal(many.count, 3);
});

test('field paths name what changed, never the values', () => {
  assert.deepEqual(fieldPaths({ lesson: { joinCamera: 'off' }, digest: 'weekly' }), ['lesson.joinCamera', 'digest']);
  assert.deepEqual(fieldPaths({ links: [{ url: 'x' }] }), ['links']);
  assert.deepEqual(fieldPaths({}), []);
});
__PB_EOF__
echo "wrote server/test/settings/notifications.check.mjs"

mkdir -p packages/core-client/src/api
cat > packages/core-client/src/api/accountApi.ts <<'__PB_EOF__'
/**
 * Account API  (Settings, Phase B)
 *
 * Notifications, push registration for this browser, muted chats, signed-in
 * devices and the account's history. Paths are the server's
 * (server/src/routes/account.routes.js, mounted under /account).
 *
 * Responses are validated loosely (passthrough): the server fills in every
 * default, so the client never has to know one.
 */

import { z } from 'zod';
import type { HttpClient } from '../http/httpClient.js';

const ChannelFlagsSchema = z.object({ inApp: z.boolean(), push: z.boolean(), email: z.boolean() });

export const NotificationSettingsSchema = z
  .object({
    categories: z.record(z.string(), ChannelFlagsSchema),
    quietHours: z
      .object({
        enabled: z.boolean(),
        start: z.string(),
        end: z.string(),
        allowLessonReminders: z.boolean(),
      })
      .passthrough(),
    focusDuringLessons: z.boolean(),
    showPreviews: z.boolean(),
    digest: z.enum(['off', 'daily', 'weekly']),
  })
  .passthrough();
export type NotificationSettings = z.infer<typeof NotificationSettingsSchema>;

export const NotificationsViewSchema = z
  .object({
    settings: NotificationSettingsSchema,
    timeZone: z.string().default('UTC'),
    quietNow: z.boolean().default(false),
    push: z
      .object({
        configured: z.boolean().default(false),
        publicKey: z.string().nullable().default(null),
        devices: z.number().default(0),
      })
      .passthrough(),
    email: z
      .object({ address: z.string().nullable().default(null), suppressed: z.boolean().default(false) })
      .passthrough(),
  })
  .passthrough();
export type NotificationsView = z.infer<typeof NotificationsViewSchema>;

export const TestResultSchema = z
  .object({ channel: z.string(), delivered: z.number(), detail: z.string() })
  .passthrough();
export type TestResult = z.infer<typeof TestResultSchema>;

const PushStatusSchema = z.object({ registered: z.boolean(), devices: z.number() }).passthrough();

export const MutedChatSchema = z
  .object({
    kind: z.enum(['conversation', 'channel']),
    id: z.string(),
    title: z.string(),
    mutedUntil: z.string().nullable().default(null),
  })
  .passthrough();
export type MutedChat = z.infer<typeof MutedChatSchema>;
const MutedChatListSchema = z.object({ items: z.array(MutedChatSchema) });

export const DeviceSessionSchema = z
  .object({
    sessionId: z.string(),
    label: z.string(),
    platform: z.string().nullable().default(null),
    ip: z.string().nullable().default(null),
    createdAt: z.string().nullable().default(null),
    lastActiveAt: z.string().nullable().default(null),
    current: z.boolean().default(false),
  })
  .passthrough();
export type DeviceSession = z.infer<typeof DeviceSessionSchema>;
const DeviceSessionListSchema = z.object({ items: z.array(DeviceSessionSchema) });

export const HistoryEntrySchema = z
  .object({
    id: z.string(),
    action: z.string(),
    at: z.string().nullable().default(null),
    device: z.string().nullable().default(null),
    ip: z.string().nullable().default(null),
    section: z.string().nullable().default(null),
    fields: z.array(z.string()).default([]),
    detail: z.string().nullable().default(null),
    count: z.number().nullable().default(null),
  })
  .passthrough();
export type HistoryEntry = z.infer<typeof HistoryEntrySchema>;
const HistoryPageSchema = z.object({
  items: z.array(HistoryEntrySchema),
  nextCursor: z.string().nullable().default(null),
});
export type HistoryPage = z.infer<typeof HistoryPageSchema>;

export type NotificationChannel = 'inApp' | 'push' | 'email';

export interface PushSubscriptionInput {
  endpoint: string;
  keys: { p256dh: string; auth: string };
}

export interface AccountApi {
  getNotifications(signal?: AbortSignal): Promise<NotificationsView>;
  /** Any part of the settings, any subset of its keys; returns the full view. */
  updateNotifications(patch: Record<string, unknown>): Promise<NotificationsView>;
  sendTestNotification(channel: NotificationChannel): Promise<TestResult>;
  registerPush(subscription: PushSubscriptionInput): Promise<z.infer<typeof PushStatusSchema>>;
  unregisterPush(endpoint: string): Promise<z.infer<typeof PushStatusSchema>>;
  listMutedChats(signal?: AbortSignal): Promise<z.infer<typeof MutedChatListSchema>>;
  unmuteChat(chat: { kind: MutedChat['kind']; id: string }): Promise<unknown>;
  muteChat(chat: { kind: MutedChat['kind']; id: string; until?: string | null }): Promise<unknown>;
  listSessions(signal?: AbortSignal): Promise<z.infer<typeof DeviceSessionListSchema>>;
  signOutSession(sessionId: string): Promise<void>;
  signOutOtherSessions(): Promise<{ revoked: number }>;
  loginHistory(query?: { cursor?: string | null; limit?: number }, signal?: AbortSignal): Promise<HistoryPage>;
  activity(query?: { cursor?: string | null; limit?: number }, signal?: AbortSignal): Promise<HistoryPage>;
}

const page = (query: { cursor?: string | null; limit?: number } = {}) => ({
  cursor: query.cursor ?? undefined,
  limit: query.limit,
});

export const createAccountApi = (http: HttpClient): AccountApi => ({
  getNotifications: (signal) => http.get('/account/notifications', { schema: NotificationsViewSchema, signal }),

  updateNotifications: (patch) =>
    http.patch('/account/notifications', patch, { schema: NotificationsViewSchema }),

  sendTestNotification: (channel) =>
    http.post('/account/notifications/test', { channel }, { schema: TestResultSchema }),

  registerPush: (subscription) =>
    http.put('/account/push-subscriptions', subscription, { schema: PushStatusSchema }),

  unregisterPush: (endpoint) =>
    http.post('/account/push-subscriptions/remove', { endpoint }, { schema: PushStatusSchema }),

  listMutedChats: (signal) => http.get('/account/muted-chats', { schema: MutedChatListSchema, signal }),

  unmuteChat: (chat) =>
    http.post(`/account/muted-chats/${chat.kind}/${encodeURIComponent(chat.id)}/unmute`, {}),

  muteChat: (chat) =>
    http.post(`/account/muted-chats/${chat.kind}/${encodeURIComponent(chat.id)}/mute`, {
      until: chat.until ?? null,
    }),

  listSessions: (signal) => http.get('/account/sessions', { schema: DeviceSessionListSchema, signal }),

  signOutSession: async (sessionId) => {
    await http.delete(`/account/sessions/${encodeURIComponent(sessionId)}`);
  },

  signOutOtherSessions: () =>
    http.post('/account/sessions/sign-out-others', {}, { schema: z.object({ revoked: z.number() }) }),

  loginHistory: (query = {}, signal) =>
    http.get('/account/login-history', { schema: HistoryPageSchema, query: page(query), signal }),

  activity: (query = {}, signal) =>
    http.get('/account/activity', { schema: HistoryPageSchema, query: page(query), signal }),
});
__PB_EOF__
echo "wrote packages/core-client/src/api/accountApi.ts"

mkdir -p apps/web/public
cat > apps/web/public/sw.js <<'__PB_EOF__'
/* Classroom service worker  (Settings, Phase B)
 *
 * Only for push notifications: it shows what the server sends and opens the
 * right page when a notification is clicked. It does not cache anything, so
 * it can never serve a stale version of the app.
 *
 * Payload (server/src/notifications/delivery.js):
 *   { title, body, url, tag, kind }
 */

self.addEventListener('install', () => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('push', (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch {
    data = { title: 'Classroom', body: event.data ? event.data.text() : '' };
  }

  const title = data.title || 'Classroom';
  const options = {
    body: data.body || '',
    tag: data.tag || undefined,
    // A newer notification with the same tag replaces the old one, with a sound.
    renotify: Boolean(data.tag),
    data: { url: data.url || '/', kind: data.kind || null },
    icon: '/favicon.ico',
    badge: '/favicon.ico',
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const target = new URL(event.notification.data?.url || '/', self.location.origin).href;

  event.waitUntil(
    (async () => {
      const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
      // An open tab of the app is reused rather than opening another one.
      for (const client of windows) {
        if (new URL(client.url).origin !== self.location.origin) continue;
        await client.focus();
        if ('navigate' in client) {
          try {
            await client.navigate(target);
          } catch {
            // Tabs the worker does not control cannot be navigated; focus is enough.
          }
        }
        return;
      }
      await self.clients.openWindow(target);
    })(),
  );
});

/* The browser replaced the subscription (keys rotated): tell the open tabs,
   which register the new one with the server. */
self.addEventListener('pushsubscriptionchange', (event) => {
  event.waitUntil(
    (async () => {
      const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
      for (const client of windows) client.postMessage({ type: 'push-subscription-changed' });
    })(),
  );
});
__PB_EOF__
echo "wrote apps/web/public/sw.js"

mkdir -p apps/web/src/lib
cat > apps/web/src/lib/pushClient.js <<'__PB_EOF__'
/**
 * Browser push for this device  (Settings, Phase B)
 *
 * Registers the service worker (public/sw.js), asks the browser for
 * permission, subscribes with the server's VAPID public key and hands the
 * subscription to the API, which binds it to this sign-in session. Signing
 * this device out — here or from another device — removes it on the server.
 */

const SW_URL = '/sw.js';

export const pushSupported = () =>
  typeof window !== 'undefined' &&
  'serviceWorker' in navigator &&
  'PushManager' in window &&
  'Notification' in window;

/** 'granted' · 'denied' · 'default' · 'unsupported' */
export const pushPermission = () => (pushSupported() ? Notification.permission : 'unsupported');

const base64UrlToBytes = (value) => {
  const padding = '='.repeat((4 - (value.length % 4)) % 4);
  const raw = atob((value + padding).replace(/-/g, '+').replace(/_/g, '/'));
  return Uint8Array.from(raw, (char) => char.charCodeAt(0));
};

const registration = async () => {
  const existing = await navigator.serviceWorker.getRegistration(SW_URL);
  return existing ?? navigator.serviceWorker.register(SW_URL, { scope: '/' });
};

/** The current subscription of this browser, or null. Never prompts. */
export const currentSubscription = async () => {
  if (!pushSupported()) return null;
  const reg = await navigator.serviceWorker.getRegistration(SW_URL);
  return reg ? reg.pushManager.getSubscription() : null;
};

const toInput = (subscription) => {
  const json = subscription.toJSON();
  return { endpoint: json.endpoint, keys: { p256dh: json.keys.p256dh, auth: json.keys.auth } };
};

/**
 * Turns push on for this browser. Must be called from a click: browsers only
 * show the permission prompt in response to a user action.
 * @returns {Promise<{ ok: boolean, reason?: string }>}
 */
export const enablePush = async ({ account, publicKey }) => {
  if (!pushSupported()) return { ok: false, reason: 'This browser cannot receive push notifications.' };
  if (!publicKey) return { ok: false, reason: 'Push is not set up on the server.' };

  const permission = await Notification.requestPermission();
  if (permission !== 'granted') {
    return {
      ok: false,
      reason:
        permission === 'denied'
          ? 'Notifications are blocked for this site. Allow them in the address bar, then try again.'
          : 'Permission was not given.',
    };
  }

  const reg = await registration();
  await navigator.serviceWorker.ready;
  let subscription = await reg.pushManager.getSubscription();

  // A subscription made with other keys (the server's keys changed) cannot be used.
  const key = base64UrlToBytes(publicKey);
  const current = subscription?.options?.applicationServerKey;
  if (subscription && current && !sameBytes(new Uint8Array(current), key)) {
    await subscription.unsubscribe().catch(() => undefined);
    subscription = null;
  }

  subscription ??= await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: key });
  await account.registerPush(toInput(subscription));
  return { ok: true };
};

const sameBytes = (a, b) => a.length === b.length && a.every((value, index) => value === b[index]);

/** Turns push off for this browser only. */
export const disablePush = async ({ account }) => {
  const subscription = await currentSubscription();
  if (!subscription) return { ok: true };
  await account.unregisterPush(subscription.endpoint).catch(() => undefined);
  await subscription.unsubscribe().catch(() => undefined);
  return { ok: true };
};

/**
 * Keeps the server's copy in step with the browser: after the service worker
 * reports a rotated subscription, or on start when permission is still given.
 */
export const resyncPush = async ({ account }) => {
  const subscription = await currentSubscription().catch(() => null);
  if (subscription && pushPermission() === 'granted') {
    await account.registerPush(toInput(subscription)).catch(() => undefined);
  }
};

export const onServiceWorkerMessage = (handler) => {
  if (!pushSupported()) return () => undefined;
  const listener = (event) => handler(event.data ?? {});
  navigator.serviceWorker.addEventListener('message', listener);
  return () => navigator.serviceWorker.removeEventListener('message', listener);
};
__PB_EOF__
echo "wrote apps/web/src/lib/pushClient.js"

mkdir -p apps/web/src/lib
cat > apps/web/src/lib/userEvents.js <<'__PB_EOF__'
/**
 * Live events for the signed-in person  (Settings, Phase B)
 *
 * The server sends per-person events (server/src/realtime/userEvents.js) on
 * the app's socket:
 *
 *   notification:new    a bell entry arrived        { notification, unread }
 *   settings:changed    changed on another device   { section, fields }
 *   session:revoked     this device was signed out  { reason }
 *
 * The socket object the core exposes has had more than one shape; this finds
 * the one that can listen and returns an unsubscribe function. Without a
 * socket it returns a no-op: the pages still work, they just refresh on focus
 * instead of live.
 */

const candidatesOf = (core) => {
  const socket = core?.socket ?? core?.socketClient ?? null;
  const list = [
    core?.chatSocket,
    core?.sockets?.chat,
    typeof socket?.namespace === 'function' ? safe(() => socket.namespace('/chat')) : null,
    typeof socket?.of === 'function' ? safe(() => socket.of('/chat')) : null,
    typeof socket?.get === 'function' ? safe(() => socket.get('/chat')) : null,
    socket?.chat,
    socket,
  ];
  return list.filter((candidate) => candidate && typeof candidate.on === 'function');
};

function safe(fn) {
  try {
    return fn();
  } catch {
    return null;
  }
}

/** Listens on every socket that can; the server delivers on /chat and /. */
export const onUserEvent = (core, event, handler) => {
  const targets = [...new Set(candidatesOf(core))];
  const offs = targets.map((target) => {
    const result = target.on(event, handler);
    if (typeof result === 'function') return result;
    return () => {
      if (typeof target.off === 'function') target.off(event, handler);
      else if (typeof target.removeListener === 'function') target.removeListener(event, handler);
    };
  });
  return () => offs.forEach((off) => safe(off));
};

export const liveEventsAvailable = (core) => candidatesOf(core).length > 0;
__PB_EOF__
echo "wrote apps/web/src/lib/userEvents.js"

mkdir -p apps/web/src/pages
cat > apps/web/src/pages/AppLayout.jsx <<'__PB_EOF__'
import { useEffect, useMemo, useRef } from 'react';
import { NavLink, Outlet, useNavigate } from 'react-router-dom';
import { createAccountApi, createProfileApi, useCore } from '@classroom/core-client';
import ErrorBoundary from '../components/system/ErrorBoundary.jsx';
import NotificationToasts from '../components/system/NotificationToasts.jsx';
import { cacheLocale, cachePreferences } from '../lib/preferences.js';
import { onServiceWorkerMessage, resyncPush } from '../lib/pushClient.js';
import { onUserEvent } from '../lib/userEvents.js';

/**
 * The shell every page except the classroom renders inside.
 *
 * The boundary sits around <Outlet/> rather than around the whole layout, so a
 * page that throws loses the page and keeps the navigation — a user who can
 * still click away from a broken screen is not stuck.
 *
 * Phase B adds three invisible helpers: SessionWatch (a device signed out
 * from elsewhere goes back to the sign-in page), NotificationToasts (a new
 * notification shows on screen) and live preference sync.
 */
export default function AppLayout() {
  return (
    <div className="app">
      <PreferencesSync />
      <SessionWatch />
      <header className="app__bar">
        <span className="app__brand">Classroom</span>
        <nav className="app__nav">
          <NavLink to="/" end>
            Dashboard
          </NavLink>
          <NavLink to="/community">Community</NavLink>
          <NavLink to="/messages">Messages</NavLink>
          <NavLink to="/media">Media</NavLink>
          <NavLink to="/settings">Settings</NavLink>
        </nav>
      </header>

      <main className="app__content">
        <ErrorBoundary area="page">
          <Outlet />
        </ErrorBoundary>
      </main>

      <NotificationToasts />
    </div>
  );
}

/**
 * Brings this device's copy of the account preferences up to date once per
 * sign-in and whenever they change on another device, so a change made there
 * (font size, how lessons start) applies here too. Also keeps this browser's
 * push registration current. Renders nothing; a failure leaves the cached
 * copy in use.
 */
function PreferencesSync() {
  const core = useCore();
  const { http, status } = core;
  const profiles = useMemo(() => createProfileApi(http), [http]);
  const account = useMemo(() => createAccountApi(http), [http]);

  useEffect(() => {
    if (status !== 'authenticated') return undefined;
    let cancelled = false;

    const sync = () =>
      Promise.all([profiles.getPreferences(), profiles.getOwn()])
        .then(([preferences, own]) => {
          if (cancelled) return;
          cachePreferences(preferences);
          cacheLocale(own.locale);
        })
        .catch(() => undefined);

    sync();
    resyncPush({ account }).catch(() => undefined);

    let timer = null;
    const offLive = onUserEvent(core, 'settings:changed', (payload) => {
      if (payload?.section && !['preferences', 'profile'].includes(payload.section)) return;
      window.clearTimeout(timer);
      timer = window.setTimeout(sync, 150);
    });
    const offWorker = onServiceWorkerMessage((message) => {
      if (message.type === 'push-subscription-changed') resyncPush({ account }).catch(() => undefined);
    });

    return () => {
      cancelled = true;
      window.clearTimeout(timer);
      offLive();
      offWorker();
    };
  }, [core, profiles, account, status]);

  return null;
}

/** Core states that mean nobody is signed in (a refresh in progress is not one of them). */
const SIGNED_OUT = new Set(['anonymous', 'unauthenticated', 'signed-out', 'signedOut', 'logged-out']);

/**
 * This device was signed out — from Settings on another device, or because
 * its session expired. The server tells open tabs (session:revoked); the core
 * learns it at the latest on its next request. Either way: back to sign-in.
 */
function SessionWatch() {
  const core = useCore();
  const { status } = core;
  const navigate = useNavigate();
  const previous = useRef(status);

  useEffect(() => {
    if (previous.current === 'authenticated' && SIGNED_OUT.has(status)) {
      navigate('/login', { replace: true, state: { reason: 'signed-out' } });
    }
    previous.current = status;
  }, [status, navigate]);

  useEffect(() => {
    if (status !== 'authenticated') return undefined;
    return onUserEvent(core, 'session:revoked', () => {
      const signOut = core.signOut ?? core.logout ?? core.auth?.signOut ?? core.auth?.logout;
      Promise.resolve(typeof signOut === 'function' ? signOut() : undefined)
        .catch(() => undefined)
        .finally(() => navigate('/login', { replace: true, state: { reason: 'signed-out-remotely' } }));
    });
  }, [core, status, navigate]);

  return null;
}
__PB_EOF__
echo "wrote apps/web/src/pages/AppLayout.jsx"

mkdir -p apps/web/src/pages
cat > apps/web/src/pages/SettingsPage.jsx <<'__PB_EOF__'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { createAccountApi, createProfileApi, useCore } from '@classroom/core-client';

import ProfileSettings from '../components/Settings/ProfileSettings.jsx';
import PrivacySettings from '../components/Settings/PrivacySettings.jsx';
import RegionSettings from '../components/Settings/RegionSettings.jsx';
import LessonSettings from '../components/Settings/LessonSettings.jsx';
import AppearanceSettings from '../components/Settings/AppearanceSettings.jsx';
import TeachingSettings from '../components/Settings/TeachingSettings.jsx';
import NotificationSettings from '../components/Settings/NotificationSettings.jsx';
import SecuritySettings from '../components/Settings/SecuritySettings.jsx';
import ActivitySettings from '../components/Settings/ActivitySettings.jsx';
import { searchSettings } from '../components/Settings/settingsIndex.js';
import { mergeDeep, pickDeep } from '../components/Settings/notificationsModel.js';
import { cacheLocale, cachePreferences } from '../lib/preferences.js';
import { liveEventsAvailable, onUserEvent } from '../lib/userEvents.js';
import '../components/Settings/settings.css';

/**
 * Settings  (Phase A + B)
 *
 * One tab per topic, each with its own address (/settings/<tab>), a search
 * across every setting, and no Save button: every change is saved the moment
 * it is made and can be undone from the notice that confirms it.
 *
 *   profile        how others see you, and a preview of exactly that
 *   privacy        check-up, private messages, visibility, blocked people
 *   notifications  type × channel, push, tests, quiet hours, focus, muted chats
 *   security       signed-in devices, sign out elsewhere, sign-in history
 *   activity       recent changes to your settings
 *   region         language, time zone, date and time format
 *   lessons        how you join, sound processing, device test
 *   appearance     text size, motion
 *   teaching       how your lessons start (teachers and owners only)
 *
 * A change made on another device arrives live (settings:changed) and the
 * page reloads what it shows; without a live connection it reloads when the
 * window regains focus.
 */

const ALL_TABS = [
  { id: 'profile', label: 'Profile' },
  { id: 'privacy', label: 'Privacy' },
  { id: 'notifications', label: 'Notifications' },
  { id: 'security', label: 'Sign-in & devices' },
  { id: 'activity', label: 'Recent changes' },
  { id: 'region', label: 'Language & region' },
  { id: 'lessons', label: 'Lessons' },
  { id: 'appearance', label: 'Appearance' },
  { id: 'teaching', label: 'Teaching', roles: ['teacher', 'owner'] },
];

/** An own save echoes back as settings:changed; ignore echoes this soon after one. */
const OWN_ECHO_MS = 2_000;

const pick = (source, keys) => Object.fromEntries(keys.map((key) => [key, source?.[key] ?? null]));

export default function SettingsPage() {
  const core = useCore();
  const { http } = core;
  const profiles = useMemo(() => createProfileApi(http), [http]);
  const account = useMemo(() => createAccountApi(http), [http]);
  const { tab: tabParam } = useParams();
  const navigate = useNavigate();

  const [own, setOwn] = useState(null);
  const [privacy, setPrivacy] = useState(null);
  const [preferences, setPreferences] = useState(null);
  const [blocks, setBlocks] = useState([]);
  const [notifications, setNotifications] = useState(null);
  const [notificationsError, setNotificationsError] = useState(false);
  const [loadError, setLoadError] = useState(false);
  const [notice, setNotice] = useState(null);
  const [query, setQuery] = useState('');
  const [highlight, setHighlight] = useState(null);
  const [reloadKey, setReloadKey] = useState(0);
  const noticeTimer = useRef(null);
  const lastOwnSave = useRef(0);

  const loadNotifications = useCallback(async () => {
    try {
      setNotifications(await account.getNotifications());
      setNotificationsError(false);
    } catch {
      setNotificationsError(true);
    }
  }, [account]);

  const load = useCallback(async () => {
    setLoadError(false);
    try {
      const [ownProfile, ownPrivacy, ownPreferences, ownBlocks] = await Promise.all([
        profiles.getOwn(),
        profiles.getPrivacy(),
        profiles.getPreferences(),
        profiles.listBlocks({ limit: 100 }),
      ]);
      setOwn(ownProfile);
      setPrivacy(ownPrivacy);
      setPreferences(cachePreferences(ownPreferences));
      setBlocks(ownBlocks.items);
      cacheLocale(ownProfile.locale);
    } catch {
      setLoadError(true);
    }
    // Separate: a problem with notifications must not hide the other tabs.
    await loadNotifications();
  }, [profiles, loadNotifications]);

  useEffect(() => {
    load();
    return () => window.clearTimeout(noticeTimer.current);
  }, [load]);

  /* ---- changes made elsewhere ---- */

  useEffect(() => {
    const refresh = () => {
      if (Date.now() - lastOwnSave.current < OWN_ECHO_MS) return;
      load();
      setReloadKey((key) => key + 1);
    };

    if (liveEventsAvailable(core)) {
      let timer = null;
      const off = onUserEvent(core, 'settings:changed', () => {
        // The event may arrive on more than one socket: one reload is enough.
        window.clearTimeout(timer);
        timer = window.setTimeout(refresh, 150);
      });
      return () => {
        window.clearTimeout(timer);
        off();
      };
    }

    const onFocus = () => refresh();
    window.addEventListener('focus', onFocus);
    return () => window.removeEventListener('focus', onFocus);
  }, [core, load]);

  const tabs = useMemo(
    () => ALL_TABS.filter((tab) => !tab.roles || tab.roles.includes(own?.role)),
    [own?.role],
  );
  const tab = tabs.some((t) => t.id === tabParam) ? tabParam : 'profile';

  /* ---- saving, with undo ---- */

  const announce = useCallback((text, undo = null, error = false) => {
    window.clearTimeout(noticeTimer.current);
    setNotice({ text, undo, error });
    noticeTimer.current = window.setTimeout(() => setNotice(null), undo ? 8_000 : 4_000);
  }, []);

  const failed = useCallback(
    (cause) => {
      announce(cause?.detail ?? cause?.message ?? 'That change was not saved. Try again.', null, true);
      throw cause;
    },
    [announce],
  );

  const markOwnSave = () => {
    lastOwnSave.current = Date.now();
  };

  const saveProfile = useCallback(
    async (patch, label, { undoable = true } = {}) => {
      const before = pick(own, Object.keys(patch));
      markOwnSave();
      try {
        const next = await profiles.update(patch);
        setOwn(next);
        if (patch.locale) cacheLocale(next.locale);
        announce(
          `${label} saved.`,
          undoable ? () => saveProfile(before, label, { undoable: false }).then(() => announce(`${label} restored.`)) : null,
        );
      } catch (cause) {
        failed(cause);
      }
    },
    [own, profiles, announce, failed],
  );

  const savePrivacy = useCallback(
    async (patch, label, { undoable = true } = {}) => {
      const before = pick(privacy, Object.keys(patch));
      setPrivacy((current) => ({ ...current, ...patch }));
      markOwnSave();
      try {
        setPrivacy(await profiles.updatePrivacy(patch));
        announce(
          `${label} saved.`,
          undoable ? () => savePrivacy(before, label, { undoable: false }).then(() => announce(`${label} restored.`)) : null,
        );
      } catch (cause) {
        setPrivacy((current) => ({ ...current, ...before }));
        failed(cause);
      }
    },
    [privacy, profiles, announce, failed],
  );

  const savePreferences = useCallback(
    async (section, patch, label, { undoable = true } = {}) => {
      const before = pick(preferences?.[section], Object.keys(patch));
      setPreferences((current) => ({ ...current, [section]: { ...current[section], ...patch } }));
      markOwnSave();
      try {
        const next = await profiles.updatePreferences({ [section]: patch });
        setPreferences(cachePreferences(next));
        announce(
          `${label} saved.`,
          undoable
            ? () => savePreferences(section, before, label, { undoable: false }).then(() => announce(`${label} restored.`))
            : null,
        );
      } catch (cause) {
        setPreferences((current) => ({ ...current, [section]: { ...current[section], ...before } }));
        failed(cause);
      }
    },
    [preferences, profiles, announce, failed],
  );

  const saveNotifications = useCallback(
    async (patch, label, { undoable = true } = {}) => {
      const before = pickDeep(notifications?.settings, patch);
      setNotifications((current) => ({ ...current, settings: mergeDeep(current.settings, patch) }));
      markOwnSave();
      try {
        setNotifications(await account.updateNotifications(patch));
        announce(
          `${label} saved.`,
          undoable
            ? () => saveNotifications(before, label, { undoable: false }).then(() => announce(`${label} restored.`))
            : null,
        );
      } catch (cause) {
        setNotifications((current) => ({ ...current, settings: mergeDeep(current.settings, before) }));
        failed(cause);
      }
    },
    [notifications, account, announce, failed],
  );

  const unblock = useCallback(
    async (block) => {
      try {
        await profiles.unblock(block.blockedUserId);
        setBlocks((current) => current.filter((b) => b.blockedUserId !== block.blockedUserId));
        announce(`${block.profile.displayName} is no longer blocked.`, async () => {
          await profiles.block({ userId: block.blockedUserId });
          setBlocks((current) => [block, ...current]);
          announce(`${block.profile.displayName} is blocked again.`);
        });
      } catch (cause) {
        announce(cause?.detail ?? 'That person could not be unblocked.', null, true);
      }
    },
    [profiles, announce],
  );

  /* ---- navigation and search ---- */

  const jumpTo = useCallback(
    (tabId, anchor) => {
      setQuery('');
      navigate(`/settings/${tabId}`);
      setHighlight(anchor);
    },
    [navigate],
  );

  useEffect(() => {
    if (!highlight) return undefined;
    const frame = requestAnimationFrame(() => {
      const el = document.getElementById(`setting-${highlight}`);
      el?.scrollIntoView({ behavior: 'smooth', block: 'center' });
      el?.classList.add('st-flash');
    });
    const timer = window.setTimeout(() => {
      document.getElementById(`setting-${highlight}`)?.classList.remove('st-flash');
      setHighlight(null);
    }, 1_600);
    return () => {
      cancelAnimationFrame(frame);
      window.clearTimeout(timer);
    };
  }, [highlight, tab]);

  const results = useMemo(() => searchSettings(query, tabs), [query, tabs]);

  /* ---- render ---- */

  if (loadError) {
    return (
      <section className="page st-page">
        <h1>Settings</h1>
        <p className="st-error">Your settings could not be loaded.</p>
        <button type="button" className="btn" onClick={load}>
          Try again
        </button>
      </section>
    );
  }

  if (!own || !privacy || !preferences) {
    return (
      <section className="page st-page">
        <h1>Settings</h1>
        <p className="st-hint">Loading your settings…</p>
      </section>
    );
  }

  const tabProps = { own, privacy, preferences, blocks, saveProfile, savePrivacy, savePreferences, unblock };

  const notificationsTab = notifications ? (
    <NotificationSettings
      account={account}
      notifications={notifications}
      saveNotifications={saveNotifications}
      announce={announce}
      reloadNotifications={loadNotifications}
    />
  ) : notificationsError ? (
    <>
      <p className="st-error">Your notification settings could not be loaded.</p>
      <button type="button" className="btn" onClick={loadNotifications}>
        Try again
      </button>
    </>
  ) : (
    <p className="st-hint">Loading…</p>
  );

  return (
    <section className="page st-page">
      <header className="st-header">
        <h1>Settings</h1>
        <input
          className="st-search"
          type="search"
          placeholder="Search settings, e.g. microphone, push or devices"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          aria-label="Search settings"
        />
      </header>

      <div className="st-layout">
        <nav className="st-nav" aria-label="Settings sections">
          {tabs.map((t) => (
            <button
              key={t.id}
              type="button"
              className={t.id === tab && !query ? 'st-nav__item is-active' : 'st-nav__item'}
              aria-current={t.id === tab && !query ? 'page' : undefined}
              onClick={() => {
                setQuery('');
                navigate(`/settings/${t.id}`);
              }}
            >
              {t.label}
            </button>
          ))}
        </nav>

        <div className="st-content">
          {query.trim() ? (
            <div className="st-results" aria-live="polite">
              {results.length === 0 ? <p className="st-hint">No setting matches “{query}”.</p> : null}
              {results.map((entry) => (
                <button key={`${entry.tab}-${entry.anchor}`} type="button" className="st-result" onClick={() => jumpTo(entry.tab, entry.anchor)}>
                  <span className="st-result__label">{entry.label}</span>
                  <span className="st-hint">{tabs.find((t) => t.id === entry.tab)?.label}</span>
                </button>
              ))}
            </div>
          ) : (
            <>
              {tab === 'profile' && <ProfileSettings {...tabProps} />}
              {tab === 'privacy' && <PrivacySettings {...tabProps} onJump={(anchor) => jumpTo('privacy', anchor)} />}
              {tab === 'notifications' && notificationsTab}
              {tab === 'security' && <SecuritySettings account={account} announce={announce} reloadKey={reloadKey} />}
              {tab === 'activity' && <ActivitySettings account={account} onJump={jumpTo} reloadKey={reloadKey} />}
              {tab === 'region' && <RegionSettings {...tabProps} />}
              {tab === 'lessons' && <LessonSettings {...tabProps} />}
              {tab === 'appearance' && <AppearanceSettings {...tabProps} />}
              {tab === 'teaching' && <TeachingSettings {...tabProps} />}
            </>
          )}
        </div>
      </div>

      {notice ? (
        <div className={notice.error ? 'st-notice st-notice--error' : 'st-notice'} role="status" aria-live="polite">
          <span>{notice.text}</span>
          {notice.undo ? (
            <button
              type="button"
              className="st-notice__undo"
              onClick={() => {
                const undo = notice.undo;
                setNotice(null);
                undo().catch(() => undefined);
              }}
            >
              Undo
            </button>
          ) : null}
        </div>
      ) : null}
    </section>
  );
}
__PB_EOF__
echo "wrote apps/web/src/pages/SettingsPage.jsx"

mkdir -p apps/web/src/components/Settings
cat > apps/web/src/components/Settings/notificationsModel.js <<'__PB_EOF__'
/**
 * Pure helpers for Settings → Notifications, Sign-in & devices and Recent
 * changes (Settings, Phase B). No React, no network: tested in
 * __checks__/notificationsModel.check.mjs.
 */

export const CATEGORY_ROWS = Object.freeze([
  { id: 'directMessages', label: 'Private messages', hint: 'Chats with one person or a group.' },
  { id: 'mentions', label: 'Mentions', hint: 'Someone writes your @handle.' },
  {
    id: 'channelMessages',
    label: 'Chatroom messages',
    hint: 'Every message in the chatrooms you can read. Off by default — mentions still reach you.',
  },
  { id: 'lessonReminders', label: 'Lesson reminders', hint: 'A day before, and 10 minutes before a lesson.' },
  { id: 'coursework', label: 'Courses', hint: 'Recordings, assignments and course updates.' },
  { id: 'community', label: 'Community', hint: 'Replies to threads you follow, and other activity.' },
]);

export const CHANNEL_COLUMNS = Object.freeze([
  { id: 'inApp', label: 'In the app' },
  { id: 'push', label: 'Push' },
  { id: 'email', label: 'Email' },
]);

const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);

/** The values `source` holds at every path `patch` touches — the undo of that patch. */
export const pickDeep = (source, patch) => {
  if (!isObject(patch)) return source;
  const result = {};
  for (const [key, value] of Object.entries(patch)) {
    result[key] = isObject(value) ? pickDeep(source?.[key] ?? {}, value) : source?.[key];
  }
  return result;
};

/** A copy of `target` with `patch` merged in, object by object. */
export const mergeDeep = (target, patch) => {
  if (!isObject(patch)) return patch;
  const result = { ...(isObject(target) ? target : {}) };
  for (const [key, value] of Object.entries(patch)) {
    result[key] = isObject(value) ? mergeDeep(result[key], value) : value;
  }
  return result;
};

/** "for 3 more hours", "until Mon 14:00", "until you turn it back on". */
export const describeMuteEnd = (mutedUntil, now = new Date(), format = defaultFormat) => {
  if (!mutedUntil) return 'until you turn it back on';
  const end = new Date(mutedUntil);
  const minutes = Math.round((end.getTime() - now.getTime()) / 60_000);
  if (Number.isNaN(minutes) || minutes <= 0) return 'ending now';
  if (minutes < 60) return `for ${minutes} more ${minutes === 1 ? 'minute' : 'minutes'}`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `for ${hours} more ${hours === 1 ? 'hour' : 'hours'}`;
  return `until ${format(end)}`;
};

function defaultFormat(date) {
  return date.toISOString().slice(0, 16).replace('T', ' ');
}

/** "just now", "5 minutes ago", "3 hours ago", "2 days ago". */
export const relativeTime = (value, now = new Date()) => {
  if (!value) return '';
  const seconds = Math.round((now.getTime() - new Date(value).getTime()) / 1000);
  if (Number.isNaN(seconds)) return '';
  if (seconds < 60) return 'just now';
  const units = [
    [60 * 60 * 24, 'day'],
    [60 * 60, 'hour'],
    [60, 'minute'],
  ];
  for (const [size, name] of units) {
    const count = Math.floor(seconds / size);
    if (count >= 1) return `${count} ${name}${count === 1 ? '' : 's'} ago`;
  }
  return 'just now';
};

const SECTION_LABELS = {
  profile: 'Profile',
  privacy: 'Privacy',
  preferences: 'Preferences',
  notifications: 'Notifications',
};

const FIELD_LABELS = {
  displayName: 'display name',
  handle: 'handle',
  headline: 'headline',
  bio: 'about me',
  links: 'links',
  locale: 'language',
  timeZone: 'time zone',
  dmPolicy: 'who can message you',
  visibility: 'profile visibility',
  showPresence: 'online status',
  sendReadReceipts: 'read receipts',
  appearance: 'appearance',
  region: 'date and time format',
  lesson: 'lesson settings',
  roomDefaults: 'lesson defaults',
  categories: 'which notifications you get',
  quietHours: 'quiet hours',
  focusDuringLessons: 'focus during lessons',
  showPreviews: 'message previews',
  digest: 'community digest',
};

/** One line of Recent changes or Sign-in history, in plain words. */
export const describeHistoryEntry = (entry) => {
  switch (entry.action) {
    case 'auth.login.succeeded':
      return 'Signed in';
    case 'auth.login.failed':
      return entry.detail === 'too-many-attempts'
        ? 'Sign-in blocked after too many attempts'
        : 'Failed sign-in attempt (wrong password)';
    case 'auth.session.revoked':
      if ((entry.count ?? 1) > 1) return `Signed out ${entry.count} other devices`;
      return entry.detail ? `Signed out ${entry.detail}` : 'Signed out another device';
    case 'settings.changed': {
      const section = SECTION_LABELS[entry.section] ?? 'Settings';
      const tops = [...new Set((entry.fields ?? []).map((field) => field.split('.')[0]))];
      const names = tops.map((field) => FIELD_LABELS[field] ?? field);
      return names.length ? `${section}: changed ${names.join(', ')}` : `${section} changed`;
    }
    default:
      return entry.action;
  }
};

/** Quiet hours as words: "22:00 – 07:00 (overnight)". */
export const describeQuietHours = ({ start, end }) =>
  `${start} – ${end}${start > end ? ' (overnight)' : ''}`;
__PB_EOF__
echo "wrote apps/web/src/components/Settings/notificationsModel.js"

mkdir -p apps/web/src/components/Settings
cat > apps/web/src/components/Settings/NotificationSettings.jsx <<'__PB_EOF__'
import { useCallback, useEffect, useState } from 'react';
import { Choice, Section, Toggle } from './fields.jsx';
import { CATEGORY_ROWS, CHANNEL_COLUMNS, describeMuteEnd, describeQuietHours } from './notificationsModel.js';
import { disablePush, enablePush, currentSubscription, pushPermission, pushSupported } from '../../lib/pushClient.js';
import { formatDate, formatTime } from '../../lib/preferences.js';

/**
 * Notifications  (Settings, Phase B)
 *
 * Which notifications reach you, where and when. The rules that apply these
 * settings live on the server (server/src/settings/notifications.js); every
 * switch here is saved at once and can be undone from the notice.
 *
 *   matrix     type × channel: in the app, push, email
 *   push       this browser: on or off
 *   test       one test notification per channel, with what really happened
 *   quiet      no push in a window of your time zone
 *   focus      in a lesson: chat is held and summarised afterwards
 *   previews   push and email say who wrote, and only if on, what
 *   digest     community digest by email
 *   muted      every muted chat, with when the mute ends
 */

const formatEnd = (date) => `${formatDate(date)} ${formatTime(date)}`;

function Matrix({ settings, saveNotifications }) {
  return (
    <Section
      id="matrix"
      title="What you are notified about"
      hint="In the app means the bell and a notice on screen. Push reaches this computer or phone when the app is closed. Email goes to your account address."
    >
      <div className="st-matrix" role="table" aria-label="Notifications by type and channel">
        <div className="st-matrix__row st-matrix__head" role="row">
          <span role="columnheader">Type</span>
          {CHANNEL_COLUMNS.map((column) => (
            <span key={column.id} role="columnheader" className="st-matrix__cell">
              {column.label}
            </span>
          ))}
        </div>
        {CATEGORY_ROWS.map((row) => (
          <div key={row.id} className="st-matrix__row" role="row">
            <span role="rowheader" className="st-matrix__label">
              <span className="st-label">{row.label}</span>
              <span className="st-hint">{row.hint}</span>
            </span>
            {CHANNEL_COLUMNS.map((column) => {
              const checked = Boolean(settings.categories?.[row.id]?.[column.id]);
              return (
                <span key={column.id} role="cell" className="st-matrix__cell">
                  <input
                    type="checkbox"
                    className="st-check"
                    checked={checked}
                    aria-label={`${row.label}: ${column.label}`}
                    onChange={(event) =>
                      saveNotifications(
                        { categories: { [row.id]: { [column.id]: event.target.checked } } },
                        `${row.label} · ${column.label}`,
                      ).catch(() => undefined)
                    }
                  />
                </span>
              );
            })}
          </div>
        ))}
      </div>
      <p className="st-hint">
        Sign-in links, password resets and other messages about your account always reach you.
      </p>
    </Section>
  );
}

function PushOnThisDevice({ account, push, announce, reload }) {
  const [state, setState] = useState('checking');
  const [busy, setBusy] = useState(false);

  const check = useCallback(async () => {
    if (!pushSupported()) return setState('unsupported');
    if (pushPermission() === 'denied') return setState('blocked');
    const subscription = await currentSubscription().catch(() => null);
    setState(subscription && pushPermission() === 'granted' ? 'on' : 'off');
    return undefined;
  }, []);

  useEffect(() => {
    check();
  }, [check]);

  const turnOn = async () => {
    setBusy(true);
    try {
      const result = await enablePush({ account, publicKey: push.publicKey });
      if (!result.ok) announce(result.reason, null, true);
      else announce('Push is on for this browser.');
    } catch (cause) {
      announce(cause?.detail ?? cause?.message ?? 'Push could not be turned on.', null, true);
    } finally {
      setBusy(false);
      await check();
      reload();
    }
  };

  const turnOff = async () => {
    setBusy(true);
    try {
      await disablePush({ account });
      announce('Push is off for this browser.');
    } finally {
      setBusy(false);
      await check();
      reload();
    }
  };

  let text;
  if (!push.configured) text = 'Push is not set up on the server yet (the web push keys are missing).';
  else if (state === 'unsupported') text = 'This browser cannot receive push notifications.';
  else if (state === 'blocked') text = 'Notifications are blocked for this site. Allow them in the address bar to use push.';
  else if (state === 'on') text = 'This browser receives push notifications.';
  else if (state === 'off') text = 'This browser does not receive push notifications.';
  else text = 'Checking…';

  return (
    <Section
      id="push"
      title="Push on this device"
      hint={`Push is set per browser. ${push.devices === 1 ? 'One browser receives' : `${push.devices} browsers receive`} push on your account.`}
    >
      <div className="st-inline">
        <span>{text}</span>
        {push.configured && state === 'off' ? (
          <button type="button" className="btn" onClick={turnOn} disabled={busy}>
            Turn on push
          </button>
        ) : null}
        {push.configured && state === 'on' ? (
          <button type="button" className="btn btn--tiny" onClick={turnOff} disabled={busy}>
            Turn off for this browser
          </button>
        ) : null}
      </div>
    </Section>
  );
}

function TestNotifications({ account }) {
  const [results, setResults] = useState({});
  const [busy, setBusy] = useState(null);

  const send = async (channel) => {
    setBusy(channel);
    try {
      const result = await account.sendTestNotification(channel);
      setResults((current) => ({ ...current, [channel]: { ok: result.delivered > 0, text: result.detail } }));
    } catch (cause) {
      setResults((current) => ({
        ...current,
        [channel]: { ok: false, text: cause?.detail ?? cause?.message ?? 'The test could not be sent.' },
      }));
    } finally {
      setBusy(null);
    }
  };

  return (
    <Section id="test" title="Send a test notification" hint="Checks one channel end to end, with your real settings on the server.">
      {CHANNEL_COLUMNS.map((column) => (
        <div key={column.id} className="st-test">
          <button type="button" className="btn btn--tiny" disabled={busy !== null} onClick={() => send(column.id)}>
            {busy === column.id ? 'Sending…' : `Test ${column.label.toLowerCase()}`}
          </button>
          {results[column.id] ? (
            <span className={results[column.id].ok ? 'st-test__ok' : 'st-error'}>{results[column.id].text}</span>
          ) : null}
        </div>
      ))}
    </Section>
  );
}

function TimeInput({ label, value, onSave }) {
  const [draft, setDraft] = useState(value);
  useEffect(() => setDraft(value), [value]);
  return (
    <label className="st-label st-time">
      {label}
      <input
        type="time"
        className="st-input__field"
        value={draft}
        step={300}
        onChange={(event) => setDraft(event.target.value)}
        onBlur={() => {
          if (draft && draft !== value) onSave(draft).catch(() => setDraft(value));
        }}
      />
    </label>
  );
}

function QuietHours({ view, saveNotifications }) {
  const quiet = view.settings.quietHours;
  return (
    <Section
      id="quiet"
      title="Quiet hours"
      hint={`No push during these hours, in your time zone (${view.timeZone.replace(/_/g, ' ')}). Everything still arrives in the app.`}
    >
      <Toggle
        label="Use quiet hours"
        hint={quiet.enabled ? `${describeQuietHours(quiet)}${view.quietNow ? ' — quiet right now' : ''}` : null}
        checked={quiet.enabled}
        onChange={(value) => saveNotifications({ quietHours: { enabled: value } }, 'Quiet hours')}
      />
      <div className="st-inline">
        <TimeInput
          label="From"
          value={quiet.start}
          onSave={(value) => saveNotifications({ quietHours: { start: value } }, 'Quiet hours start')}
        />
        <TimeInput
          label="Until"
          value={quiet.end}
          onSave={(value) => saveNotifications({ quietHours: { end: value } }, 'Quiet hours end')}
        />
      </div>
      <Toggle
        label="Let a lesson that is about to start through"
        hint="The reminder 10 minutes before a lesson, and a lesson that starts now."
        checked={quiet.allowLessonReminders}
        onChange={(value) => saveNotifications({ quietHours: { allowLessonReminders: value } }, 'Lesson reminders in quiet hours')}
      />
    </Section>
  );
}

function MutedChats({ account, announce }) {
  const [items, setItems] = useState(null);

  const load = useCallback(async () => {
    try {
      setItems((await account.listMutedChats()).items);
    } catch {
      setItems([]);
    }
  }, [account]);

  useEffect(() => {
    load();
  }, [load]);

  const unmute = async (chat) => {
    try {
      await account.unmuteChat(chat);
      setItems((current) => current.filter((item) => !(item.kind === chat.kind && item.id === chat.id)));
      announce(`${chat.title} is no longer muted.`, async () => {
        await account.muteChat({ kind: chat.kind, id: chat.id, until: chat.mutedUntil });
        await load();
        announce(`${chat.title} is muted again.`);
      });
    } catch (cause) {
      announce(cause?.detail ?? 'That chat could not be unmuted.', null, true);
    }
  };

  return (
    <Section id="muted" title="Muted chats" hint="A muted chat still counts as unread, but never notifies you.">
      {items === null ? <p className="st-hint">Loading…</p> : null}
      {items?.length === 0 ? <p className="st-hint">No chat is muted.</p> : null}
      {items?.map((chat) => (
        <div key={`${chat.kind}-${chat.id}`} className="st-link">
          <span className="st-link__label">{chat.title}</span>
          <span className="st-link__url">Muted {describeMuteEnd(chat.mutedUntil, new Date(), formatEnd)}</span>
          <button type="button" className="btn btn--tiny" onClick={() => unmute(chat)}>
            Unmute
          </button>
        </div>
      ))}
    </Section>
  );
}

export default function NotificationSettings({ account, notifications, saveNotifications, announce, reloadNotifications }) {
  const { settings } = notifications;
  return (
    <>
      <Matrix settings={settings} saveNotifications={saveNotifications} />
      <PushOnThisDevice account={account} push={notifications.push} announce={announce} reload={reloadNotifications} />
      <TestNotifications account={account} />
      <QuietHours view={notifications} saveNotifications={saveNotifications} />

      <Section title="During lessons and on the lock screen">
        <Toggle
          id="focus"
          label="Focus during lessons"
          hint="While you are in a live lesson, private messages and mentions do not notify you. When you leave, you get one summary."
          checked={settings.focusDuringLessons}
          onChange={(value) => saveNotifications({ focusDuringLessons: value }, 'Focus during lessons')}
        />
        <Toggle
          id="previews"
          label="Show message text in push and email"
          hint="Off: they say who wrote to you, not what."
          checked={settings.showPreviews}
          onChange={(value) => saveNotifications({ showPreviews: value }, 'Message previews')}
        />
      </Section>

      <Section title="Community digest">
        <Choice
          id="digest"
          label="Unread community activity by email"
          value={settings.digest}
          options={[
            { value: 'daily', title: 'Daily' },
            { value: 'weekly', title: 'Weekly, on Mondays' },
            { value: 'off', title: 'Off' },
          ]}
          onChange={(value) => saveNotifications({ digest: value }, 'Community digest')}
        />
        {notifications.email.suppressed ? (
          <p className="st-error">Email to {notifications.email.address} is paused because an earlier message bounced.</p>
        ) : null}
      </Section>

      <MutedChats account={account} announce={announce} />
    </>
  );
}
__PB_EOF__
echo "wrote apps/web/src/components/Settings/NotificationSettings.jsx"

mkdir -p apps/web/src/components/Settings
cat > apps/web/src/components/Settings/SecuritySettings.jsx <<'__PB_EOF__'
import { useCallback, useEffect, useState } from 'react';
import { Section } from './fields.jsx';
import { describeHistoryEntry, relativeTime } from './notificationsModel.js';
import { formatDate, formatTime } from '../../lib/preferences.js';

/**
 * Sign-in & devices  (Settings, Phase B)
 *
 * Every device signed in to the account, this one marked, each with a way to
 * sign it out; "sign out everywhere else"; and the sign-ins and failed
 * attempts of the last weeks. A device that is signed out here stops at once:
 * its next request is refused and its open tabs return to the sign-in page.
 */

const when = (value) => (value ? `${formatDate(value)}, ${formatTime(value)}` : '');

export function HistoryList({ load, empty, reloadKey }) {
  const [items, setItems] = useState(null);
  const [cursor, setCursor] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(false);

  const fetchPage = useCallback(
    async (from = null) => {
      setBusy(true);
      setError(false);
      try {
        const page = await load({ cursor: from, limit: 20 });
        setItems((current) => (from ? [...(current ?? []), ...page.items] : page.items));
        setCursor(page.nextCursor);
      } catch {
        setError(true);
        setItems((current) => current ?? []);
      } finally {
        setBusy(false);
      }
    },
    [load],
  );

  useEffect(() => {
    fetchPage(null);
  }, [fetchPage, reloadKey]);

  if (items === null) return <p className="st-hint">Loading…</p>;

  return (
    <>
      {error ? <p className="st-error">The history could not be loaded.</p> : null}
      {items.length === 0 && !error ? <p className="st-hint">{empty}</p> : null}
      <ul className="st-history">
        {items.map((entry) => (
          <li key={entry.id} className={entry.action === 'auth.login.failed' ? 'st-history__item is-warning' : 'st-history__item'}>
            <span className="st-history__what">{describeHistoryEntry(entry)}</span>
            <span className="st-hint">
              {when(entry.at)}
              {entry.device ? ` · ${entry.device}` : ''}
              {entry.ip ? ` · ${entry.ip}` : ''}
            </span>
          </li>
        ))}
      </ul>
      {cursor ? (
        <button type="button" className="btn btn--tiny" disabled={busy} onClick={() => fetchPage(cursor)}>
          {busy ? 'Loading…' : 'Show older'}
        </button>
      ) : null}
    </>
  );
}

export default function SecuritySettings({ account, announce, reloadKey }) {
  const [sessions, setSessions] = useState(null);
  const [confirming, setConfirming] = useState(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      setSessions((await account.listSessions()).items);
    } catch {
      setSessions([]);
    }
  }, [account]);

  useEffect(() => {
    load();
  }, [load, reloadKey]);

  const signOut = async (session) => {
    setBusy(true);
    try {
      await account.signOutSession(session.sessionId);
      announce(`${session.label} was signed out.`);
      setConfirming(null);
      await load();
    } catch (cause) {
      announce(cause?.detail ?? 'That device could not be signed out.', null, true);
    } finally {
      setBusy(false);
    }
  };

  const signOutOthers = async () => {
    setBusy(true);
    try {
      const { revoked } = await account.signOutOtherSessions();
      announce(revoked === 0 ? 'No other device was signed in.' : `Signed out ${revoked} ${revoked === 1 ? 'device' : 'devices'}.`);
      setConfirming(null);
      await load();
    } catch (cause) {
      announce(cause?.detail ?? 'The other devices could not be signed out.', null, true);
    } finally {
      setBusy(false);
    }
  };

  const others = (sessions ?? []).filter((session) => !session.current);
  const loadHistory = useCallback((query) => account.loginHistory(query), [account]);

  return (
    <>
      <Section
        id="sessions"
        title="Where you are signed in"
        hint="Something you do not recognise? Sign it out, then change your password."
      >
        {sessions === null ? <p className="st-hint">Loading…</p> : null}
        {sessions?.map((session) => (
          <div key={session.sessionId} className="st-session">
            <div className="st-session__info">
              <span className="st-label">
                {session.label}
                {session.current ? <span className="st-badge">This device</span> : null}
              </span>
              <span className="st-hint">
                {session.current ? 'Active now' : `Last active ${relativeTime(session.lastActiveAt) || 'unknown'}`}
                {session.ip ? ` · ${session.ip}` : ''}
                {session.createdAt ? ` · signed in ${when(session.createdAt)}` : ''}
              </span>
            </div>
            {session.current ? null : confirming === session.sessionId ? (
              <span className="st-inline">
                <button type="button" className="btn btn--tiny btn--danger" disabled={busy} onClick={() => signOut(session)}>
                  Sign out
                </button>
                <button type="button" className="btn btn--tiny" onClick={() => setConfirming(null)}>
                  Cancel
                </button>
              </span>
            ) : (
              <button type="button" className="btn btn--tiny" onClick={() => setConfirming(session.sessionId)}>
                Sign out…
              </button>
            )}
          </div>
        ))}
      </Section>

      <Section id="sign-out-others" title="Sign out everywhere else" hint="Every device except this one has to sign in again.">
        {confirming === 'others' ? (
          <span className="st-inline">
            <span>Sign out {others.length} {others.length === 1 ? 'device' : 'devices'}?</span>
            <button type="button" className="btn btn--tiny btn--danger" disabled={busy} onClick={signOutOthers}>
              Sign them out
            </button>
            <button type="button" className="btn btn--tiny" onClick={() => setConfirming(null)}>
              Cancel
            </button>
          </span>
        ) : (
          <button type="button" className="btn" disabled={others.length === 0} onClick={() => setConfirming('others')}>
            Sign out all other devices
          </button>
        )}
      </Section>

      <Section id="login-history" title="Sign-in history" hint="Sign-ins and failed attempts on your account.">
        <HistoryList load={loadHistory} empty="No sign-ins recorded yet." reloadKey={reloadKey} />
      </Section>
    </>
  );
}
__PB_EOF__
echo "wrote apps/web/src/components/Settings/SecuritySettings.jsx"

mkdir -p apps/web/src/components/Settings
cat > apps/web/src/components/Settings/ActivitySettings.jsx <<'__PB_EOF__'
import { useCallback } from 'react';
import { Section } from './fields.jsx';
import { HistoryList } from './SecuritySettings.jsx';

/**
 * Recent changes  (Settings, Phase B)
 *
 * Every settings change on the account, with the device it was made on — so a
 * change nobody here made stands out. The names of the settings are shown,
 * never their values.
 */
export default function ActivitySettings({ account, onJump, reloadKey }) {
  const load = useCallback((query) => account.activity(query), [account]);
  return (
    <Section
      id="changes"
      title="Recent changes"
      hint="Changes to your settings and devices you signed out, newest first."
    >
      <HistoryList load={load} empty="Nothing has been changed yet." reloadKey={reloadKey} />
      <p className="st-hint">
        A change you did not make?{' '}
        <button type="button" className="st-linkbutton" onClick={() => onJump('security', 'sessions')}>
          Check where you are signed in
        </button>
        .
      </p>
    </Section>
  );
}
__PB_EOF__
echo "wrote apps/web/src/components/Settings/ActivitySettings.jsx"

mkdir -p apps/web/src/components/Settings/__checks__
cat > apps/web/src/components/Settings/__checks__/notificationsModel.check.mjs <<'__PB_EOF__'
// Settings, Phase B — pure helpers of the notification, device and history tabs.
// Run: node --test apps/web/src/components/Settings/__checks__/*.check.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  describeHistoryEntry,
  describeMuteEnd,
  describeQuietHours,
  mergeDeep,
  pickDeep,
  relativeTime,
} from '../notificationsModel.js';

test('pickDeep takes exactly what a patch touches — the undo', () => {
  const settings = { categories: { mentions: { push: true, email: false } }, digest: 'daily' };
  const patch = { categories: { mentions: { email: true } } };
  assert.deepEqual(pickDeep(settings, patch), { categories: { mentions: { email: false } } });
  assert.deepEqual(mergeDeep(mergeDeep(settings, patch), pickDeep(settings, patch)), settings);
});

test('mergeDeep leaves the original alone', () => {
  const original = { a: { b: 1, c: 2 } };
  const next = mergeDeep(original, { a: { b: 5 } });
  assert.deepEqual(next, { a: { b: 5, c: 2 } });
  assert.equal(original.a.b, 1);
});

test('mute end in words', () => {
  const now = new Date('2026-03-10T12:00:00Z');
  assert.equal(describeMuteEnd(null, now), 'until you turn it back on');
  assert.equal(describeMuteEnd('2026-03-10T12:30:00Z', now), 'for 30 more minutes');
  assert.equal(describeMuteEnd('2026-03-10T15:00:00Z', now), 'for 3 more hours');
  assert.equal(describeMuteEnd('2026-03-12T12:00:00Z', now, () => 'Thu'), 'until Thu');
  assert.equal(describeMuteEnd('2026-03-10T11:00:00Z', now), 'ending now');
});

test('relative time', () => {
  const now = new Date('2026-03-10T12:00:00Z');
  assert.equal(relativeTime('2026-03-10T11:59:30Z', now), 'just now');
  assert.equal(relativeTime('2026-03-10T11:55:00Z', now), '5 minutes ago');
  assert.equal(relativeTime('2026-03-08T12:00:00Z', now), '2 days ago');
});

test('history entries read as sentences', () => {
  assert.equal(describeHistoryEntry({ action: 'auth.login.succeeded' }), 'Signed in');
  assert.equal(describeHistoryEntry({ action: 'auth.login.failed', detail: 'too-many-attempts' }), 'Sign-in blocked after too many attempts');
  assert.equal(describeHistoryEntry({ action: 'auth.session.revoked', detail: 'Chrome on Windows', count: 1 }), 'Signed out Chrome on Windows');
  assert.equal(describeHistoryEntry({ action: 'auth.session.revoked', count: 3 }), 'Signed out 3 other devices');
  assert.equal(
    describeHistoryEntry({ action: 'settings.changed', section: 'notifications', fields: ['quietHours.start', 'quietHours.end', 'digest'] }),
    'Notifications: changed quiet hours, community digest',
  );
});

test('quiet hours in words', () => {
  assert.equal(describeQuietHours({ start: '22:00', end: '07:00' }), '22:00 – 07:00 (overnight)');
  assert.equal(describeQuietHours({ start: '12:00', end: '13:00' }), '12:00 – 13:00');
});
__PB_EOF__
echo "wrote apps/web/src/components/Settings/__checks__/notificationsModel.check.mjs"

mkdir -p apps/web/src/components/system
cat > apps/web/src/components/system/NotificationToasts.jsx <<'__PB_EOF__'
import { useEffect, useRef, useState } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { useCore } from '@classroom/core-client';
import { onUserEvent } from '../../lib/userEvents.js';
import './notifications.css';

/**
 * A new notification, on screen  (Settings, Phase B)
 *
 * The server only sends notification:new when the person's settings say "in
 * the app" for that type, so this component has no rules of its own. At most
 * three at a time, each for six seconds; the same notification arriving on
 * two sockets shows once. Messages for the chat that is open right now are
 * not shown — the chat itself already shows them.
 */

const SHOW_MS = 6_000;
const MAX = 3;

export default function NotificationToasts() {
  const core = useCore();
  const { status } = core;
  const navigate = useNavigate();
  const location = useLocation();
  const [toasts, setToasts] = useState([]);
  const seen = useRef(new Set());
  const path = useRef(location.pathname);
  path.current = location.pathname;

  useEffect(() => {
    if (status !== 'authenticated') return undefined;
    return onUserEvent(core, 'notification:new', (payload) => {
      const notification = payload?.notification;
      if (!notification?.notificationId || seen.current.has(notification.notificationId)) return;
      seen.current.add(notification.notificationId);
      if (notification.url && notification.url === path.current) return;

      setToasts((current) => [...current, notification].slice(-MAX));
      window.setTimeout(() => {
        setToasts((current) => current.filter((toast) => toast.notificationId !== notification.notificationId));
      }, SHOW_MS);
    });
  }, [core, status]);

  if (toasts.length === 0) return null;

  const dismiss = (id) => setToasts((current) => current.filter((toast) => toast.notificationId !== id));

  return (
    <div className="nt-stack" role="region" aria-label="Notifications" aria-live="polite">
      {toasts.map((toast) => (
        <div key={toast.notificationId} className="nt-toast">
          <button
            type="button"
            className="nt-toast__body"
            onClick={() => {
              dismiss(toast.notificationId);
              if (toast.url) navigate(toast.url);
            }}
          >
            <span className="nt-toast__title">{toast.title}</span>
            {toast.body ? <span className="nt-toast__text">{toast.body}</span> : null}
          </button>
          <button type="button" className="nt-toast__close" aria-label="Dismiss" onClick={() => dismiss(toast.notificationId)}>
            ×
          </button>
        </div>
      ))}
    </div>
  );
}
__PB_EOF__
echo "wrote apps/web/src/components/system/NotificationToasts.jsx"

mkdir -p apps/web/src/components/system
cat > apps/web/src/components/system/notifications.css <<'__PB_EOF__'
/* On-screen notifications — see components/system/NotificationToasts.jsx */

.nt-stack { position: fixed; inset-block-start: 16px; inset-inline-end: 16px; z-index: 60; display: flex; flex-direction: column; gap: 8px; width: min(360px, calc(100vw - 32px)); }
.nt-toast { display: flex; align-items: flex-start; gap: 4px; border-radius: 12px; background: var(--color-surface, #fff); color: inherit; border: 1px solid rgba(127,127,127,.25); box-shadow: 0 10px 28px rgba(0,0,0,.18); animation: nt-in .18s ease-out; }
.nt-toast__body { flex: 1 1 auto; min-width: 0; display: flex; flex-direction: column; gap: 2px; padding: 12px 4px 12px 14px; border: 0; background: transparent; color: inherit; font: inherit; text-align: start; cursor: pointer; }
.nt-toast__title { font-weight: 700; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.nt-toast__text { font-size: .9rem; opacity: .8; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
.nt-toast__close { border: 0; background: transparent; color: inherit; font-size: 1.2rem; line-height: 1; padding: 10px 12px; cursor: pointer; opacity: .6; }
.nt-toast__close:hover, .nt-toast__close:focus-visible { opacity: 1; }
@keyframes nt-in { from { opacity: 0; transform: translateY(-6px); } to { opacity: 1; transform: none; } }
@media (prefers-reduced-motion: reduce) { .nt-toast { animation: none; } }
__PB_EOF__
echo "wrote apps/web/src/components/system/notifications.css"

cat > .phaseB-patch.mjs <<'__PB_EOF__'
import { existsSync, readFileSync, writeFileSync } from 'node:fs';

/*
 * Settings, Phase B — edits to files that stay otherwise untouched.
 * Every anchor must be found exactly once; if one is not, nothing is written
 * to any of these files and the installer stops.
 */

const CSS_B = `

/* ---- Phase B: notifications, devices, history ---- */

.st-matrix { display: flex; flex-direction: column; border: 1px solid rgba(127,127,127,.3); border-radius: 10px; overflow: hidden; }
.st-matrix__row { display: grid; grid-template-columns: minmax(0, 1fr) repeat(3, 84px); align-items: center; gap: 8px; padding: 10px 12px; }
.st-matrix__row + .st-matrix__row { border-top: 1px solid rgba(127,127,127,.18); }
.st-matrix__head { font-size: .85rem; font-weight: 700; background: rgba(127,127,127,.08); }
.st-matrix__label { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
.st-matrix__cell { display: grid; place-items: center; text-align: center; }
@media (max-width: 560px) { .st-matrix__row { grid-template-columns: minmax(0, 1fr) repeat(3, 56px); } .st-matrix__head { font-size: .75rem; } }
.st-check { width: 20px; height: 20px; accent-color: #2563eb; cursor: pointer; }

.st-time { flex-direction: row; align-items: center; gap: 8px; }
.st-time .st-input__field { flex: 0 0 auto; width: 8.5em; }

.st-test { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; }
.st-test__ok { font-size: .85rem; color: #15803d; }

.st-session { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 10px; padding: 10px 12px; border-radius: 10px; border: 1px solid rgba(127,127,127,.25); }
.st-session__info { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
.st-session__info .st-label { flex-direction: row; align-items: center; gap: 8px; }
.st-badge { font-size: .72rem; font-weight: 700; padding: 2px 8px; border-radius: 999px; background: rgba(37,99,235,.14); color: #1d4ed8; }

.st-history { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 2px; }
.st-history__item { display: flex; flex-direction: column; gap: 2px; padding: 8px 12px; border-radius: 8px; }
.st-history__item:nth-child(odd) { background: rgba(127,127,127,.07); }
.st-history__item.is-warning .st-history__what { color: #b45309; font-weight: 600; }

.st-linkbutton { border: 0; padding: 0; background: none; color: #2563eb; font: inherit; text-decoration: underline; cursor: pointer; }
.btn--danger { background: #b91c1c; color: #fff; border-color: #b91c1c; }
`;

const INDEX_B =
  "  { tab: 'notifications', anchor: 'matrix', label: 'What you are notified about', keywords: 'notifications types channels email push in app messages mentions chatroom community courses' },\n" +
  "  { tab: 'notifications', anchor: 'push', label: 'Push on this device', keywords: 'push browser device notifications enable permission' },\n" +
  "  { tab: 'notifications', anchor: 'test', label: 'Send a test notification', keywords: 'test notification check email push' },\n" +
  "  { tab: 'notifications', anchor: 'quiet', label: 'Quiet hours', keywords: 'quiet hours night do not disturb sleep silent' },\n" +
  "  { tab: 'notifications', anchor: 'focus', label: 'Focus during lessons', keywords: 'focus lesson class summary interrupt' },\n" +
  "  { tab: 'notifications', anchor: 'previews', label: 'Show message text in push and email', keywords: 'preview message text lock screen privacy' },\n" +
  "  { tab: 'notifications', anchor: 'digest', label: 'Community digest', keywords: 'digest email daily weekly summary community' },\n" +
  "  { tab: 'notifications', anchor: 'muted', label: 'Muted chats', keywords: 'mute muted unmute chats silence' },\n" +
  "  { tab: 'security', anchor: 'sessions', label: 'Where you are signed in', keywords: 'devices sessions signed in logged in browsers phone computer' },\n" +
  "  { tab: 'security', anchor: 'sign-out-others', label: 'Sign out everywhere else', keywords: 'sign out log out everywhere other devices' },\n" +
  "  { tab: 'security', anchor: 'login-history', label: 'Sign-in history', keywords: 'login sign in history failed attempts security' },\n" +
  "  { tab: 'activity', anchor: 'changes', label: 'Recent changes', keywords: 'history changes activity log audit' },\n";

const PROFILE_NOTIFICATION_ROUTES = `/**
 * Notification settings (Phase B). The same data as GET/PATCH
 * /account/notifications, for clients that use the profile paths.
 */
router.get(
  '/me/notifications',
  route(async (req) => NotificationService.getSettings(req.user.id)),
);

router.patch(
  '/me/notifications',
  route(
    asHttp(async (req) => {
      const next = await NotificationService.updateSettings({ userId: req.user.id, patch: req.body ?? {} });
      await recordChange(req, 'notifications', req.body);
      return next;
    }),
  ),
);

/**
 * Who may message me, and what others see.`;

const plan = [
  {
    file: 'server/src/app.js',
    marker: 'accountRoutes',
    edits: [
      {
        name: 'import the account routes',
        regex: /^import\s+profileRoutes\s+from\s+['"]([^'"]*)profile\.routes\.js['"];?[ \t]*\r?\n/m,
        replace: (m, dir) => `${m}import accountRoutes from '${dir}account.routes.js';\n`,
      },
      {
        name: 'mount them under /account',
        regex: /^([ \t]*)app\.use\(\s*['"]\/profiles['"][^\n]*profileRoutes[^\n]*\);?[ \t]*\r?\n/m,
        replace: (m, indent) => `${m}${indent}app.use('/account', accountRoutes); // Settings, Phase B\n`,
      },
    ],
  },
  {
    file: 'packages/core-client/src/index.ts',
    marker: 'accountApi',
    edits: [
      {
        name: 'export the account API',
        find: "export * from './api/profileApi.js';\n",
        replace: "export * from './api/profileApi.js';\nexport * from './api/accountApi.js';\n",
      },
    ],
  },
  {
    file: 'server/src/identity/Profile.js',
    marker: 'NotificationService.updateSettings',
    edits: [
      {
        name: 'notification settings get real storage',
        find:
          '/** Notification preferences have no storage yet; the defaults are returned unchanged. */\n' +
          'export const updateNotifications = async () => ({ ...DEFAULT_NOTIFICATIONS });\n',
        replace:
          '/** Notification settings (Phase B): validated and stored by NotificationService. */\n' +
          'export const updateNotifications = async ({ userId, patch } = {}) => {\n' +
          "  const NotificationService = await import('../community/NotificationService.js');\n" +
          '  return NotificationService.updateSettings({ userId, patch: patch ?? {} });\n' +
          '};\n',
      },
    ],
  },
  {
    file: 'server/src/routes/profile.routes.js',
    marker: 'recordChange',
    edits: [
      {
        name: 'imports',
        find: "import { rateLimit } from '../middleware/rateLimit.js';\n",
        replace:
          "import { rateLimit } from '../middleware/rateLimit.js';\n" +
          "import * as NotificationService from '../community/NotificationService.js';\n" +
          "import { recordChange } from '../settings/changeLog.js';\n",
      },
      {
        name: 'profile changes are recorded and announced',
        find:
          '      if (avatarAssetId) await Profile.setAvatar({ userId: req.user.id, assetId: avatarAssetId });\n' +
          '      return Profile.update({ userId: req.user.id, patch });\n',
        replace:
          '      if (avatarAssetId) await Profile.setAvatar({ userId: req.user.id, assetId: avatarAssetId });\n' +
          '      const next = await Profile.update({ userId: req.user.id, patch });\n' +
          "      await recordChange(req, 'profile', avatarAssetId ? { ...patch, avatar: true } : patch);\n" +
          '      return next;\n',
      },
      {
        name: 'preference changes are recorded and announced',
        find: '  route(asHttp(async (req) => Profile.updatePreferences({ userId: req.user.id, patch: req.body }))),\n',
        replace:
          '  route(\n' +
          '    asHttp(async (req) => {\n' +
          '      const next = await Profile.updatePreferences({ userId: req.user.id, patch: req.body });\n' +
          "      await recordChange(req, 'preferences', req.body);\n" +
          '      return next;\n' +
          '    }),\n' +
          '  ),\n',
      },
      {
        name: 'notification settings under /profiles/me/notifications',
        find: '/**\n * Who may message me, and what others see.',
        replace: PROFILE_NOTIFICATION_ROUTES,
      },
      {
        name: 'privacy changes are recorded and announced',
        find: 'const updatePrivacy = route(async (req) => Profile.updatePrivacy({ userId: req.user.id, patch: req.body }));\n',
        replace:
          'const updatePrivacy = route(async (req) => {\n' +
          '  const next = await Profile.updatePrivacy({ userId: req.user.id, patch: req.body });\n' +
          "  await recordChange(req, 'privacy', req.body);\n" +
          '  return next;\n' +
          '});\n',
      },
    ],
  },
  {
    file: 'apps/web/src/components/Settings/settingsIndex.js',
    marker: "tab: 'notifications'",
    edits: [
      {
        name: 'the new tabs can be searched',
        find: "  { tab: 'teaching', anchor: 'join-muted', label: 'Learners join muted', keywords: 'muted join learners microphone default' },\n];\n",
        replace:
          "  { tab: 'teaching', anchor: 'join-muted', label: 'Learners join muted', keywords: 'muted join learners microphone default' },\n" +
          INDEX_B +
          '];\n',
      },
    ],
  },
  {
    file: 'apps/web/src/components/Settings/settings.css',
    marker: 'Phase B: notifications',
    edits: [
      {
        name: 'styles for the new tabs',
        find: '.st-notice__undo { border: 0; background: transparent; color: #93c5fd; font: inherit; font-weight: 700; cursor: pointer; }\n',
        replace:
          '.st-notice__undo { border: 0; background: transparent; color: #93c5fd; font: inherit; font-weight: 700; cursor: pointer; }' +
          CSS_B,
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

/*
 * Optional: the realtime entrypoint must attach the presence gateway. Most
 * trees already do; if this one does not and the place is unambiguous, add it.
 */
const REALTIME = 'server/src/realtime/index.js';
if (existsSync(REALTIME)) {
  const src = readFileSync(REALTIME, 'utf8');
  if (/attachPresenceGateway|presenceGateway/.test(src)) {
    console.log(`${REALTIME}: presence gateway already wired`);
  } else {
    const calls = [...src.matchAll(/^([ \t]*)(?:await\s+)?attach\w*Gateway\(\s*io\b[^\n]*\n/gm)];
    const imports = [...src.matchAll(/^import[^\n]*\n/gm)];
    if (calls.length === 1 && imports.length > 0) {
      const lastImport = imports.at(-1);
      const call = calls[0];
      let next = src.slice(0, call.index + call[0].length) +
        `${call[1]}attachPresenceGateway(io); // Settings, Phase B: presence and per-person events\n` +
        src.slice(call.index + call[0].length);
      const at = lastImport.index + lastImport[0].length;
      next = next.slice(0, at) + "import { attachPresenceGateway } from './presenceGateway.js';\n" + next.slice(at);
      writeFileSync(REALTIME, next);
      console.log('patched', REALTIME, '\n  - attach the presence gateway');
    } else {
      console.log(`WARN ${REALTIME}: could not find where to attach the presence gateway.`);
      console.log("     Add these two lines by hand, next to the other gateways:");
      console.log("       import { attachPresenceGateway } from './presenceGateway.js';");
      console.log('       attachPresenceGateway(io);');
    }
  }
}
__PB_EOF__
node .phaseB-patch.mjs
rm -f .phaseB-patch.mjs

# ---------------------------------------------------------------------------
# web-push (the server library that sends browser push)
# ---------------------------------------------------------------------------
echo "--- web-push"
SERVER_PKG=$(node -p "require('./server/package.json').name" 2>/dev/null || echo "")
if node -e "require.resolve('web-push', { paths: ['./server'] })" >/dev/null 2>&1; then
  echo "web-push is already installed"
elif [ -n "$SERVER_PKG" ] && npm install web-push@^3.6.7 -w "$SERVER_PKG" --no-audit --no-fund; then
  echo "web-push installed in $SERVER_PKG"
else
  echo "WARN web-push could not be installed. Everything else works; push stays off until"
  echo "     you run: npm install web-push@^3.6.7 -w ${SERVER_PKG:-@classroom/server}"
fi

# ---------------------------------------------------------------------------
# Web push keys (VAPID). Generated once; existing keys are kept, because new
# keys would silently break every browser that already allowed push.
# ---------------------------------------------------------------------------
echo "--- web push keys"
ENV_FILES=()
for e in .env server/.env; do [ -f "$e" ] && ENV_FILES+=("$e"); done
if [ ${#ENV_FILES[@]} -eq 0 ]; then
  echo "WARN no .env found. Push stays off until WEB_PUSH_PUBLIC_KEY, WEB_PUSH_PRIVATE_KEY"
  echo "     and WEB_PUSH_SUBJECT are set for the api and worker processes."
else
  KEYS=""
  for e in "${ENV_FILES[@]}"; do
    if grep -q '^WEB_PUSH_PUBLIC_KEY=.\+' "$e" && grep -q '^WEB_PUSH_PRIVATE_KEY=.\+' "$e"; then
      KEYS="$(grep '^WEB_PUSH_PUBLIC_KEY=' "$e" | tail -1 | cut -d= -f2-) $(grep '^WEB_PUSH_PRIVATE_KEY=' "$e" | tail -1 | cut -d= -f2-)"
      echo "keeping the web push keys in $e"
      break
    fi
  done
  if [ -z "$KEYS" ]; then
    KEYS=$(node -e "
      const c = require('node:crypto');
      let ecdh, priv;
      do { ecdh = c.createECDH('prime256v1'); ecdh.generateKeys(); priv = ecdh.getPrivateKey(); } while (priv.length !== 32);
      console.log(ecdh.getPublicKey().toString('base64url') + ' ' + priv.toString('base64url'));
    ")
    echo "generated new web push keys"
  fi
  PUB=${KEYS%% *}
  PRIV=${KEYS##* }
  for e in "${ENV_FILES[@]}"; do
    if ! grep -q '^WEB_PUSH_PUBLIC_KEY=.\+' "$e"; then
      sed -i '/^WEB_PUSH_PUBLIC_KEY=/d;/^WEB_PUSH_PRIVATE_KEY=/d;/^WEB_PUSH_SUBJECT=/d' "$e"
      [ -n "$(tail -c1 "$e")" ] && echo >> "$e"
      {
        echo "# Web push (Settings, Phase B). Keep these: new keys break every browser that allowed push."
        echo "WEB_PUSH_PUBLIC_KEY=$PUB"
        echo "WEB_PUSH_PRIVATE_KEY=$PRIV"
        echo "WEB_PUSH_SUBJECT=mailto:admin@classroom.local"
      } >> "$e"
      echo "added web push keys to $e"
    fi
  done
fi

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
    *.json) if node -e "JSON.parse(require('fs').readFileSync('$f','utf8'))"; then echo "ok  $f"; else FAILED=1; fi ;;
    *) echo "ok  $f" ;;
  esac
done
if [ "$FAILED" -ne 0 ]; then
  echo
  echo "A file did not pass its check (see above). Undo with: bash phaseB-install.sh --restore" >&2
  exit 1
fi

echo "--- rules (node --test)"
if node --test server/test/settings/*.check.mjs apps/web/src/components/Settings/__checks__/*.check.mjs > .phaseB-test.log 2>&1; then
  echo "ok  $(grep -E '^# pass' .phaseB-test.log | awk '{print $3}') rule tests passed"
  rm -f .phaseB-test.log
else
  cat .phaseB-test.log
  rm -f .phaseB-test.log
  echo "The rule checks failed (see above). Undo with: bash phaseB-install.sh --restore" >&2
  exit 1
fi

# Things that degrade quietly rather than break: say so now, not in a bug report.
if ! grep -qE "listSessions" server/src/identity/SessionStore.js 2>/dev/null; then
  echo "WARN SessionStore.js has no listSessions(): Sign-in & devices will show an empty list."
fi
if ! grep -qE "revokeSession" server/src/identity/SessionStore.js 2>/dev/null; then
  echo "WARN SessionStore.js has no revokeSession(): a device signed out from Settings is still refused"
  echo "     at once, but its refresh token only ends when it expires."
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
  echo "Phase B installed and migration 022 applied. The API restarts on its own;"
  echo "reload the browser tabs with Ctrl+Shift+R."
  if command -v pgrep >/dev/null 2>&1 && ! pgrep -f "src/worker.js" >/dev/null 2>&1; then
    echo
    echo "Note: the worker is not running. Chat, mention, reminder and digest notifications"
    echo "are delivered by it. Start it in a second terminal:"
    echo "  npm run dev:worker -w ${SERVER_PKG:-@classroom/server}"
  fi
else
  echo
  echo "The files are installed, but the migration did not run. Start the containers"
  echo "(./dev-up.sh), then: SERVICE_ROLE=api npm run db:migrate && touch server/src/server.js"
  exit 1
fi