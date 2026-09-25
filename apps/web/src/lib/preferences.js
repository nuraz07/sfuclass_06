/**
 * Preferences on this device  (Settings, Phase A)
 *
 * The account's preferences live on the server (GET/PATCH
 * /profiles/me/preferences). This module keeps a copy in localStorage so they
 * apply from the first frame — the font size before the page paints, the
 * microphone state before a lesson is joined — and refreshes that copy
 * whenever the server answers (PreferencesSync in AppLayout, and every save
 * in Settings).
 *
 * Device choices (camera, microphone, speaker) are stored here only: device
 * ids differ from computer to computer.
 */

const CACHE_KEY = 'classroom:preferences';
const DEVICE_KEY = 'classroom:devices';
const LOCALE_KEY = 'classroom:locale';

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
  roomDefaults: { reactionsEnabled: true, learnersJoinMuted: false },
});

const storage = () => {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null;
  }
};

const readJson = (key) => {
  try {
    return JSON.parse(storage()?.getItem(key) ?? 'null');
  } catch {
    return null;
  }
};

const writeJson = (key, value) => {
  try {
    storage()?.setItem(key, JSON.stringify(value));
  } catch {
    // Private mode or a full quota: the preferences still apply for this page.
  }
};

const merge = (stored) => {
  const result = {};
  for (const [section, defaults] of Object.entries(DEFAULT_PREFERENCES)) {
    result[section] = { ...defaults, ...(stored?.[section] ?? {}) };
  }
  return result;
};

export const cachedPreferences = () => merge(readJson(CACHE_KEY));

/** Stores the server's answer on this device and applies what applies at once. */
export const cachePreferences = (preferences) => {
  const merged = merge(preferences);
  writeJson(CACHE_KEY, merged);
  applyAppearance(merged.appearance);
  return merged;
};

export const cacheLocale = (locale) => {
  if (locale) writeJson(LOCALE_KEY, locale);
};
const cachedLocale = () => readJson(LOCALE_KEY) ?? undefined;

// ---------------------------------------------------------------------------
// Appearance
// ---------------------------------------------------------------------------

export const FONT_SCALES = { small: '93.75%', default: '100%', large: '112.5%', 'x-large': '125%' };

const MOTION_STYLE_ID = 'classroom-reduce-motion';
const MOTION_CSS = `
:root[data-reduce-motion="true"] *,
:root[data-reduce-motion="true"] *::before,
:root[data-reduce-motion="true"] *::after {
  animation-duration: 0.01ms !important;
  animation-iteration-count: 1 !important;
  transition-duration: 0.01ms !important;
  scroll-behavior: auto !important;
}`;

export const applyAppearance = (appearance = DEFAULT_PREFERENCES.appearance) => {
  const root = globalThis.document?.documentElement;
  if (!root) return;
  root.style.fontSize = FONT_SCALES[appearance.fontScale] ?? '100%';
  root.dataset.reduceMotion = appearance.reduceMotion ? 'true' : 'false';
  if (!document.getElementById(MOTION_STYLE_ID)) {
    const style = document.createElement('style');
    style.id = MOTION_STYLE_ID;
    style.textContent = MOTION_CSS;
    document.head.appendChild(style);
  }
};

/** Called once in main.jsx, before the first render. */
export const applyCachedAppearance = () => applyAppearance(cachedPreferences().appearance);

// ---------------------------------------------------------------------------
// Date and time
// ---------------------------------------------------------------------------

const pad = (n) => String(n).padStart(2, '0');

export const formatTime = (value, region = cachedPreferences().region) => {
  const date = value instanceof Date ? value : new Date(value);
  const options = { hour: '2-digit', minute: '2-digit' };
  if (region.timeFormat === '24h') options.hourCycle = 'h23';
  if (region.timeFormat === '12h') options.hourCycle = 'h12';
  return new Intl.DateTimeFormat(cachedLocale(), options).format(date);
};

export const formatDate = (value, region = cachedPreferences().region) => {
  const date = value instanceof Date ? value : new Date(value);
  const d = pad(date.getDate());
  const m = pad(date.getMonth() + 1);
  const y = date.getFullYear();
  switch (region.dateFormat) {
    case 'day-month-year':
      return `${d}.${m}.${y}`;
    case 'month-day-year':
      return `${m}/${d}/${y}`;
    case 'year-month-day':
      return `${y}-${m}-${d}`;
    default:
      return new Intl.DateTimeFormat(cachedLocale(), { day: 'numeric', month: 'short', year: 'numeric' }).format(date);
  }
};

// ---------------------------------------------------------------------------
// Lessons: how to join, which devices
// ---------------------------------------------------------------------------

export const readDevices = () => ({ cameraId: null, microphoneId: null, speakerId: null, ...(readJson(DEVICE_KEY) ?? {}) });
export const writeDevices = (patch) => {
  const next = { ...readDevices(), ...patch };
  writeJson(DEVICE_KEY, next);
  return next;
};

/** Microphone and camera state when a lesson is joined, from Settings → Lessons. */
export const lessonJoinDefaults = () => {
  const { lesson } = cachedPreferences();
  return { startMuted: lesson.joinMicrophone !== 'on', startCameraOff: lesson.joinCamera === 'off' };
};

/** getUserMedia constraints for this device and these preferences. */
export const mediaConstraints = (request = { audio: true, video: true }) => {
  const { lesson } = cachedPreferences();
  const devices = readDevices();
  const base = (value) => (value && typeof value === 'object' ? value : {});

  const audio = request.audio
    ? {
        ...base(request.audio),
        noiseSuppression: lesson.noiseSuppression,
        echoCancellation: lesson.echoCancellation,
        autoGainControl: true,
        // `ideal`, not `exact`: an unplugged device falls back instead of failing.
        ...(devices.microphoneId ? { deviceId: { ideal: devices.microphoneId } } : {}),
      }
    : false;

  const video = request.video
    ? {
        ...base(request.video),
        ...(lesson.dataSaver
          ? { width: { ideal: 640 }, height: { ideal: 360 }, frameRate: { ideal: 15 } }
          : { width: { ideal: 1280 }, height: { ideal: 720 } }),
        ...(devices.cameraId ? { deviceId: { ideal: devices.cameraId } } : {}),
      }
    : false;

  return { audio, video };
};

/**
 * The same device adapter, with every capture using the chosen devices and
 * the audio processing from Settings. A Proxy rather than a copy: the adapter
 * keeps its identity for everything else, and this wrapper is created once per
 * adapter, so the lesson does not rejoin because a setting changed.
 */
export const withMediaPreferences = (adapter) => {
  if (!adapter) return adapter;
  return new Proxy(adapter, {
    get(target, property) {
      if (property === 'getUserMedia') {
        return async (request) => {
          const mediaDevices = globalThis.navigator?.mediaDevices;
          if (!mediaDevices?.getUserMedia) return target.getUserMedia(request);
          try {
            return await mediaDevices.getUserMedia(mediaConstraints(request));
          } catch (cause) {
            // A setting the device cannot meet must never keep someone out of
            // a lesson: capture the way the adapter would have.
            if (cause?.name === 'OverconstrainedError' || cause?.name === 'NotFoundError') {
              return target.getUserMedia(request);
            }
            throw cause;
          }
        };
      }
      // The target as receiver: getters that use private fields must see the real object.
      const value = Reflect.get(target, property);
      return typeof value === 'function' ? value.bind(target) : value;
    },
  });
};
