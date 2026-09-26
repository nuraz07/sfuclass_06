// classroom-app/server/src/identity/secondFactor.js
/**
 * Two-step sign-in  (Settings, Phase C)
 *
 * An authenticator app (TOTP), ten recovery codes, and passkeys
 * (identity/passkeys.js). Someone "has two-step sign-in" when an authenticator
 * app is set up or at least one passkey exists; from then on a password alone
 * no longer signs them in (AuthService.login).
 *
 * Setting up an app is two steps on purpose: the secret waits in Redis until
 * a code from the app proves it was scanned, so a half-finished setup can
 * never lock anyone out.
 */

import { env } from '../config/env.js';
import { pool } from '../db/pool.js';
import { stateRedis as redis } from '../db/redis.js';
import { logger } from '../observability/logger.js';
import * as Totp from '../security/totp.js';
import * as Recovery from '../security/recoveryCodes.js';
import { open, seal } from '../security/secretBox.js';
import { twoFactorKey } from '../security/accountKeys.js';

const log = logger.child({ component: 'second-factor' });

const SETUP_TTL_SEC = 10 * 60;
const setupKey = (userId) => `${env.REDIS_PREFIX}:totp-setup:${userId}`;

const iso = (value) => (value ? new Date(value).toISOString() : null);

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

/** What Settings shows, and what login needs to know. */
export const status = async (userId) => {
  const [totp, codes, passkeys] = await Promise.all([
    pool.query(`SELECT enabled_at FROM user_totp WHERE user_id = $1`, [userId]),
    pool.query(`SELECT count(*)::int AS n FROM user_recovery_codes WHERE user_id = $1 AND used_at IS NULL`, [userId]),
    pool.query(`SELECT count(*)::int AS n FROM user_passkeys WHERE user_id = $1`, [userId]),
  ]);
  const totpEnabled = Boolean(totp.rows[0]);
  return {
    totp: { enabled: totpEnabled, enabledAt: iso(totp.rows[0]?.enabled_at) },
    recoveryCodesRemaining: codes.rows[0]?.n ?? 0,
    passkeyCount: passkeys.rows[0]?.n ?? 0,
    required: totpEnabled || (passkeys.rows[0]?.n ?? 0) > 0,
  };
};

/** Which second steps a sign-in may use. Empty: a password is enough. */
export const methodsFor = async (userId) => {
  const current = await status(userId);
  const methods = [];
  if (current.totp.enabled) methods.push('totp');
  if (current.recoveryCodesRemaining > 0) methods.push('recovery');
  if (current.passkeyCount > 0) methods.push('passkey');
  return methods;
};

// ---------------------------------------------------------------------------
// Authenticator app
// ---------------------------------------------------------------------------

const qrDataUrl = async (text) => {
  try {
    const imported = await import('qrcode');
    const QRCode = imported.default ?? imported;
    return await QRCode.toDataURL(text, { margin: 1, width: 220, errorCorrectionLevel: 'M' });
  } catch (cause) {
    // Without the library the secret and the link still work; only the picture is missing.
    log.debug({ err: cause }, 'no QR code library');
    return null;
  }
};

/** Step 1: a new secret, held for ten minutes until it is confirmed. */
export const startTotpSetup = async ({ userId, accountName }) => {
  const secret = Totp.generateSecret();
  await redis.set(setupKey(userId), seal(secret, twoFactorKey()), 'EX', SETUP_TTL_SEC);
  const uri = Totp.otpauthUri({ secret, accountName });
  return { secret, uri, qr: await qrDataUrl(uri), expiresInSec: SETUP_TTL_SEC };
};

/**
 * Step 2: a code from the app proves it was scanned. Replaces any earlier
 * app, and issues a fresh set of recovery codes, which are returned once.
 */
export const confirmTotpSetup = async ({ userId, code }) => {
  const sealed = await redis.get(setupKey(userId));
  if (!sealed) {
    throw Object.assign(new Error('The setup expired. Start again and scan the new code.'), { code: 'validation_failed' });
  }
  const secret = open(sealed, twoFactorKey());
  const step = Totp.verifyCode(secret, code);
  if (step === null) {
    throw Object.assign(new Error('That code is not right. Check the time on your phone and try the newest code.'), {
      code: 'validation_failed',
    });
  }

  const codes = Recovery.generateCodes();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query(
      `INSERT INTO user_totp (user_id, secret_encrypted, last_used_step, enabled_at)
       VALUES ($1, $2, $3, now())
       ON CONFLICT (user_id) DO UPDATE
          SET secret_encrypted = EXCLUDED.secret_encrypted,
              last_used_step = EXCLUDED.last_used_step,
              enabled_at = now()`,
      [userId, seal(secret, twoFactorKey()), step],
    );
    await replaceRecoveryCodes(client, userId, codes);
    await client.query('COMMIT');
  } catch (cause) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw cause;
  } finally {
    client.release();
  }
  await redis.del(setupKey(userId));
  log.info({ userId }, 'authenticator app enabled');
  return { recoveryCodes: codes };
};

/** Removes the app. Recovery codes go with it unless passkeys still need them. */
export const disableTotp = async ({ userId }) => {
  await pool.query(`DELETE FROM user_totp WHERE user_id = $1`, [userId]);
  const { passkeyCount } = await status(userId);
  if (passkeyCount === 0) await pool.query(`DELETE FROM user_recovery_codes WHERE user_id = $1`, [userId]);
  log.info({ userId }, 'authenticator app disabled');
};

// ---------------------------------------------------------------------------
// Recovery codes
// ---------------------------------------------------------------------------

const replaceRecoveryCodes = async (client, userId, codes) => {
  await client.query(`DELETE FROM user_recovery_codes WHERE user_id = $1`, [userId]);
  for (const code of codes) {
    await client.query(`INSERT INTO user_recovery_codes (user_id, code_hash) VALUES ($1, $2)`, [
      userId,
      Recovery.hashCode(code),
    ]);
  }
};

/** A new set; every older code stops working. */
export const regenerateRecoveryCodes = async ({ userId }) => {
  const codes = Recovery.generateCodes();
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await replaceRecoveryCodes(client, userId, codes);
    await client.query('COMMIT');
  } catch (cause) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw cause;
  } finally {
    client.release();
  }
  return { recoveryCodes: codes };
};

/** Called when the first passkey is added and no codes exist yet. */
export const ensureRecoveryCodes = async ({ userId }) => {
  const { rows } = await pool.query(`SELECT 1 FROM user_recovery_codes WHERE user_id = $1 LIMIT 1`, [userId]);
  if (rows.length > 0) return null;
  return (await regenerateRecoveryCodes({ userId })).recoveryCodes;
};

// ---------------------------------------------------------------------------
// Checking a code
// ---------------------------------------------------------------------------

/**
 * A 6-digit code from the app, or a recovery code (used up on success).
 * @returns {Promise<null | 'totp' | 'recovery'>}
 */
export const verifyCode = async ({ userId, code }) => {
  const input = String(code ?? '').trim();

  if (Recovery.looksLikeRecoveryCode(input)) {
    const normalized = Recovery.normalizeCode(input);
    const { rowCount } = await pool.query(
      `UPDATE user_recovery_codes SET used_at = now()
        WHERE id = (SELECT id FROM user_recovery_codes
                     WHERE user_id = $1 AND code_hash = $2 AND used_at IS NULL LIMIT 1)`,
      [userId, Recovery.hashCode(normalized)],
    );
    return rowCount === 1 ? 'recovery' : null;
  }

  const { rows } = await pool.query(
    `SELECT secret_encrypted, last_used_step FROM user_totp WHERE user_id = $1`,
    [userId],
  );
  if (!rows[0]) return null;
  let secret;
  try {
    secret = open(rows[0].secret_encrypted, twoFactorKey());
  } catch (cause) {
    log.error({ err: cause, userId }, 'authenticator secret cannot be decrypted; was the key changed?');
    return null;
  }
  const step = Totp.verifyCode(secret, input, { lastUsedStep: Number(rows[0].last_used_step) });
  if (step === null) return null;

  // Conditional: two requests with the same code cannot both succeed.
  const { rowCount } = await pool.query(
    `UPDATE user_totp SET last_used_step = $2 WHERE user_id = $1 AND last_used_step < $2`,
    [userId, step],
  );
  return rowCount === 1 ? 'totp' : null;
};

/** For the data export and account deletion. */
export const removeAll = async (userId, client = pool) => {
  await client.query(`DELETE FROM user_totp WHERE user_id = $1`, [userId]);
  await client.query(`DELETE FROM user_recovery_codes WHERE user_id = $1`, [userId]);
  await client.query(`DELETE FROM user_passkeys WHERE user_id = $1`, [userId]);
};

export default {
  status, methodsFor, startTotpSetup, confirmTotpSetup, disableTotp,
  regenerateRecoveryCodes, ensureRecoveryCodes, verifyCode, removeAll,
};
