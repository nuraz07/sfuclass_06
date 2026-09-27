// classroom-app/server/src/identity/passkeys.js
/**
 * Passkeys (WebAuthn)  (Settings, Phase C)
 *
 * A passkey is a key pair kept by the device (and often synced by the
 * platform): the private half never leaves it, the public half is stored
 * here. It works two ways:
 *
 *   second step   after the password, instead of a code
 *   sign-in       on its own, with the device's fingerprint, face or PIN
 *                 (user verification required) — no password at all
 *
 * The WebAuthn parsing is @simplewebauthn/server, imported lazily: without
 * it, everything else in the platform keeps working and passkey calls answer
 * "not available".
 *
 * Which site a passkey belongs to (the relying party id) is taken from the
 * Origin of the request, checked against APP_URL and ALLOWED_ORIGINS — so it
 * also works on a forwarded development address (Codespaces, a tunnel) that
 * is listed there. In development, localhost and *.app.github.dev are
 * accepted as well.
 */

import { randomUUID } from 'node:crypto';
import { env } from '../config/env.js';
import { pool } from '../db/pool.js';
import { stateRedis as redis } from '../db/redis.js';
import { logger } from '../observability/logger.js';

const log = logger.child({ component: 'passkeys' });

const CHALLENGE_TTL_SEC = 5 * 60;
const challengeKey = (id) => `${env.REDIS_PREFIX}:webauthn:${id}`;
const MAX_PASSKEYS = 10;

const notAvailable = () =>
  Object.assign(new Error('Passkeys are not available on this server yet.'), { code: 'dependency_unavailable' });

let library = null;
const webauthn = async () => {
  if (library) return library;
  try {
    library = await import('@simplewebauthn/server');
    return library;
  } catch (cause) {
    log.warn({ err: cause }, '@simplewebauthn/server is not installed');
    throw notAvailable();
  }
};

export const available = async () => {
  try {
    await webauthn();
    return true;
  } catch {
    return false;
  }
};

// ---------------------------------------------------------------------------
// Site
// ---------------------------------------------------------------------------

const originOf = (value) => {
  try {
    return new URL(value).origin;
  } catch {
    return null;
  }
};

/** The origin a browser request came from, if this site may use passkeys there. */
export const relyingParty = (requestOrigin) => {
  const origin = originOf(requestOrigin ?? '') ?? originOf(env.APP_URL);
  if (!origin) throw Object.assign(new Error('Unknown site.'), { code: 'validation_failed' });

  const allowed = new Set([originOf(env.APP_URL), ...(env.ALLOWED_ORIGINS ?? []).map(originOf)].filter(Boolean));
  const { hostname, protocol } = new URL(origin);
  const devHost =
    env.NODE_ENV !== 'production' &&
    (hostname === 'localhost' || hostname === '127.0.0.1' || hostname.endsWith('.app.github.dev'));

  if (!allowed.has(origin) && !devHost) {
    throw Object.assign(new Error('Passkeys cannot be used from this address.'), { code: 'forbidden' });
  }
  if (protocol !== 'https:' && hostname !== 'localhost' && hostname !== '127.0.0.1') {
    throw Object.assign(new Error('Passkeys need a secure (https) address.'), { code: 'validation_failed' });
  }
  return { origin, rpID: hostname, rpName: 'Classroom' };
};

// ---------------------------------------------------------------------------
// Challenges (single-use, five minutes)
// ---------------------------------------------------------------------------

const keepChallenge = async (record) => {
  const id = randomUUID();
  await redis.set(challengeKey(id), JSON.stringify(record), 'EX', CHALLENGE_TTL_SEC);
  return id;
};

const takeChallenge = async (id) => {
  if (!id) return null;
  const raw = await redis.getdel(challengeKey(id));
  return raw ? JSON.parse(raw) : null;
};

const expired = () =>
  Object.assign(new Error('That took too long. Try again.'), { code: 'validation_failed' });

// ---------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------

const toPasskey = (row) => ({
  id: row.id,
  name: row.name,
  deviceType: row.device_type ?? null,
  backedUp: Boolean(row.backed_up),
  site: row.rp_id,
  createdAt: row.created_at ? new Date(row.created_at).toISOString() : null,
  lastUsedAt: row.last_used_at ? new Date(row.last_used_at).toISOString() : null,
});

export const list = async (userId) => {
  const { rows } = await pool.query(
    `SELECT id, name, device_type, backed_up, rp_id, created_at, last_used_at
       FROM user_passkeys WHERE user_id = $1 ORDER BY created_at`,
    [userId],
  );
  return rows.map(toPasskey);
};

export const rename = async ({ userId, id, name }) => {
  const { rowCount } = await pool.query(
    `UPDATE user_passkeys SET name = $3 WHERE user_id = $1 AND id = $2`,
    [userId, id, name],
  );
  return rowCount === 1;
};

export const remove = async ({ userId, id }) => {
  const { rows } = await pool.query(
    `DELETE FROM user_passkeys WHERE user_id = $1 AND id = $2 RETURNING name`,
    [userId, id],
  );
  return rows[0]?.name ?? null;
};

const credentialOf = (row) => ({
  id: row.credential_id,
  publicKey: new Uint8Array(row.public_key),
  counter: Number(row.counter ?? 0),
  transports: row.transports ?? [],
});

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

export const registrationOptions = async ({ user, requestOrigin }) => {
  const { generateRegistrationOptions } = await webauthn();
  const site = relyingParty(requestOrigin);

  const { rows } = await pool.query(
    `SELECT credential_id, transports FROM user_passkeys WHERE user_id = $1`,
    [user.userId],
  );
  if (rows.length >= MAX_PASSKEYS) {
    throw Object.assign(new Error(`You can keep up to ${MAX_PASSKEYS} passkeys. Remove one first.`), {
      code: 'validation_failed',
    });
  }

  const options = await generateRegistrationOptions({
    rpName: site.rpName,
    rpID: site.rpID,
    userID: new TextEncoder().encode(user.userId),
    userName: user.email,
    userDisplayName: user.displayName ?? user.email,
    attestationType: 'none',
    // A device that already holds one of this person's passkeys is not asked twice.
    excludeCredentials: rows.map((row) => ({ id: row.credential_id, transports: row.transports ?? [] })),
    authenticatorSelection: { residentKey: 'required', userVerification: 'preferred' },
  });

  const optionsId = await keepChallenge({
    purpose: 'register',
    challenge: options.challenge,
    userId: user.userId,
    origin: site.origin,
    rpID: site.rpID,
  });
  return { optionsId, options };
};

export const finishRegistration = async ({ userId, optionsId, response, name }) => {
  const { verifyRegistrationResponse } = await webauthn();
  const stored = await takeChallenge(optionsId);
  if (!stored || stored.purpose !== 'register' || stored.userId !== userId) throw expired();

  let verification;
  try {
    verification = await verifyRegistrationResponse({
      response,
      expectedChallenge: stored.challenge,
      expectedOrigin: stored.origin,
      expectedRPID: stored.rpID,
      requireUserVerification: false,
    });
  } catch (cause) {
    log.info({ err: cause, userId }, 'passkey registration refused');
    throw Object.assign(new Error('The passkey could not be verified. Try again.'), { code: 'validation_failed' });
  }
  if (!verification.verified || !verification.registrationInfo) {
    throw Object.assign(new Error('The passkey could not be verified. Try again.'), { code: 'validation_failed' });
  }

  const { credential, credentialDeviceType, credentialBackedUp } = verification.registrationInfo;
  const { rows } = await pool.query(
    `INSERT INTO user_passkeys (user_id, credential_id, public_key, counter, transports,
                                device_type, backed_up, name, rp_id)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
     ON CONFLICT (credential_id) DO NOTHING
     RETURNING id, name, device_type, backed_up, rp_id, created_at, last_used_at`,
    [
      userId,
      credential.id,
      Buffer.from(credential.publicKey),
      credential.counter ?? 0,
      credential.transports ?? response?.response?.transports ?? [],
      credentialDeviceType ?? null,
      Boolean(credentialBackedUp),
      String(name || 'Passkey').slice(0, 60),
      stored.rpID,
    ],
  );
  if (!rows[0]) throw Object.assign(new Error('This passkey is already saved.'), { code: 'conflict' });
  log.info({ userId }, 'passkey added');
  return toPasskey(rows[0]);
};

// ---------------------------------------------------------------------------
// Authentication
// ---------------------------------------------------------------------------

/**
 * Options for a browser to sign with a passkey.
 *   userId set    second step: only this person's passkeys
 *   userId null   sign-in without a password: the browser offers what it has
 */
export const authenticationOptions = async ({ userId = null, requestOrigin, context = null }) => {
  const { generateAuthenticationOptions } = await webauthn();
  const site = relyingParty(requestOrigin);

  let allowCredentials;
  if (userId) {
    const { rows } = await pool.query(
      `SELECT credential_id, transports FROM user_passkeys WHERE user_id = $1 AND rp_id = $2`,
      [userId, site.rpID],
    );
    if (rows.length === 0) {
      throw Object.assign(new Error('No passkey for this site is saved on your account.'), { code: 'not_found' });
    }
    allowCredentials = rows.map((row) => ({ id: row.credential_id, transports: row.transports ?? [] }));
  }

  const options = await generateAuthenticationOptions({
    rpID: site.rpID,
    allowCredentials,
    userVerification: userId ? 'preferred' : 'required',
  });

  const optionsId = await keepChallenge({
    purpose: 'authenticate',
    challenge: options.challenge,
    userId,
    context,
    origin: site.origin,
    rpID: site.rpID,
  });
  return { optionsId, options };
};

/**
 * Checks a signature from the browser.
 * @returns {Promise<{ userId: string, passkeyName: string, context: unknown }>}
 */
export const verifyAuthentication = async ({ optionsId, response }) => {
  const { verifyAuthenticationResponse } = await webauthn();
  const stored = await takeChallenge(optionsId);
  if (!stored || stored.purpose !== 'authenticate') throw expired();

  const { rows } = await pool.query(
    `SELECT id, user_id, credential_id, public_key, counter, transports, name
       FROM user_passkeys WHERE credential_id = $1 AND rp_id = $2`,
    [String(response?.id ?? ''), stored.rpID],
  );
  const row = rows[0];
  const refused = () =>
    Object.assign(new Error('That passkey was not accepted.'), { code: 'unauthenticated' });

  if (!row || (stored.userId && row.user_id !== stored.userId)) throw refused();

  let verification;
  try {
    verification = await verifyAuthenticationResponse({
      response,
      expectedChallenge: stored.challenge,
      expectedOrigin: stored.origin,
      expectedRPID: stored.rpID,
      credential: credentialOf(row),
      requireUserVerification: !stored.userId,
    });
  } catch (cause) {
    log.info({ err: cause }, 'passkey signature refused');
    throw refused();
  }
  if (!verification.verified) throw refused();

  await pool.query(
    `UPDATE user_passkeys SET counter = $2, last_used_at = now() WHERE id = $1`,
    [row.id, verification.authenticationInfo?.newCounter ?? row.counter],
  );
  return { userId: row.user_id, passkeyName: row.name, context: stored.context ?? null };
};

export default {
  available, relyingParty, list, rename, remove,
  registrationOptions, finishRegistration, authenticationOptions, verifyAuthentication,
};
