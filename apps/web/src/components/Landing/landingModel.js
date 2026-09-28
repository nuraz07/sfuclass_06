/**
 * Pure helpers for the public homepage  (Landing)
 *
 * The room planner on the homepage uses the same rules as the real room
 * editor — doors 3 to 10 minutes before the start, hosts 30 minutes early —
 * so what a visitor tries here is what they get after signing up.
 * No React, no network: tested in __checks__/landingModel.check.mjs.
 */

export const DOORS = Object.freeze({ min: 3, max: 10, default: 5 });
export const HOST_EARLY_MIN = 30;
export const LENGTHS = Object.freeze([30, 45, 60, 90]);

const MINUTE = 60_000;

/** The next full half hour at least 20 minutes from now: a believable example start. */
export const exampleStart = (now = new Date()) => {
  const start = new Date(now.getTime() + 20 * MINUTE);
  start.setSeconds(0, 0);
  start.setMinutes(start.getMinutes() < 30 ? 30 : 60);
  return start;
};

export const clampDoors = (value) =>
  Math.min(DOORS.max, Math.max(DOORS.min, Math.round(Number(value) || DOORS.default)));

/**
 * The moments of one room, and where each sits on a bar from the host's
 * early entry to the end (0–100 %), for the timeline drawing.
 */
export const timelineFor = ({ start, lengthMinutes, doorsMinutes }) => {
  const startsAt = new Date(start).getTime();
  const doors = clampDoors(doorsMinutes);
  const hostAt = startsAt - HOST_EARLY_MIN * MINUTE;
  const doorsAt = startsAt - doors * MINUTE;
  const endsAt = startsAt + lengthMinutes * MINUTE;
  const span = endsAt - hostAt;
  const at = (t) => Math.round(((t - hostAt) / span) * 1000) / 10;
  return {
    hostAt,
    doorsAt,
    startsAt,
    endsAt,
    marks: [
      { id: 'host', label: 'You can open the room', time: hostAt, position: 0 },
      { id: 'doors', label: 'Doors open', time: doorsAt, position: at(doorsAt) },
      { id: 'start', label: 'Lesson starts', time: startsAt, position: at(startsAt) },
      { id: 'end', label: 'Room closes', time: endsAt, position: 100 },
    ],
  };
};

/**
 * A language tag the date formatter accepts, or undefined (the browser's
 * default). Browsers can report tags Intl rejects (e.g. "en-US@posix"), and
 * a throwing formatter would blank the whole homepage.
 */
export const safeLocale = (locale) => {
  try {
    return locale && Intl.DateTimeFormat.supportedLocalesOf([locale]).length ? locale : undefined;
  } catch {
    return undefined;
  }
};

/** A time zone Intl knows, or UTC. */
export const safeZone = (zone) => {
  try {
    new Intl.DateTimeFormat('en', { timeZone: zone });
    return zone || 'UTC';
  } catch {
    return 'UTC';
  }
};

/** "14:30" in a time zone, in the visitor's language. */
export const clock = (time, timeZone, locale) =>
  new Intl.DateTimeFormat(safeLocale(locale), { timeZone: safeZone(timeZone), hour: '2-digit', minute: '2-digit' }).format(
    new Date(time),
  );

/** The weekday offset between two zones at a moment: -1, 0 or +1 ("next day"). */
export const dayShift = (time, fromZone, toZone) => {
  const day = (zone) =>
    new Intl.DateTimeFormat('en-CA', { timeZone: safeZone(zone), year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(time));
  const a = day(fromZone);
  const b = day(toZone);
  return a === b ? 0 : b > a ? 1 : -1;
};

/** Cities shown next to the visitor's own time; the visitor's zone first, no duplicates. */
export const GUEST_ZONES = Object.freeze([
  { zone: 'Europe/London', city: 'London' },
  { zone: 'Europe/Berlin', city: 'Berlin' },
  { zone: 'America/New_York', city: 'New York' },
  { zone: 'Asia/Singapore', city: 'Singapore' },
  { zone: 'Australia/Sydney', city: 'Sydney' },
]);

export const cityOf = (zone) => String(zone || 'UTC').split('/').pop().replace(/_/g, ' ');

export const guestTimes = ({ time, ownZone, locale, count = 3 }) => {
  const seen = new Set();
  const list = [];
  for (const entry of [{ zone: ownZone, city: cityOf(ownZone), own: true }, ...GUEST_ZONES]) {
    const shown = clock(time, entry.zone, locale);
    const key = `${shown}|${dayShift(time, ownZone, entry.zone)}`;
    if (seen.has(entry.zone) || (!entry.own && seen.has(key))) continue;
    seen.add(entry.zone);
    seen.add(key);
    list.push({ ...entry, time: shown, shift: dayShift(time, ownZone, entry.zone) });
    if (list.length === count + 1) break;
  }
  return list;
};

/** "4:59" — minutes and seconds, for the countdown in the demo. */
export const mmss = (ms) => {
  const total = Math.max(0, Math.ceil(ms / 1000));
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`;
};

/** Where the "Create this room" button leads: sign-up first, then the real editor. */
export const plannerNext = '/rooms/new';
