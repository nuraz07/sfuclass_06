// classroom-app/server/src/identity/signup.js
/**
 * Creating an account from the homepage  (Landing)
 *
 * AuthService.register has always been able to create an account; nothing
 * exposed it. This decides the two things register() needs from outside:
 *
 *   may people sign up?   SIGNUP_MODE=open (default) or closed
 *   which organisation?   SIGNUP_TENANT_ID when set; otherwise the
 *                         organisation most people already belong to, so a
 *                         new account can join "anyone with the link" rooms
 *                         and find its classmates. With no users yet, the
 *                         first organisation there is.
 *
 * New accounts are always learners: a role is never chosen at sign-up.
 * Signing in looks accounts up by email across organisations, so an address
 * that exists anywhere is refused here — it could not be signed in to.
 */

import { pool } from '../db/pool.js';
import { logger } from '../observability/logger.js';
import * as Users from './User.js';

const log = logger.child({ component: 'signup' });

const fail = (code, message) => {
  throw Object.assign(new Error(message), { code });
};

export const signupMode = () => (String(process.env.SIGNUP_MODE ?? 'open').trim().toLowerCase() === 'closed' ? 'closed' : 'open');

export const resolveSignupTenant = async () => {
  const pinned = process.env.SIGNUP_TENANT_ID?.trim();
  if (pinned) {
    const { rows } = await pool.query(`SELECT id FROM tenants WHERE id = $1`, [pinned]).catch(() => ({ rows: [] }));
    if (rows[0]) return rows[0].id;
    log.error({ tenantId: pinned }, 'SIGNUP_TENANT_ID does not name an organisation; falling back');
  }
  const { rows } = await pool.query(
    `SELECT tenant_id FROM users WHERE deleted_at IS NULL
      GROUP BY tenant_id ORDER BY count(*) DESC, tenant_id LIMIT 1`,
  );
  if (rows[0]) return rows[0].tenant_id;
  const first = await pool.query(`SELECT id FROM tenants LIMIT 1`);
  return first.rows[0]?.id ?? null;
};

const TIME_ZONES = new Set(Intl.supportedValuesOf('timeZone'));

/**
 * @returns the same as AuthService.login: { user, accessToken, refreshToken, sessionId, … }
 */
export const registerOpen = async ({ displayName, email, password, timeZone = null, locale = null, device }) => {
  if (signupMode() === 'closed') {
    fail('forbidden', 'New accounts cannot be created here. Ask your school or organisation for an invitation.');
  }

  const address = String(email).trim();
  if (await Users.findCredentials(address)) {
    fail('conflict', 'An account with this email already exists.');
  }

  const tenantId = await resolveSignupTenant();
  if (!tenantId) fail('validation_failed', 'Sign-up is not set up yet: there is no organisation to join.');

  const AuthService = await import('./AuthService.js');
  const result = await AuthService.register({
    tenantId,
    email: address,
    password,
    displayName: String(displayName).trim(),
    role: 'learner',
    locale: locale && /^[a-z]{2}(-[A-Z]{2})?$/.test(locale) ? locale : 'en',
    timeZone: timeZone && TIME_ZONES.has(timeZone) ? timeZone : 'UTC',
    device,
  });
  log.info({ userId: result.user?.userId, tenantId }, 'account created from the homepage');
  return result;
};

export default { registerOpen, resolveSignupTenant, signupMode };
