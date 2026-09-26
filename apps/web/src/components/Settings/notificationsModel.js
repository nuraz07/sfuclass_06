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
    case 'auth.second_factor.failed':
      return entry.detail === 'passkey'
        ? 'Password right, passkey refused'
        : 'Password right, wrong second-step code';
    case 'security.password.changed':
      return (entry.count ?? 0) > 0
        ? `Password changed; ${entry.count} other ${entry.count === 1 ? 'device' : 'devices'} signed out`
        : 'Password changed';
    case 'security.totp.enabled':
      return 'Two-step sign-in turned on (authenticator app)';
    case 'security.totp.disabled':
      return 'Authenticator app removed';
    case 'security.recovery_codes.regenerated':
      return 'New recovery codes made; the old ones stopped working';
    case 'security.passkey.added':
      return entry.detail ? `Passkey added: ${entry.detail}` : 'Passkey added';
    case 'security.passkey.removed':
      return entry.detail ? `Passkey removed: ${entry.detail}` : 'Passkey removed';
    case 'account.exported':
      return 'Your data was downloaded';
    case 'account.deletion.requested':
      return 'Account deletion requested';
    case 'account.deletion.cancelled':
      return 'Account deletion cancelled';
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
