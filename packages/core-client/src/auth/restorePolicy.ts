/**
 * Staying signed in when the server is briefly away  (Auth)
 *
 * Resuming a session (on load, or when an access token runs out) can fail for
 * two very different reasons:
 *
 *   the server said no     401 / revoked / reused — the session is over:
 *                          show the sign-in page
 *   the server did not     network error, timeout, 5xx (a restarting API, a
 *   answer properly        dev proxy with nothing behind it), 429 — nothing is
 *                          known about the session: keep it and try again
 *
 * A 403 on the refresh route is almost always a stale CSRF token (the API
 * restarted, the cookie rotated): fetch a fresh one and try once more.
 *
 * Pure: no React, no network.
 */

export type RestoreVerdict = 'signed-out' | 'csrf' | 'transient';

const TRANSIENT_CODES = new Set(['dependency_unavailable', 'rate_limited', 'internal_error', 'timeout', 'service_unavailable']);

/** What a failed refresh means. Anything that is not an answer from the API is transient. */
export const classifyRefreshFailure = (error: unknown): RestoreVerdict => {
  const code = (error as { code?: unknown } | null)?.code;
  if (typeof code !== 'string') return 'transient';
  if (code === 'forbidden') return 'csrf';
  if (TRANSIENT_CODES.has(code)) return 'transient';
  return 'signed-out';
};

/** 1 s, 2 s, 4 s, 8 s, 16 s, then every 30 s — with a little jitter so tabs do not line up. */
export const restoreDelayMs = (attempt: number, random: () => number = Math.random): number => {
  const base = Math.min(1_000 * 2 ** Math.max(0, attempt - 1), 30_000);
  return Math.round(base * (0.85 + random() * 0.3));
};

export default { classifyRefreshFailure, restoreDelayMs };
