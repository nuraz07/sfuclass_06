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
