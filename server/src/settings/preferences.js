// classroom-app/server/src/settings/preferences.js
/**
 * Account preferences  (Settings, Phase A)
 *
 * The one definition of what a preference may be. Stored in
 * profiles.preferences (021) as a jsonb object of sections; every write is
 * validated here, merged into what is stored, and the full result returned
 * with defaults filled in — so a client never has to know a default.
 *
 *   appearance    fontScale · reduceMotion
 *   region        dateFormat · timeFormat          (language and time zone
 *                                                    live on the user row)
 *   lesson        joinMicrophone · joinCamera · noiseSuppression ·
 *                 echoCancellation · dataSaver
 *   roomDefaults  reactionsEnabled · learnersJoinMuted
 *                                                   teachers and owners only
 *
 * Waiting room and "learners may share their screen" are deliberately not
 * lesson defaults yet: the join flow has no admit step (a waiting room would
 * turn people away, the host included), and the screen-share rule is not
 * enforced in one place the default could rely on.
 *
 * Device choices (which camera, which microphone) are not here on purpose:
 * device ids differ per computer, so the browser keeps them.
 */

import { z } from 'zod';

const appearance = z.object({
  fontScale: z.enum(['small', 'default', 'large', 'x-large']),
  reduceMotion: z.boolean(),
});

const region = z.object({
  dateFormat: z.enum(['auto', 'day-month-year', 'month-day-year', 'year-month-day']),
  timeFormat: z.enum(['auto', '24h', '12h']),
});

const lesson = z.object({
  joinMicrophone: z.enum(['off', 'on']),
  joinCamera: z.enum(['on', 'off']),
  noiseSuppression: z.boolean(),
  echoCancellation: z.boolean(),
  dataSaver: z.boolean(),
});

const roomDefaults = z.object({
  reactionsEnabled: z.boolean(),
  learnersJoinMuted: z.boolean(),
});

export const DEFAULT_PREFERENCES = Object.freeze({
  appearance: { fontScale: 'default', reduceMotion: false },
  region: { dateFormat: 'auto', timeFormat: 'auto' },
  lesson: {
    joinMicrophone: 'off',
    joinCamera: 'on',
    noiseSuppression: true,
    echoCancellation: true,
    dataSaver: false,
  },
  roomDefaults: {
    reactionsEnabled: true,
    learnersJoinMuted: false,
  },
});

const SECTIONS = { appearance, region, lesson, roomDefaults };

/** A patch: any section, any subset of its keys. Unknown keys are refused. */
export const PreferencesPatchSchema = z
  .object({
    appearance: appearance.partial().strict().optional(),
    region: region.partial().strict().optional(),
    lesson: lesson.partial().strict().optional(),
    roomDefaults: roomDefaults.partial().strict().optional(),
  })
  .strict();

/** Stored values over defaults; anything stored that is no longer valid falls back. */
export const withDefaults = (stored = {}) => {
  const result = {};
  for (const [name, schema] of Object.entries(SECTIONS)) {
    const merged = { ...DEFAULT_PREFERENCES[name], ...(stored?.[name] ?? {}) };
    const parsed = schema.safeParse(merged);
    result[name] = parsed.success ? parsed.data : { ...DEFAULT_PREFERENCES[name] };
  }
  return result;
};

/** Merges a validated patch into stored preferences, section by section. */
export const mergePatch = (stored = {}, patch = {}) => {
  const next = { ...(stored ?? {}) };
  for (const [name, values] of Object.entries(patch)) {
    if (values) next[name] = { ...(next[name] ?? {}), ...values };
  }
  return next;
};

export const TEACHING_ROLES = new Set(['teacher', 'owner']);

export default { DEFAULT_PREFERENCES, PreferencesPatchSchema, withDefaults, mergePatch, TEACHING_ROLES };
