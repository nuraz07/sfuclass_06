// classroom-app/server/src/config/publicUrl.js
/**
 * The address people open the app at  (Rooms · links)
 *
 * APP_URL in .env is where the app runs for the developer — usually
 * http://localhost:5173. That is the wrong address for a link somebody else
 * opens: a room invitation, a reminder email, a QR code, a calendar entry,
 * a password reset. This module works out the public address instead, and
 * does it by itself on every start, so a fresh clone in a new Codespace (a
 * new address every time) needs no editing.
 *
 * In order:
 *
 *   1. PUBLIC_APP_URL          set it to pin the address, e.g. in production
 *                              or behind your own domain
 *   2. the hosted workspace    when APP_URL points at this machine and the
 *                              app runs in GitHub Codespaces or Gitpod: the
 *                              forwarded address of APP_URL's port
 *   3. APP_URL                 as configured
 *
 * For a request from a browser, publicAppUrlFor(req) prefers the address
 * that browser is actually on (Origin, then Referer, then ?origin=) — when it
 * is one this app trusts and not a local address that nobody else can open.
 *
 * Read from process.env, not config/env.js: PUBLIC_APP_URL is optional and
 * not part of the env schema that check-env-schema.js compares.
 */

import { env, isProduction } from './env.js';
import {
  chooseLinkOrigin,
  isLocalOrigin,
  originOf,
  resolvePublicAppUrl,
} from './publicUrlRules.js';

export { chooseLinkOrigin, hostedWorkspaceUrl, isLocalOrigin, originOf, resolvePublicAppUrl } from './publicUrlRules.js';

let cached = null;

/** The public address of the web app, without a trailing slash. */
export const publicAppUrl = () => {
  cached ??= resolvePublicAppUrl({ environment: process.env, appUrl: env.APP_URL ?? process.env.APP_URL });
  return cached;
};

/** Origins a browser may legitimately be on. */
export const isTrustedOrigin = (origin, { environment = process.env, production = isProduction } = {}) => {
  if (!origin) return false;
  const trusted = new Set(
    [publicAppUrl(), originOf(env.APP_URL ?? environment.APP_URL), ...(env.ALLOWED_ORIGINS ?? []).map(originOf)].filter(Boolean),
  );
  if (trusted.has(origin)) return true;
  if (production) return false;
  // Development: this workspace's own forwarded addresses, and this machine.
  const host = new URL(origin).hostname;
  if (isLocalOrigin(origin)) return true;
  if (environment.CODESPACE_NAME) {
    const domain = environment.GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN || 'app.github.dev';
    return host.startsWith(`${environment.CODESPACE_NAME}-`) && host.endsWith(`.${domain}`);
  }
  return false;
};

/** The address to put in a link produced for this request. */
export const publicAppUrlFor = (req) =>
  chooseLinkOrigin({
    candidates: [req?.get?.('origin'), req?.get?.('referer'), req?.query?.origin].filter(Boolean),
    fallback: publicAppUrl(),
    trusted: (origin) => isTrustedOrigin(origin),
  });

export default publicAppUrl;
