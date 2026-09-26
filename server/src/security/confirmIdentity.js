// classroom-app/server/src/security/confirmIdentity.js
/**
 * "Confirm it's you"  (Settings, Phase C)
 *
 * Changes that lock someone out or cannot be undone — turning two-step
 * sign-in off, removing a passkey, new recovery codes, deleting the account —
 * ask for the password again, or for a code when the account has two-step
 * sign-in. A laptop left open is signed in; it does not know the password.
 *
 * Wrong answers count toward the same lockout as wrong passwords at sign-in
 * (users.failed_attempts), so this cannot be used to guess a password.
 */

import { pool } from '../db/pool.js';
import * as Users from '../identity/User.js';

const refused = (message = 'That is not right.') =>
  Object.assign(new Error(message), { code: 'forbidden', reauth: true });

/**
 * @param {{ userId: string, password?: string, code?: string }} input
 * @returns {Promise<'password' | 'totp' | 'recovery'>}
 */
export const confirmIdentity = async ({ userId, password, code }) => {
  const { rows } = await pool.query(
    `SELECT password_hash, locked_until FROM users WHERE id = $1 AND deleted_at IS NULL`,
    [userId],
  );
  const row = rows[0];
  if (!row) throw refused();
  if (row.locked_until && new Date(row.locked_until) > new Date()) {
    throw Object.assign(new Error('Too many attempts. Try again in a few minutes.'), { code: 'rate_limited', retryAfter: 900 });
  }

  if (password) {
    const correct = row.password_hash ? await Users.verifyPassword(password, row.password_hash) : false;
    if (correct) return 'password';
    await Users.recordFailedLogin(userId);
    throw refused('That password is not right.');
  }

  if (code) {
    const SecondFactor = await import('../identity/secondFactor.js');
    const method = await SecondFactor.verifyCode({ userId, code });
    if (method) return method;
    await Users.recordFailedLogin(userId);
    throw refused('That code is not right.');
  }

  throw refused('Enter your password to confirm.');
};

export default confirmIdentity;
