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
