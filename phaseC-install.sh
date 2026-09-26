#!/usr/bin/env bash
# phaseC-install.sh — Settings, Phase C: password, two-step sign-in, passkeys, your data.
#
# Run from the project folder (the one containing server/, packages/ and apps/):
#   bash phaseC-install.sh
#
# Writes 33 files, patches 5 more, keeps a backup of every file it touches
# in .phaseC-backup/<timestamp>/, installs @simplewebauthn/server and qrcode,
# puts an encryption key for authenticator secrets into .env, checks everything,
# applies migration 023 and restarts API and worker.
# Undo: bash phaseC-install.sh --restore   (back to the state before the first install;
#       the tables added by 023 stay — they are unused without these files)
set -euo pipefail

if [ ! -d server/src/messaging ] || [ ! -d packages/core-client/src ] || [ ! -d apps/web/src ]; then
  echo "Run this from the project folder (the one that contains server/, packages/ and apps/)." >&2
  exit 1
fi

TOUCHED=(
  server/src/db/migrations/023_account_security.sql
  server/src/security/totp.js
  server/src/security/recoveryCodes.js
  server/src/security/secretBox.js
  server/src/security/accountKeys.js
  server/src/security/confirmIdentity.js
  server/src/security/exportSanitize.js
  server/src/identity/secondFactor.js
  server/src/identity/passkeys.js
  server/src/identity/loginChallenge.js
  server/src/identity/dataExport.js
  server/src/identity/accountDeletion.js
  server/src/identity/AuthService.js
  server/src/routes/auth.routes.js
  server/src/routes/accountSecurity.routes.js
  server/src/routes/account.routes.js
  server/src/queues/workers/notificationWorker.js
  server/test/settings/security.check.mjs
  packages/core-client/src/CoreProvider.tsx
  packages/core-client/src/api/accountSecurityApi.ts
  apps/web/src/lib/webauthn.js
  apps/web/src/pages/LoginPage.jsx
  apps/web/src/pages/SettingsPage.jsx
  apps/web/src/pages/AppLayout.jsx
  apps/web/src/components/Settings/ConfirmIdentity.jsx
  apps/web/src/components/Settings/RecoveryCodes.jsx
  apps/web/src/components/Settings/AccountProtection.jsx
  apps/web/src/components/Settings/SecuritySettings.jsx
  apps/web/src/components/Settings/DataSettings.jsx
  apps/web/src/components/Settings/notificationsModel.js
  apps/web/src/components/Settings/__checks__/security.check.mjs
  apps/web/src/components/system/DeletionBanner.jsx
  apps/web/src/components/system/notifications.css
  server/src/app.js
  server/src/signaling/authSocket.js
  packages/core-client/src/index.ts
  apps/web/src/components/Settings/settingsIndex.js
  apps/web/src/components/Settings/settings.css
  server/package.json
  package.json
  package-lock.json
  .env
  server/.env
)

if [ "${1:-}" = "--restore" ]; then
  FIRST=$(ls -1d .phaseC-backup/* 2>/dev/null | head -1 || true)
  [ -n "$FIRST" ] || { echo "No backup found." >&2; exit 1; }
  for f in "${TOUCHED[@]}"; do
    if [ -f "$FIRST/$f" ]; then mkdir -p "$(dirname "$f")"; cp "$FIRST/$f" "$f"; echo "restored $f";
    elif [ -f "$f" ] && [ "$f" != "server/src/db/migrations/023_account_security.sql" ]; then rm "$f"; echo "removed $f (did not exist before)"; fi
  done
  touch server/src/server.js 2>/dev/null || true
  [ -f server/src/worker.js ] && touch server/src/worker.js || true
  echo "Restored from $FIRST. The migration file 023 stays, because the database already has it."
  echo "Accounts that turned on two-step sign-in sign in with the password alone again."
  exit 0
fi

# ---------------------------------------------------------------------------
# Is this the tree Phase C was written for? Nothing is changed if not.
# ---------------------------------------------------------------------------
MISSING=()
need() { # need <file> <text> <why>
  if [ ! -f "$1" ]; then MISSING+=("$1 is missing ($3)");
  elif ! grep -qF -- "$2" "$1"; then MISSING+=("$1 has no '$2' ($3)"); fi
}
need server/src/routes/account.routes.js "readHistory" "Settings Phase B"
need server/src/identity/deviceSessions.js "revokeOthers" "Settings Phase B"
need server/src/security/sessionActivity.js "isRevoked" "Settings Phase B"
need apps/web/src/components/Settings/SecuritySettings.jsx "HistoryList" "Settings Phase B"
need apps/web/src/components/Settings/settingsIndex.js "anchor: 'changes'" "Settings Phase B"
need packages/core-client/src/index.ts "accountApi" "Settings Phase B"
need server/src/identity/AuthService.js "const startSession = async ({ user, device })" "sign-in"
need server/src/identity/User.js "export const validatePassword" "passwords"
need server/src/identity/User.js "export const recordFailedLogin" "passwords"
need server/src/identity/SessionStore.js "export const listSessions" "sessions"
need server/src/routes/auth.routes.js "function issue(res, tokens)" "sign-in routes"
need server/src/signaling/authSocket.js "loadIdentity(claims.userId)" "socket sign-in"
need packages/core-client/src/CoreProvider.tsx "wantsRefreshToken: true" "web sign-in"
need apps/web/src/pages/LoginPage.jsx "signIn" "sign-in page"
need server/src/queues/queues.js "enqueueNotification" "worker queues"
need server/src/app.js "accountRoutes" "route mounting (Phase B)"
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "This tree does not match what Phase C expects. Nothing was changed:" >&2
  for m in "${MISSING[@]}"; do echo "  - $m" >&2; done
  exit 1
fi

BACKUP=".phaseC-backup/$(date +%Y%m%d-%H%M%S)"
for f in "${TOUCHED[@]}"; do
  if [ -f "$f" ]; then mkdir -p "$BACKUP/$(dirname "$f")"; cp "$f" "$BACKUP/$f"; fi
done
echo "backup: $BACKUP"

mkdir -p server/src/db/migrations
cat > server/src/db/migrations/023_account_security.sql <<'__PC_EOF__'
-- 023_account_security.sql  (Settings, Phase C)
--
-- Two-step sign-in, passkeys and scheduled account deletion.
--
--   user_totp                  one authenticator app per account. The secret is
--                              encrypted at rest (security/secretBox.js), never
--                              stored in the clear. last_used_step stops a code
--                              from being used twice.
--   user_recovery_codes        ten single-use codes, stored as SHA-256 hashes:
--                              they are random, so a slow hash adds nothing.
--   user_passkeys              WebAuthn credentials. rp_id records the site the
--                              passkey was made for; a browser will only use it
--                              there.
--   account_deletion_requests  "Delete my account" with a grace period. The
--                              account keeps working until scheduled_for, so
--                              signing in and pressing Cancel undoes it.
--
-- users.status already allows 'deleted', which is what the anonymisation sets.
-- Additive only.

create table if not exists user_totp (
  user_id          uuid        primary key references users (id) on delete cascade,
  secret_encrypted text        not null,
  last_used_step   bigint      not null default 0,
  enabled_at       timestamptz not null default now()
);

create table if not exists user_recovery_codes (
  id         uuid        primary key default gen_random_uuid(),
  user_id    uuid        not null references users (id) on delete cascade,
  code_hash  text        not null,
  used_at    timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists user_recovery_codes_user_idx
  on user_recovery_codes (user_id) where used_at is null;

create table if not exists user_passkeys (
  id            uuid        primary key default gen_random_uuid(),
  user_id       uuid        not null references users (id) on delete cascade,
  credential_id text        not null,
  public_key    bytea       not null,
  counter       bigint      not null default 0,
  transports    text[]      not null default '{}',
  device_type   text,
  backed_up     boolean     not null default false,
  name          text        not null default 'Passkey',
  rp_id         text        not null,
  created_at    timestamptz not null default now(),
  last_used_at  timestamptz,
  constraint user_passkeys_credential_key unique (credential_id)
);

create index if not exists user_passkeys_user_idx on user_passkeys (user_id);

create table if not exists account_deletion_requests (
  user_id       uuid        primary key references users (id) on delete cascade,
  requested_at  timestamptz not null default now(),
  scheduled_for timestamptz not null,
  completed_at  timestamptz
);

create index if not exists account_deletion_due_idx
  on account_deletion_requests (scheduled_for) where completed_at is null;
__PC_EOF__
echo "wrote server/src/db/migrations/023_account_security.sql"

mkdir -p server/src/security
cat > server/src/security/totp.js <<'__PC_EOF__'
// classroom-app/server/src/security/totp.js
/**
 * Time-based one-time passwords (RFC 6238) for authenticator apps
 * (Settings, Phase C).
 *
 * SHA-1, 6 digits, 30 seconds: what every authenticator app understands.
 * Pure, and in Node's standard library — no dependency, and tested against
 * the RFC's own vectors (server/test/settings/security.check.mjs).
 */

import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto';

export const PERIOD_SEC = 30;
export const DIGITS = 6;

const ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/** RFC 4648 base32 without padding, as authenticator apps expect. */
export const base32Encode = (buffer) => {
  let bits = 0;
  let value = 0;
  let output = '';
  for (const byte of buffer) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      output += ALPHABET[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) output += ALPHABET[(value << (5 - bits)) & 31];
  return output;
};

export const base32Decode = (text) => {
  const clean = String(text ?? '').toUpperCase().replace(/[\s=-]/g, '');
  let bits = 0;
  let value = 0;
  const bytes = [];
  for (const char of clean) {
    const index = ALPHABET.indexOf(char);
    if (index === -1) throw new Error('not base32');
    value = (value << 5) | index;
    bits += 5;
    if (bits >= 8) {
      bytes.push((value >>> (bits - 8)) & 255);
      bits -= 8;
    }
  }
  return Buffer.from(bytes);
};

/** 20 random bytes: the size RFC 4226 recommends for SHA-1. */
export const generateSecret = () => base32Encode(randomBytes(20));

export const stepAt = (now = Date.now()) => Math.floor(now / 1000 / PERIOD_SEC);

/** The code for one time step. `digits` is a parameter only for the RFC vectors. */
export const codeAt = (secret, step, digits = DIGITS) => {
  const key = Buffer.isBuffer(secret) ? secret : base32Decode(secret);
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(step));
  const hmac = createHmac('sha1', key).update(counter).digest();
  const offset = hmac[hmac.length - 1] & 0x0f;
  const binary =
    ((hmac[offset] & 0x7f) << 24) |
    ((hmac[offset + 1] & 0xff) << 16) |
    ((hmac[offset + 2] & 0xff) << 8) |
    (hmac[offset + 3] & 0xff);
  return String(binary % 10 ** digits).padStart(digits, '0');
};

const sameCode = (a, b) => a.length === b.length && timingSafeEqual(Buffer.from(a), Buffer.from(b));

/**
 * Accepts the current step and one either side (clock drift of a phone), but
 * never a step at or before `lastUsedStep`: a code that was used once, or an
 * older one, is refused — that is what stops a code seen over someone's
 * shoulder from working a second time.
 *
 * @returns {number|null} the matching step, to be stored as the new lastUsedStep
 */
export const verifyCode = (secret, code, { now = Date.now(), window = 1, lastUsedStep = 0 } = {}) => {
  const clean = String(code ?? '').replace(/\s/g, '');
  if (!/^\d{6}$/.test(clean)) return null;
  const current = stepAt(now);
  for (let offset = -window; offset <= window; offset += 1) {
    const step = current + offset;
    if (step <= lastUsedStep) continue;
    if (sameCode(codeAt(secret, step), clean)) return step;
  }
  return null;
};

/** The link an authenticator app reads from the QR code. */
export const otpauthUri = ({ secret, accountName, issuer = 'Classroom' }) => {
  const label = encodeURIComponent(`${issuer}:${accountName}`);
  const params = new URLSearchParams({
    secret,
    issuer,
    algorithm: 'SHA1',
    digits: String(DIGITS),
    period: String(PERIOD_SEC),
  });
  return `otpauth://totp/${label}?${params.toString()}`;
};

export default { generateSecret, codeAt, verifyCode, otpauthUri, base32Encode, base32Decode, stepAt };
__PC_EOF__
echo "wrote server/src/security/totp.js"

mkdir -p server/src/security
cat > server/src/security/recoveryCodes.js <<'__PC_EOF__'
// classroom-app/server/src/security/recoveryCodes.js
/**
 * Recovery codes  (Settings, Phase C)
 *
 * Ten single-use codes for the day the phone with the authenticator app is
 * lost. Shown once, stored only as hashes. Pure.
 *
 * Format "abcd-efgh": 8 characters from an alphabet without look-alikes
 * (no 0/o, 1/l/i), ~40 bits each — enough for a code that is also
 * rate-limited and single-use.
 */

import { createHash, randomInt } from 'node:crypto';

const ALPHABET = 'abcdefghjkmnpqrstuvwxyz23456789';
export const COUNT = 10;

const one = () => {
  let code = '';
  for (let i = 0; i < 8; i += 1) code += ALPHABET[randomInt(ALPHABET.length)];
  return `${code.slice(0, 4)}-${code.slice(4)}`;
};

export const generateCodes = (count = COUNT) => {
  const codes = new Set();
  while (codes.size < count) codes.add(one());
  return [...codes];
};

/** What someone types — spaces, capitals, a missing dash — to the stored form. */
export const normalizeCode = (input) => {
  const clean = String(input ?? '').toLowerCase().replace(/[^a-z0-9]/g, '');
  if (clean.length !== 8) return null;
  return `${clean.slice(0, 4)}-${clean.slice(4)}`;
};

export const hashCode = (code) => createHash('sha256').update(`classroom-recovery:${code}`).digest('base64url');

/** Looks like a recovery code rather than a 6-digit authenticator code. */
export const looksLikeRecoveryCode = (input) => normalizeCode(input) !== null && !/^\d+$/.test(String(input).trim());

export default { generateCodes, normalizeCode, hashCode, looksLikeRecoveryCode, COUNT };
__PC_EOF__
echo "wrote server/src/security/recoveryCodes.js"

mkdir -p server/src/security
cat > server/src/security/secretBox.js <<'__PC_EOF__'
// classroom-app/server/src/security/secretBox.js
/**
 * Encryption at rest for small secrets  (Settings, Phase C)
 *
 * AES-256-GCM: the authenticator secrets in user_totp are useless to someone
 * who only has a database dump. The key comes from security/accountKeys.js;
 * these functions take it as a parameter, so they stay pure and testable.
 *
 * Format: "v1.<iv>.<tag>.<ciphertext>", each part base64url.
 */

import { createCipheriv, createDecipheriv, hkdfSync, randomBytes } from 'node:crypto';

export const seal = (plaintext, key) => {
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, iv);
  const data = Buffer.concat([cipher.update(String(plaintext), 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return ['v1', iv.toString('base64url'), tag.toString('base64url'), data.toString('base64url')].join('.');
};

export const open = (sealed, key) => {
  const [version, iv, tag, data] = String(sealed ?? '').split('.');
  if (version !== 'v1' || !iv || !tag || data === undefined) throw new Error('not a sealed value');
  const decipher = createDecipheriv('aes-256-gcm', key, Buffer.from(iv, 'base64url'));
  decipher.setAuthTag(Buffer.from(tag, 'base64url'));
  return Buffer.concat([decipher.update(Buffer.from(data, 'base64url')), decipher.final()]).toString('utf8');
};

/** 32 bytes from any secret material, bound to a purpose. */
export const deriveKey = (material, purpose = 'classroom-two-factor') =>
  Buffer.from(hkdfSync('sha256', Buffer.from(String(material)), Buffer.alloc(0), Buffer.from(purpose), 32));

export default { seal, open, deriveKey };
__PC_EOF__
echo "wrote server/src/security/secretBox.js"

mkdir -p server/src/security
cat > server/src/security/accountKeys.js <<'__PC_EOF__'
// classroom-app/server/src/security/accountKeys.js
/**
 * The key that encrypts authenticator secrets  (Settings, Phase C)
 *
 * TWO_FACTOR_ENCRYPTION_KEY (32 bytes, base64) when it is set — the installer
 * writes one into .env. Without it, a key derived from COOKIE_SECRET, so a
 * deployment that has not added the variable yet still works.
 *
 * Keep the key: changing it makes every enabled authenticator app unreadable,
 * and those people then need a recovery code to sign in.
 *
 * Read from process.env, not config/env.js: the variable is not in the env
 * schema, which ops/scripts/check-env-schema.js compares with .env.example.
 * For production, add it to the api role there as a secret.
 */

import { env } from '../config/env.js';
import { deriveKey } from './secretBox.js';

let cached = null;

export const twoFactorKey = () => {
  if (cached) return cached;
  const explicit = process.env.TWO_FACTOR_ENCRYPTION_KEY;
  if (explicit) {
    const decoded = Buffer.from(explicit, 'base64');
    if (decoded.length === 32) {
      cached = decoded;
      return cached;
    }
  }
  const material = env.COOKIE_SECRET ?? process.env.COOKIE_SECRET;
  if (!material) throw Object.assign(new Error('No key for two-step sign-in is configured.'), { code: 'internal_error' });
  cached = deriveKey(material);
  return cached;
};

export default twoFactorKey;
__PC_EOF__
echo "wrote server/src/security/accountKeys.js"

mkdir -p server/src/security
cat > server/src/security/confirmIdentity.js <<'__PC_EOF__'
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
__PC_EOF__
echo "wrote server/src/security/confirmIdentity.js"

mkdir -p server/src/security
cat > server/src/security/exportSanitize.js <<'__PC_EOF__'
// classroom-app/server/src/security/exportSanitize.js
/**
 * What never goes into a data export, whatever table it comes from: password
 * hashes, secrets, tokens, key material. Pure.
 */

const SENSITIVE = /(password|secret|token|hash|private|p256dh|^auth$|public_key|endpoint|fingerprint)/i;

export const stripSensitive = (row) => {
  if (!row || typeof row !== 'object') return row;
  const clean = {};
  for (const [key, value] of Object.entries(row)) {
    if (SENSITIVE.test(key)) continue;
    if (Buffer.isBuffer(value)) continue;
    clean[key] = value instanceof Date ? value.toISOString() : value;
  }
  return clean;
};

/** A file name for the download: classroom-export-2026-09-26.json */
export const exportFileName = (now = new Date()) => `classroom-export-${now.toISOString().slice(0, 10)}.json`;

export default stripSensitive;
__PC_EOF__
echo "wrote server/src/security/exportSanitize.js"

mkdir -p server/src/identity
cat > server/src/identity/secondFactor.js <<'__PC_EOF__'
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
__PC_EOF__
echo "wrote server/src/identity/secondFactor.js"

mkdir -p server/src/identity
cat > server/src/identity/passkeys.js <<'__PC_EOF__'
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
__PC_EOF__
echo "wrote server/src/identity/passkeys.js"

mkdir -p server/src/identity
cat > server/src/identity/loginChallenge.js <<'__PC_EOF__'
// classroom-app/server/src/identity/loginChallenge.js
/**
 * The second step of a sign-in  (Settings, Phase C)
 *
 * After a correct password, someone with two-step sign-in gets a challenge
 * instead of a session. Nothing is signed in yet: no session exists, no token
 * is issued, no socket can open. Only a code or a passkey turns the challenge
 * into a session (AuthService.completeSecondFactor).
 *
 * A challenge lives five minutes and allows five wrong codes; after that the
 * password has to be entered again.
 */

import { randomBytes, createHash } from 'node:crypto';
import { env } from '../config/env.js';
import { stateRedis as redis } from '../db/redis.js';

const TTL_SEC = 5 * 60;
export const MAX_ATTEMPTS = 5;

const key = (challengeId) =>
  `${env.REDIS_PREFIX}:login-challenge:${createHash('sha256').update(String(challengeId)).digest('base64url')}`;

export const create = async ({ userId, device = {} }) => {
  const challengeId = randomBytes(24).toString('base64url');
  await redis.set(key(challengeId), JSON.stringify({ userId, device, attempts: 0 }), 'EX', TTL_SEC);
  return { challengeId, expiresInSec: TTL_SEC };
};

export const read = async (challengeId) => {
  if (!challengeId) return null;
  const raw = await redis.get(key(challengeId));
  return raw ? JSON.parse(raw) : null;
};

/** A wrong code. Returns the attempts left; at zero the challenge is gone. */
export const recordFailure = async (challengeId) => {
  const record = await read(challengeId);
  if (!record) return 0;
  record.attempts += 1;
  const left = MAX_ATTEMPTS - record.attempts;
  if (left <= 0) {
    await redis.del(key(challengeId));
    return 0;
  }
  const ttl = await redis.ttl(key(challengeId));
  await redis.set(key(challengeId), JSON.stringify(record), 'EX', Math.max(ttl, 1));
  return left;
};

/** Used up: a challenge makes exactly one session. */
export const consume = async (challengeId) => {
  const raw = await redis.getdel(key(challengeId));
  return raw ? JSON.parse(raw) : null;
};

export default { create, read, recordFailure, consume, MAX_ATTEMPTS };
__PC_EOF__
echo "wrote server/src/identity/loginChallenge.js"

mkdir -p server/src/identity
cat > server/src/identity/dataExport.js <<'__PC_EOF__'
// classroom-app/server/src/identity/dataExport.js
/**
 * "Download your data"  (Settings, Phase C)
 *
 * Everything the platform keeps about one person, as one JSON document they
 * can read and take elsewhere: the account, the profile and every setting,
 * signed-in devices and history, what they wrote in chats and the community,
 * courses, progress, submissions and notifications.
 *
 * Tables are read by whichever column names the person in them (user_id,
 * author_id, …), looked up in the catalogue rather than assumed, so a table
 * that changes shape still exports — and one that does not exist is listed
 * as unavailable instead of failing the whole download. Secrets never leave
 * (security/exportSanitize.js).
 */

import { pool } from '../db/pool.js';
import { logger } from '../observability/logger.js';
import { stripSensitive } from '../security/exportSanitize.js';

const log = logger.child({ component: 'data-export' });

const ROW_LIMIT = 20_000;

/** Tables, and the columns that point at the person, in order of preference. */
const TABLES = [
  ['messages', ['author_id']],
  ['conversation_participants', ['user_id']],
  ['channel_participants', ['user_id']],
  ['message_receipts', ['user_id']],
  ['threads', ['author_id', 'user_id', 'created_by']],
  ['posts', ['author_id', 'user_id']],
  ['post_reactions', ['user_id']],
  ['space_memberships', ['user_id']],
  ['enrollments', ['user_id']],
  ['lesson_progress', ['user_id']],
  ['course_progress', ['user_id']],
  ['certificates', ['user_id']],
  ['submissions', ['user_id', 'learner_id', 'student_id']],
  ['grades', ['user_id', 'learner_id', 'student_id']],
  ['assets', ['owner_id', 'user_id', 'uploaded_by']],
  ['scheduled_sessions', ['host_id', 'created_by']],
  ['session_invitees', ['user_id']],
  ['notifications', ['user_id']],
  ['notification_preferences', ['user_id']],
  ['blocks', ['user_id']],
  ['chat_mutes', ['user_id']],
  ['web_push_subscriptions', ['user_id']],
  ['devices', ['user_id']],
  ['user_passkeys', ['user_id']],
];

const columnsOf = async () => {
  const { rows } = await pool.query(
    `SELECT table_name, column_name FROM information_schema.columns
      WHERE table_schema = current_schema() AND table_name = ANY($1::text[])`,
    [TABLES.map(([name]) => name)],
  );
  const map = new Map();
  for (const row of rows) {
    if (!map.has(row.table_name)) map.set(row.table_name, new Set());
    map.get(row.table_name).add(row.column_name);
  }
  return map;
};

const readTable = async (table, candidates, columns, userId) => {
  const present = columns.get(table);
  if (!present) return { unavailable: 'not in this database' };
  const owner = candidates.find((column) => present.has(column));
  if (!owner) return { unavailable: 'no column names a person' };
  const order = present.has('created_at') ? ' ORDER BY created_at' : '';
  try {
    // Identifiers come from the catalogue above, never from a request.
    const { rows } = await pool.query(
      `SELECT * FROM "${table}" WHERE "${owner}" = $1${order} LIMIT ${ROW_LIMIT + 1}`,
      [userId],
    );
    return {
      rows: rows.slice(0, ROW_LIMIT).map(stripSensitive),
      truncated: rows.length > ROW_LIMIT,
    };
  } catch (cause) {
    log.warn({ err: cause, table }, 'export: table not read');
    return { unavailable: 'could not be read' };
  }
};

/**
 * @param {{ userId: string }} input
 * @returns {Promise<object>} the document, ready for JSON.stringify
 */
export const buildExport = async ({ userId }) => {
  const Users = await import('./User.js');
  const account = await Users.findById(userId);
  if (!account) throw Object.assign(new Error('No account'), { code: 'not_found' });

  const [profileRows, settings, security, sessions, history, columns] = await Promise.all([
    pool.query(`SELECT * FROM profiles WHERE user_id = $1`, [userId]),
    import('../community/NotificationService.js').then((m) => m.getSettings(userId)).catch(() => null),
    import('./secondFactor.js').then((m) => m.status(userId)).catch(() => null),
    import('./deviceSessions.js').then((m) => m.list(userId)).catch(() => []),
    pool
      .query(
        `SELECT action, metadata, host(ip) AS ip, user_agent, created_at
           FROM audit_log WHERE actor_id = $1 ORDER BY id DESC LIMIT 1000`,
        [userId],
      )
      .then((result) => result.rows.map(stripSensitive))
      .catch(() => []),
    columnsOf(),
  ]);

  const data = {};
  for (const [table, candidates] of TABLES) {
    data[table] = await readTable(table, candidates, columns, userId);
  }

  return {
    format: 'classroom-export/1',
    exportedAt: new Date().toISOString(),
    note: 'Everything Classroom keeps about your account. Passwords, keys and secrets are never included.',
    account,
    profile: profileRows.rows[0] ? stripSensitive(profileRows.rows[0]) : null,
    notificationSettings: settings,
    twoStepSignIn: security
      ? {
          authenticatorApp: security.totp.enabled,
          recoveryCodesRemaining: security.recoveryCodesRemaining,
          passkeys: security.passkeyCount,
        }
      : null,
    signedInDevices: sessions,
    history,
    data,
  };
};

export default buildExport;
__PC_EOF__
echo "wrote server/src/identity/dataExport.js"

mkdir -p server/src/identity
cat > server/src/identity/accountDeletion.js <<'__PC_EOF__'
// classroom-app/server/src/identity/accountDeletion.js
/**
 * Deleting an account  (Settings, Phase C)
 *
 * Two steps, fourteen days apart:
 *
 *   request    every other device is signed out, an email confirms it, and
 *              the account keeps working — signing in and pressing Cancel in
 *              the banner stops the deletion. Nothing is removed yet.
 *
 *   run        after the grace period (notificationWorker, 'account.deletion'):
 *              the account is anonymised, not dropped. Messages, posts,
 *              grades and attendance belong to the courses and chats they
 *              were part of, so they stay, attributed to "Deleted user".
 *              Everything personal goes: email, password, name, profile,
 *              settings, notifications, push registrations, two-step
 *              sign-in, passkeys, blocks, memberships of chats; every
 *              session ends.
 *
 * Every run re-checks the database, so a job that fires twice, or for a
 * request that was cancelled, does nothing.
 */

import { pool } from '../db/pool.js';
import { logger } from '../observability/logger.js';

const log = logger.child({ component: 'account-deletion' });

export const GRACE_DAYS = 14;

const iso = (value) => (value ? new Date(value).toISOString() : null);

export const status = async (userId) => {
  const { rows } = await pool.query(
    `SELECT requested_at, scheduled_for FROM account_deletion_requests
      WHERE user_id = $1 AND completed_at IS NULL`,
    [userId],
  );
  return rows[0] ? { requestedAt: iso(rows[0].requested_at), scheduledFor: iso(rows[0].scheduled_for) } : null;
};

const schedule = async ({ userId, scheduledFor }) => {
  try {
    const { enqueue, QUEUE_NAMES } = await import('../queues/queues.js');
    const at = new Date(scheduledFor).getTime();
    await enqueue(
      QUEUE_NAMES.NOTIFY,
      'account.deletion',
      { userId },
      { jobId: `account-deletion.${userId}.${at}`, delay: Math.max(0, at - Date.now()), attempts: 5 },
    );
  } catch (cause) {
    // The row is the truth; every run of the job also sweeps whatever is due.
    log.error({ err: cause, userId }, 'deletion job not queued');
  }
};

/** Starts the grace period. A second request keeps the first date. */
export const request = async ({ userId, graceDays = GRACE_DAYS }) => {
  const { rows } = await pool.query(
    `INSERT INTO account_deletion_requests (user_id, requested_at, scheduled_for)
     VALUES ($1, now(), now() + ($2 || ' days')::interval)
     ON CONFLICT (user_id) DO UPDATE
        SET requested_at = CASE WHEN account_deletion_requests.completed_at IS NULL
                                 THEN account_deletion_requests.requested_at ELSE now() END,
            scheduled_for = CASE WHEN account_deletion_requests.completed_at IS NULL
                                 THEN account_deletion_requests.scheduled_for
                                 ELSE now() + ($2 || ' days')::interval END,
            completed_at = NULL
     RETURNING requested_at, scheduled_for`,
    [userId, String(graceDays)],
  );
  const result = { requestedAt: iso(rows[0].requested_at), scheduledFor: iso(rows[0].scheduled_for) };
  await schedule({ userId, scheduledFor: result.scheduledFor });
  log.warn({ userId, scheduledFor: result.scheduledFor }, 'account deletion requested');
  return result;
};

export const cancel = async ({ userId }) => {
  const { rowCount } = await pool.query(
    `DELETE FROM account_deletion_requests WHERE user_id = $1 AND completed_at IS NULL`,
    [userId],
  );
  if (rowCount > 0) log.warn({ userId }, 'account deletion cancelled');
  return rowCount > 0;
};

/** Runs a statement; a table or column this database does not have is skipped. */
const optional = async (client, sql, params) => {
  await client.query('SAVEPOINT optional_step');
  try {
    await client.query(sql, params);
    await client.query('RELEASE SAVEPOINT optional_step');
  } catch (cause) {
    await client.query('ROLLBACK TO SAVEPOINT optional_step');
    log.warn({ err: cause.message, sql: sql.split('\n')[0] }, 'deletion step skipped');
  }
};

const anonymise = async (userId) => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const { rows } = await client.query(
      `SELECT 1 FROM account_deletion_requests
        WHERE user_id = $1 AND completed_at IS NULL AND scheduled_for <= now()
        FOR UPDATE`,
      [userId],
    );
    if (!rows[0]) {
      await client.query('ROLLBACK');
      return false;
    }

    await client.query(
      `UPDATE users
          SET email = 'deleted+' || id || '@invalid',
              password_hash = NULL,
              display_name = 'Deleted user',
              status = 'deleted',
              email_verified_at = NULL,
              deleted_at = now(),
              updated_at = now()
        WHERE id = $1`,
      [userId],
    );
    await optional(
      client,
      `UPDATE profiles
          SET handle = 'deleted_' || substr(replace(user_id::text, '-', ''), 1, 12),
              headline = NULL, bio = NULL, links = '[]'::jsonb, avatar_asset_id = NULL,
              preferences = '{}'::jsonb, visibility = 'private', dm_policy = 'nobody',
              show_presence = false, updated_at = now()
        WHERE user_id = $1`,
      [userId],
    );
    for (const sql of [
      `DELETE FROM notification_preferences WHERE user_id = $1`,
      `DELETE FROM notifications WHERE user_id = $1`,
      `DELETE FROM web_push_subscriptions WHERE user_id = $1`,
      `DELETE FROM user_totp WHERE user_id = $1`,
      `DELETE FROM user_recovery_codes WHERE user_id = $1`,
      `DELETE FROM user_passkeys WHERE user_id = $1`,
      `DELETE FROM blocks WHERE user_id = $1 OR blocked_id = $1`,
      `DELETE FROM chat_mutes WHERE user_id = $1`,
      `DELETE FROM devices WHERE user_id = $1`,
      `DELETE FROM calendar_feed_tokens WHERE user_id = $1`,
      `UPDATE conversation_participants SET left_at = coalesce(left_at, now()) WHERE user_id = $1`,
      `DELETE FROM space_memberships WHERE user_id = $1`,
    ]) {
      await optional(client, sql, [userId]);
    }
    await client.query(
      `UPDATE account_deletion_requests SET completed_at = now() WHERE user_id = $1`,
      [userId],
    );
    await client.query('COMMIT');
  } catch (cause) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw cause;
  } finally {
    client.release();
  }

  // Sessions live in Redis: end them after the database agrees.
  try {
    const Sessions = await import('./SessionStore.js');
    await Sessions.revokeAllForUser({ userId, reason: 'account-deleted' });
  } catch (cause) {
    log.warn({ err: cause, userId }, 'sessions not revoked after deletion');
  }
  log.warn({ userId }, 'account anonymised');
  return true;
};

/**
 * Anonymises every account whose grace period is over. Called by the worker
 * for each scheduled job, and it sweeps all due requests, so a job lost in a
 * Redis flush is caught by the next one.
 */
export const runDue = async ({ limit = 50 } = {}) => {
  const { rows } = await pool.query(
    `SELECT user_id FROM account_deletion_requests
      WHERE completed_at IS NULL AND scheduled_for <= now()
      ORDER BY scheduled_for LIMIT $1`,
    [limit],
  );
  let deleted = 0;
  for (const row of rows) {
    try {
      if (await anonymise(row.user_id)) deleted += 1;
    } catch (cause) {
      log.error({ err: cause, userId: row.user_id }, 'account deletion failed; the next run retries');
    }
  }
  return { due: rows.length, deleted };
};

export default { status, request, cancel, runDue, GRACE_DAYS };
__PC_EOF__
echo "wrote server/src/identity/accountDeletion.js"

mkdir -p server/src/identity
cat > server/src/identity/AuthService.js <<'__PC_EOF__'
// classroom-app/server/src/identity/AuthService.js
/**
 * Authentication  (F5)  [NEW]
 *
 * Register, sign in, refresh, sign out. The token design:
 *
 *   access    RS256, fifteen minutes, sent as a bearer header. RS256 rather
 *             than HS256 so the SFU and the realtime service can verify it
 *             with the public key without holding anything that can mint one.
 *
 *   refresh   opaque, thirty days, in an httpOnly cookie on web and secure
 *             storage on mobile. Rotated on every use — see SessionStore.
 *
 * The access token is deliberately small: subject, role, session, expiry.
 * Putting entitlements or a display name in it would mean a plan upgrade or a
 * renamed user taking fifteen minutes to take effect, and a token that is a
 * cache is a cache nobody can invalidate.
 *
 * Two-step sign-in (Settings, Phase C): someone with an authenticator app or
 * a passkey gets a challenge from login() instead of a session. Nothing is
 * signed in until completeSecondFactor() or completeSecondFactorWithPasskey()
 * accepts the second step — no half-signed-in session exists that other code
 * would have to remember to refuse. signInWithPasskey() signs in with a
 * passkey alone (the device checks fingerprint, face or PIN).
 *
 * Timing is treated as a side channel throughout. A sign-in attempt for an
 * address that does not exist still hashes a password, and every failure
 * returns the same message — otherwise the endpoint is a directory of who has
 * an account.
 */

import { randomUUID, randomBytes, timingSafeEqual, createHash } from 'node:crypto';
import { env } from '../config/env.js';
import { logger } from '../observability/logger.js';
import * as Users from './User.js';
import * as Sessions from './SessionStore.js';
import * as Profiles from './Profile.js';
import * as LoginChallenge from './loginChallenge.js';

const log = logger.child({ component: 'auth' });

let keys = null;

/** jose, imported lazily so a process that never verifies a token never loads it. */
const getKeys = async () => {
  if (keys) return keys;

  const { importPKCS8, importSPKI } = await import('jose');

  keys = {
    private: env.JWT_PRIVATE_KEY ? await importPKCS8(env.JWT_PRIVATE_KEY, 'RS256') : null,
    public: env.JWT_PUBLIC_KEY ? await importSPKI(env.JWT_PUBLIC_KEY, 'RS256') : null,
  };

  return keys;
};

/** A generic failure. Never says which half was wrong. */
const invalidCredentials = () =>
  Object.assign(new Error('That email address and password do not match.'), {
    code: 'unauthenticated',
  });

// ---------------------------------------------------------------------------
// Tokens
// ---------------------------------------------------------------------------

/**
 * Claims, and only these. `sid` ties the token to a session so it can be
 * revoked; `jti` identifies this token so it alone can be denied.
 */
export const issueAccessToken = async ({ userId, role, sessionId }) => {
  const { SignJWT } = await import('jose');
  const { private: privateKey } = await getKeys();

  if (!privateKey) {
    throw Object.assign(new Error('token signing is not configured'), { code: 'internal_error' });
  }

  const jti = randomUUID();
  const issuedAt = Math.floor(Date.now() / 1000);

  const token = await new SignJWT({ role, sid: sessionId })
    .setProtectedHeader({ alg: 'RS256', typ: 'JWT' })
    .setSubject(userId)
    .setJti(jti)
    .setIssuer(env.JWT_ISSUER)
    .setAudience(env.JWT_AUDIENCE)
    .setIssuedAt(issuedAt)
    .setExpirationTime(`${Sessions.ACCESS_TTL}s`)
    .sign(privateKey);

  return { token, jti, expiresAt: new Date((issuedAt + Sessions.ACCESS_TTL) * 1000).toISOString() };
};

/**
 * Verifies a token and checks it has not been revoked.
 *
 * The two revocation checks cover different cases: `isRevoked` denies one
 * specific token after a sign-out, and `isIssuedBeforeRevocation` denies every
 * token issued before a password change without listing them individually.
 */
export const verifyAccessToken = async (token) => {
  const { jwtVerify } = await import('jose');
  const { public: publicKey } = await getKeys();

  if (!publicKey) {
    throw Object.assign(new Error('token verification is not configured'), { code: 'internal_error' });
  }

  let payload;
  try {
    ({ payload } = await jwtVerify(token, publicKey, {
      issuer: env.JWT_ISSUER,
      audience: env.JWT_AUDIENCE,
      algorithms: ['RS256'],
      // Small tolerance for clock drift between tasks; larger would widen the
      // window a just-expired token stays usable.
      clockTolerance: 5,
    }));
  } catch (cause) {
    throw Object.assign(new Error('Your session has expired.'), {
      code: 'unauthenticated',
      cause,
    });
  }

  if (await Sessions.isRevoked(payload.jti)) {
    throw Object.assign(new Error('This session was signed out.'), { code: 'token_revoked' });
  }

  if (await Sessions.isIssuedBeforeRevocation({ userId: payload.sub, issuedAtSec: payload.iat })) {
    throw Object.assign(new Error('Please sign in again.'), { code: 'token_revoked' });
  }

  return {
    userId: payload.sub,
    role: payload.role,
    sessionId: payload.sid,
    jti: payload.jti,
    issuedAt: payload.iat,
    expiresAt: payload.exp,
  };
};

/** Opaque and random. A refresh token carries no claims by design. */
const newRefreshToken = () => randomBytes(48).toString('base64url');

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

export const register = async ({ tenantId, email, password, displayName, role, locale, timeZone, device }) => {  const policy = Users.validatePassword(password, { email, displayName });
  if (!policy.valid) {
    throw Object.assign(new Error(policy.errors[0]), {
      code: 'validation_failed',
      errors: policy.errors,
    });
  }

  const user = await Users.create({ tenantId, email, password, displayName, role, locale, timeZone });  await Profiles.createForUser({ userId: user.userId, displayName });

  await sendVerificationEmail({ user }).catch((cause) =>
    log.error({ err: cause, userId: user.userId }, 'verification email not sent'),
  );

  // Signed in immediately. Requiring verification before first use loses people
  // at the exact moment they are most willing to continue; the unverified state
  // gates what matters instead.
  const session = await startSession({ user, device });

  log.info({ userId: user.userId }, 'user registered');
  return { user, ...session };
};

// ---------------------------------------------------------------------------
// Sign in
// ---------------------------------------------------------------------------

export const login = async ({ email, password, device }) => {
  const credentials = await Users.findCredentials(email);

  /**
   * A missing account still costs a hash. Returning immediately would make the
   * response time a reliable oracle for which addresses are registered.
   */
  if (!credentials) {
    await Users.verifyPassword(password, await Users.hashPassword(randomUUID()));
    throw invalidCredentials();
  }

  if (Users.isLocked(credentials)) {
    throw Object.assign(
      new Error('Too many attempts. Try again in a few minutes.'),
      { code: 'rate_limited', retryAfter: 900 },
    );
  }

  if (credentials.status === 'suspended') {
    throw Object.assign(new Error('This account has been suspended.'), { code: 'forbidden' });
  }

  const correct = credentials.passwordHash
    ? await Users.verifyPassword(password, credentials.passwordHash)
    : false;

  if (!correct) {
    await Users.recordFailedLogin(credentials.userId);
    throw invalidCredentials();
  }

  // Opportunistic upgrade when the hashing parameters have been raised since
  // this password was last set. Written directly: Users.updatePassword also
  // signs every device out, which a silent rehash must not do.
  if (Users.needsRehash(credentials.passwordHash)) {
    const { pool } = await import('../db/pool.js');
    await pool
      .query(`UPDATE users SET password_hash = $2 WHERE id = $1`, [credentials.userId, await Users.hashPassword(password)])
      .catch(() => undefined);
  }

  // Two-step sign-in: the password was right, the session waits for the second step.
  const SecondFactor = await import('./secondFactor.js');
  const methods = await SecondFactor.methodsFor(credentials.userId);
  if (methods.length > 0) {
    const { challengeId, expiresInSec } = await LoginChallenge.create({ userId: credentials.userId, device });
    log.info({ userId: credentials.userId, methods }, 'password accepted; second step required');
    return { secondFactorRequired: true, challengeId, methods, expiresInSec };
  }

  await Users.recordSuccessfulLogin(credentials.userId);

  const user = await Users.findById(credentials.userId);
  const session = await startSession({ user, device });

  log.info({ userId: user.userId, platform: device?.platform }, 'signed in');
  return { user, ...session };
};

// ---------------------------------------------------------------------------
// Second step (Settings, Phase C)
// ---------------------------------------------------------------------------

const secondStepFailed = (left) =>
  Object.assign(
    new Error(
      left > 0
        ? `That code is not right. ${left} ${left === 1 ? 'attempt' : 'attempts'} left.`
        : 'Too many wrong codes. Sign in with your password again.',
    ),
    { code: 'unauthenticated', attemptsLeft: left },
  );

const challengeGone = () =>
  Object.assign(new Error('The sign-in took too long. Enter your password again.'), { code: 'unauthenticated' });

const finishSignIn = async ({ userId, device, method }) => {
  const user = await Users.findById(userId);
  if (!user || user.status !== 'active') throw invalidCredentials();
  await Users.recordSuccessfulLogin(userId);
  const session = await startSession({ user, device });
  log.info({ userId, method, platform: device?.platform }, 'signed in');
  return { user, ...session, secondFactor: method };
};

/** A code from the authenticator app, or a recovery code. */
export const completeSecondFactor = async ({ challengeId, code, device }) => {
  const challenge = await LoginChallenge.read(challengeId);
  if (!challenge) throw challengeGone();

  const SecondFactor = await import('./secondFactor.js');
  const method = await SecondFactor.verifyCode({ userId: challenge.userId, code });
  if (!method) throw secondStepFailed(await LoginChallenge.recordFailure(challengeId));

  if (!(await LoginChallenge.consume(challengeId))) throw challengeGone();
  return finishSignIn({ userId: challenge.userId, device: device ?? challenge.device, method });
};

/** Options for a passkey as the second step of this sign-in. */
export const secondFactorPasskeyOptions = async ({ challengeId, requestOrigin }) => {
  const challenge = await LoginChallenge.read(challengeId);
  if (!challenge) throw challengeGone();
  const Passkeys = await import('./passkeys.js');
  return Passkeys.authenticationOptions({ userId: challenge.userId, requestOrigin, context: { challengeId } });
};

export const completeSecondFactorWithPasskey = async ({ challengeId, optionsId, response, device }) => {
  const challenge = await LoginChallenge.read(challengeId);
  if (!challenge) throw challengeGone();

  const Passkeys = await import('./passkeys.js');
  let verified;
  try {
    verified = await Passkeys.verifyAuthentication({ optionsId, response });
  } catch (cause) {
    await LoginChallenge.recordFailure(challengeId);
    throw cause;
  }
  if (verified.userId !== challenge.userId || verified.context?.challengeId !== challengeId) {
    throw secondStepFailed(await LoginChallenge.recordFailure(challengeId));
  }
  if (!(await LoginChallenge.consume(challengeId))) throw challengeGone();
  return finishSignIn({ userId: challenge.userId, device: device ?? challenge.device, method: 'passkey' });
};

/** Sign in with a passkey alone. */
export const passkeySignInOptions = async ({ requestOrigin }) => {
  const Passkeys = await import('./passkeys.js');
  return Passkeys.authenticationOptions({ userId: null, requestOrigin });
};

export const signInWithPasskey = async ({ optionsId, response, device }) => {
  const Passkeys = await import('./passkeys.js');
  const verified = await Passkeys.verifyAuthentication({ optionsId, response });
  const { pool } = await import('../db/pool.js');
  const { rows } = await pool.query(`SELECT status FROM users WHERE id = $1 AND deleted_at IS NULL`, [verified.userId]);
  if (rows[0]?.status === 'suspended') {
    throw Object.assign(new Error('This account has been suspended.'), { code: 'forbidden' });
  }
  return finishSignIn({ userId: verified.userId, device, method: 'passkey-only' });
};

const startSession = async ({ user, device }) => {
  const refreshToken = newRefreshToken();
  const { sessionId } = await Sessions.createSession({
    userId: user.userId,
    refreshToken,
    device,
  });

  const access = await issueAccessToken({
    userId: user.userId,
    role: user.role,
    sessionId,
  });

  return {
    accessToken: access.token,
    accessTokenExpiresAt: access.expiresAt,
    refreshToken,
    sessionId,
  };
};

// ---------------------------------------------------------------------------
// Refresh
// ---------------------------------------------------------------------------

/**
 * Exchanges a refresh token for a new pair. The old refresh token stops working
 * the moment this succeeds.
 */
export const refresh = async ({ sessionId, refreshToken, device }) => {
  const nextToken = newRefreshToken();

  const result = await Sessions.rotate({
    sessionId,
    presentedToken: refreshToken,
    newToken: nextToken,
    device,
  });

  if (!result.ok) {
    // Both failures look identical from outside. Telling a caller that their
    // token was reused tells an attacker they have been noticed.
    throw Object.assign(new Error('Please sign in again.'), { code: 'token_revoked' });
  }

  const user = await Users.findById(result.userId);
  if (!user || user.status !== 'active') {
    await Sessions.revokeSession({ sessionId, reason: 'account-inactive' });
    throw Object.assign(new Error('Please sign in again.'), { code: 'token_revoked' });
  }

  const access = await issueAccessToken({
    userId: user.userId,
    // Read fresh, not carried over: a role change takes effect on the next
    // refresh rather than in thirty days.
    role: user.role,
    sessionId,
  });

  return {
    // The caller writes this back into the cookie, and Sessions.rotate needs it
    // on the next refresh to find the family. Omitting it produced a cookie
    // reading "undefined.<token>", which then failed every rotation.
    sessionId,
    accessToken: access.token,
    accessTokenExpiresAt: access.expiresAt,
    refreshToken: nextToken,
    user,
  };
};

// ---------------------------------------------------------------------------
// Sign out
// ---------------------------------------------------------------------------

export const logout = async ({ sessionId, jti, accessTokenExpiresAt }) => {
  if (jti && accessTokenExpiresAt) {
    // The access token has minutes left; deny it rather than waiting.
    await Sessions.revokeAccessToken({ jti, expiresAt: accessTokenExpiresAt });
  }
  if (sessionId) await Sessions.revokeSession({ sessionId, reason: 'signed-out' });
  return true;
};

export const logoutEverywhere = async ({ userId, exceptSessionId = null }) => {
  const revoked = await Sessions.revokeAllForUser({
    userId,
    reason: 'signed-out-everywhere',
    exceptSessionId,
  });
  return { revoked };
};

export const listDevices = (userId) => Sessions.listSessions(userId);

/**
 * GET /auth/me. auth.routes has called this since v6; it did not exist, so
 * the route answered 500.
 */
export const describeSession = async ({ userId, sessionId }) => {
  const [user, session] = await Promise.all([Users.findById(userId), sessionId ? Sessions.getSession(sessionId) : null]);
  if (!user) throw Object.assign(new Error('Sign in to continue.'), { code: 'unauthenticated' });
  return {
    user,
    session: session
      ? {
          sessionId,
          device: session.device ?? null,
          createdAt: session.createdAt ? new Date(session.createdAt).toISOString() : null,
          lastUsedAt: session.lastUsedAt ? new Date(session.lastUsedAt).toISOString() : null,
        }
      : { sessionId: sessionId ?? null },
  };
};

/**
 * DELETE /auth/devices/:deviceId, also called since v6 and also missing.
 * Accepts a session id and signs that session out, the same way Settings →
 * Sign-in & devices does.
 */
export const revokeDeviceSession = async (userId, sessionId) => {
  const { revoke } = await import('./deviceSessions.js');
  const result = await revoke({ userId, sessionId });
  if (!result) throw Object.assign(new Error('No such device.'), { code: 'not_found' });
  return true;
};

// ---------------------------------------------------------------------------
// Email verification and password reset
// ---------------------------------------------------------------------------

/** Single-use, hashed at rest, short-lived. */
const issueToken = async ({ userId, purpose, ttlSec }) => {
  const token = randomBytes(32).toString('base64url');
  const { stateRedis: redis } = await import('../db/redis.js');

  await redis.set(
    `${env.REDIS_PREFIX}:token:${purpose}:${createHash('sha256').update(token).digest('base64url')}`,
    userId,
    'EX',
    ttlSec,
  );

  return token;
};

const consumeToken = async ({ token, purpose }) => {
  const { stateRedis: redis } = await import('../db/redis.js');
  const key = `${env.REDIS_PREFIX}:token:${purpose}:${createHash('sha256').update(token).digest('base64url')}`;

  // GETDEL: read and consume atomically, so a token cannot be used twice by two
  // requests arriving together.
  const userId = await redis.getdel(key);
  return userId ?? null;
};

const sendVerificationEmail = async ({ user }) => {
  const token = await issueToken({ userId: user.userId, purpose: 'verify', ttlSec: 86_400 });
  const { enqueueNotification } = await import('../queues/queues.js');

  await enqueueNotification('notification.email', {
    userId: user.userId,
    type: 'email.verify',
    title: 'Confirm your email address',
    href: `${env.APP_URL}/verify-email?token=${token}`,
  });
};

export const verifyEmail = async ({ token }) => {
  const userId = await consumeToken({ token, purpose: 'verify' });
  if (!userId) {
    throw Object.assign(new Error('That link has expired.'), { code: 'not_found' });
  }
  await Users.verifyEmail(userId);
  return { userId };
};

/**
 * Always reports success, whether or not the address exists. Anything else is
 * an account-enumeration endpoint that nobody has to authenticate to use.
 */
export const requestPasswordReset = async ({ email }) => {
  const user = await Users.findByEmail(email);

  if (user) {
    const token = await issueToken({ userId: user.userId, purpose: 'reset', ttlSec: 3_600 });
    const { enqueueNotification } = await import('../queues/queues.js');

    await enqueueNotification('notification.email', {
      userId: user.userId,
      type: 'password.reset',
      title: 'Reset your password',
      href: `${env.APP_URL}/reset-password?token=${token}`,
    }).catch((cause) => log.error({ err: cause }, 'reset email not queued'));
  }

  return { sent: true };
};

export const resetPassword = async ({ token, password }) => {
  const userId = await consumeToken({ token, purpose: 'reset' });
  if (!userId) {
    throw Object.assign(new Error('That link has expired.'), { code: 'not_found' });
  }

  const user = await Users.findById(userId);
  const policy = Users.validatePassword(password, { email: user.email, displayName: user.displayName });

  if (!policy.valid) {
    throw Object.assign(new Error(policy.errors[0]), { code: 'validation_failed', errors: policy.errors });
  }

  // updatePassword revokes every session, which is the point of a reset.
  await Users.updatePassword({ userId, password });

  log.info({ userId }, 'password reset');
  return { userId };
};

/**
 * Changing a password requires the current one, even while signed in.
 * v6 path: signs every device out, this one included. Settings uses
 * security/passwordChange.js, which keeps this device signed in.
 */
export const changePassword = async ({ userId, currentPassword, newPassword }) => {
  const user = await Users.findById(userId);
  const credentials = await Users.findCredentials(user.email);

  const correct = await Users.verifyPassword(currentPassword, credentials.passwordHash);
  if (!correct) throw invalidCredentials();

  const policy = Users.validatePassword(newPassword, { email: user.email, displayName: user.displayName });
  if (!policy.valid) {
    throw Object.assign(new Error(policy.errors[0]), { code: 'validation_failed', errors: policy.errors });
  }

  await Users.updatePassword({ userId, password: newPassword });
  return { userId };
};

/** Compares two secrets in constant time. Exported for the CSRF middleware. */
export const safeEqual = (a, b) => {
  const left = Buffer.from(String(a));
  const right = Buffer.from(String(b));
  return left.length === right.length && timingSafeEqual(left, right);
};

export default {
  register, login, refresh, logout, logoutEverywhere, listDevices,
  issueAccessToken, verifyAccessToken, verifyEmail, requestPasswordReset,
  resetPassword, changePassword, describeSession, revokeDeviceSession,
  completeSecondFactor, secondFactorPasskeyOptions, completeSecondFactorWithPasskey,
  passkeySignInOptions, signInWithPasskey,
};
__PC_EOF__
echo "wrote server/src/identity/AuthService.js"

mkdir -p server/src/routes
cat > server/src/routes/auth.routes.js <<'__PC_EOF__'
/**
 * auth.routes — login · second step · passkeys · refresh · logout · devices (F5, Settings Phase C)
 *
 * Phase C: POST /login answers { secondFactorRequired, challengeId, methods }
 * instead of tokens when the account has two-step sign-in. The session is
 * created only by the second step:
 *
 *   POST /login/second-factor                   { challengeId, code }
 *   POST /login/second-factor/passkey/options   { challengeId }
 *   POST /login/second-factor/passkey           { challengeId, optionsId, response }
 *   POST /passkey/options                       sign in with a passkey alone
 *   POST /passkey                               { optionsId, response }
 *
 * All of them answer exactly like /login (cookie, body, wantsRefreshToken).
 *
 * The split that matters here: the API is bearer-token based, but the refresh
 * token lives in an httpOnly, SameSite=Strict cookie. That is why CSRF
 * protection applies to exactly one group of routes — the cookie-authenticated
 * ones — and nowhere else. A bearer endpoint cannot be CSRF'd; a cookie
 * endpoint can.
 *
 * Those routes are listed in securityConfig.csrf.protectedPaths and guarded by
 * the single `csrfProtection()` mounted in app.js. This file deliberately does
 * not mount it again: csrfProtection is a *factory*, and passing the factory
 * itself into a middleware chain makes Express call it with (req, res, next),
 * whereupon it ignores all three, returns the real middleware, and never calls
 * next — so the request hangs until the client times out.
 *
 *  - Access tokens are short-lived RS256, so the SFU can verify them with the
 *    public key without ever holding the signing key.
 *  - Refresh tokens rotate on every use and are bound to a device session.
 *    Reuse of an already-rotated token is treated as theft: the whole session
 *    family is revoked.
 *  - Logout revokes server-side (SessionStore), because "the client deleted the
 *    token" is not a security property.
 *
 * Rate limits here are stricter than the global ones — credential stuffing is
 * the whole point of this file's existence.
 */

import { Router } from 'express';
import { z } from 'zod';

import * as AuthService from '../identity/AuthService.js';
import * as DeviceRegistry from '../identity/DeviceRegistry.js';
import { env } from '../config/env.js';
import { rateLimit } from '../middleware/rateLimit.js';
import { auditFromRequest } from '../security/auditLog.js';
import { route, validate, requireAuth, noStore, unauthorised } from './_helpers.js';

const router = Router();

const REFRESH_COOKIE = 'cp_refresh';

const DURATION_UNITS = { s: 1_000, m: 60_000, h: 3_600_000, d: 86_400_000 };

/**
 * '30d' -> 2592000000.
 *
 * env.REFRESH_TTL is a duration *string* — config/env.js validates it against
 * /^\d+[smhd]$/ and hands it over unparsed. Multiplying it by 1000 yields NaN,
 * and a cookie with Max-Age=NaN is one the browser discards, which shows up
 * later as "signing in works but a reload signs me out".
 */
const toMilliseconds = (value) => {
  const amount = Number.parseInt(value, 10);
  return amount * DURATION_UNITS[value.at(-1)];
};

const refreshCookieOptions = () => ({
  httpOnly: true,
  secure: env.NODE_ENV === 'production',
  // 'lax' rather than 'strict': a strict cookie is withheld on any request that
  // began as a navigation, so arriving at the app from a link or a calendar
  // invite would look exactly like being signed out. Lax still refuses to send
  // it on a cross-site POST, which is the case CSRF actually cares about.
  sameSite: 'lax',
  // The whole app, not just /auth. Scoping it to /auth means the browser never
  // attaches it to anything else — which is fine in principle, but it also
  // means a stale or missing cookie is invisible everywhere else in the app.
  path: '/',
  maxAge: toMilliseconds(env.REFRESH_TTL),
  signed: true,
});

const deviceSchema = z.object({
  deviceId: z.string().max(128).optional(),
  platform: z.enum(['web', 'ios', 'android']).default('web'),
  model: z.string().max(128).optional(),
  appVersion: z.string().max(32).optional(),
});

/**
 * AuthService.refresh needs the session id as well as the token — Sessions.rotate
 * looks the family up by id and compares the presented token against it. The
 * cookie therefore carries both, joined by a dot: a uuid contains none and a
 * base64url token contains none, so the split is unambiguous.
 */
function issue(res, tokens) {
  const cookieValue = `${tokens.sessionId}.${tokens.refreshToken}`;
  res.cookie(REFRESH_COOKIE, cookieValue, refreshCookieOptions());
  noStore(res);
  return {
    accessToken: tokens.accessToken,
    expiresIn: tokens.expiresIn,
    tokenType: 'Bearer',
    user: tokens.user,
    // The refresh token is never in the body on web. Mobile asks for it
    // explicitly below.
  };
}

/* ------------------------------------------------------------------ *
 * CSRF bootstrap
 * ------------------------------------------------------------------ */

/**
 * Hands out the double-submit token.
 *
 * The SPA is served from CloudFront and the API from a different origin, so a
 * page load never touches this server and the CSRF cookie is never issued as a
 * side effect of one. Without a route that does it deliberately, a client's
 * very first call to /auth/refresh arrives with no cookie and is rejected — on
 * every cold start, for every visitor.
 *
 * GET is in csrfConfig.ignoredMethods, so this passes the check it bootstraps.
 * The middleware has already put the value — existing or freshly minted — on
 * req.csrfToken and the Set-Cookie on the response; this only returns it, so
 * the client never has to know the cookie's name.
 */
router.get(
  '/csrf',
  route(async (req, res) => {
    noStore(res);
    return { csrfToken: req.csrfToken ?? null };
  }),
);

/* ------------------------------------------------------------------ *
 * Credentials
 * ------------------------------------------------------------------ */

router.post(
  '/login',
  rateLimit({ key: 'auth:login', points: 10, durationSec: 300, by: ['ip', 'body.email'] }),
  validate({
    body: z.object({
      email: z.string().email(),
      password: z.string().min(1).max(512),
      device: deviceSchema.optional(),
      // Mobile cannot use a cookie; it gets the refresh token in the body.
      wantsRefreshToken: z.boolean().default(false),
    }),
  }),
  route(async (req, res) => {
    const tokens = await AuthService.login({
      email: req.body.email,
      password: req.body.password,
      device: req.body.device ?? { platform: 'web' },
      ip: req.ip,
      userAgent: req.get('user-agent') ?? null,
    });

    // Two-step sign-in: no cookie, no token — only the challenge.
    if (tokens.secondFactorRequired) {
      noStore(res);
      return {
        secondFactorRequired: true,
        challengeId: tokens.challengeId,
        methods: tokens.methods,
        expiresInSec: tokens.expiresInSec,
      };
    }

    return respondWithSession(req, res, tokens);
  }),
);

/** Tokens as /login has always answered them. */
function respondWithSession(req, res, tokens) {
  const body = issue(res, tokens);
  if (req.body?.wantsRefreshToken) {
    body.refreshToken = tokens.refreshToken;
    // The client needs this to refresh; Sessions.rotate looks the family up
    // by id, not by token.
    body.sessionId = tokens.sessionId;
  }
  return body;
}

/** A refused second step, recorded on the account it was for, so its owner sees it. */
const auditSecondStepFailure = async (req, challengeId, method) => {
  try {
    const { read } = await import('../identity/loginChallenge.js');
    const challenge = await read(challengeId);
    if (!challenge?.userId) return;
    const asAccount = Object.create(req);
    asAccount.user = { id: challenge.userId, userId: challenge.userId };
    await auditFromRequest(asAccount, {
      action: 'auth.second_factor.failed',
      targetType: 'user',
      targetId: challenge.userId,
      metadata: { method },
    });
  } catch {
    // History is best effort; the refusal itself already happened.
  }
};

const secondStepBody = z.object({
  challengeId: z.string().min(16).max(128),
  device: deviceSchema.optional(),
  wantsRefreshToken: z.boolean().default(false),
});

router.post(
  '/login/second-factor',
  rateLimit({ key: 'auth:second-factor', points: 20, durationSec: 300, by: ['ip'] }),
  validate({ body: secondStepBody.extend({ code: z.string().min(6).max(20) }) }),
  route(async (req, res) => {
    let tokens;
    try {
      tokens = await AuthService.completeSecondFactor({
        challengeId: req.body.challengeId,
        code: req.body.code,
        device: req.body.device,
      });
    } catch (error) {
      if (error?.code === 'unauthenticated') await auditSecondStepFailure(req, req.body.challengeId, 'code');
      throw error;
    }
    return respondWithSession(req, res, tokens);
  }),
);

router.post(
  '/login/second-factor/passkey/options',
  rateLimit({ key: 'auth:passkey-options', points: 30, durationSec: 300, by: ['ip'] }),
  validate({ body: z.object({ challengeId: z.string().min(16).max(128) }) }),
  route(async (req, res) => {
    noStore(res);
    return AuthService.secondFactorPasskeyOptions({
      challengeId: req.body.challengeId,
      requestOrigin: req.get('origin') ?? null,
    });
  }),
);

const passkeyResponse = z.object({ id: z.string().min(1).max(1024) }).passthrough();

router.post(
  '/login/second-factor/passkey',
  rateLimit({ key: 'auth:second-factor', points: 20, durationSec: 300, by: ['ip'] }),
  validate({ body: secondStepBody.extend({ optionsId: z.string().uuid(), response: passkeyResponse }) }),
  route(async (req, res) => {
    let tokens;
    try {
      tokens = await AuthService.completeSecondFactorWithPasskey({
        challengeId: req.body.challengeId,
        optionsId: req.body.optionsId,
        response: req.body.response,
        device: req.body.device,
      });
    } catch (error) {
      if (error?.code === 'unauthenticated') await auditSecondStepFailure(req, req.body.challengeId, 'passkey');
      throw error;
    }
    return respondWithSession(req, res, tokens);
  }),
);

/** Sign in with a passkey alone: the browser offers the passkeys it holds for this site. */
router.post(
  '/passkey/options',
  rateLimit({ key: 'auth:passkey-options', points: 30, durationSec: 300, by: ['ip'] }),
  route(async (req, res) => {
    noStore(res);
    return AuthService.passkeySignInOptions({ requestOrigin: req.get('origin') ?? null });
  }),
);

router.post(
  '/passkey',
  rateLimit({ key: 'auth:login', points: 10, durationSec: 300, by: ['ip'] }),
  validate({
    body: z.object({
      optionsId: z.string().uuid(),
      response: passkeyResponse,
      device: deviceSchema.optional(),
      wantsRefreshToken: z.boolean().default(false),
    }),
  }),
  route(async (req, res) => {
    const tokens = await AuthService.signInWithPasskey({
      optionsId: req.body.optionsId,
      response: req.body.response,
      device: req.body.device ?? { platform: 'web' },
    });
    return respondWithSession(req, res, tokens);
  }),
);

/**
 * Cookie route. CSRF is enforced by the global csrfProtection() in app.js,
 * which covers every path in securityConfig.csrf.protectedPaths. Mobile sends
 * the refresh token in the body and skips the cookie path entirely.
 */
router.post(
  '/refresh',
  rateLimit({ key: 'auth:refresh', points: 60, durationSec: 300, by: ['ip'] }),
  validate({ body: z.object({ refreshToken: z.string().min(1).optional() }).default({}) }),
  route(async (req, res) => {
    const presented = req.body.refreshToken ?? req.signedCookies?.[REFRESH_COOKIE];
    if (!presented) throw unauthorised('No refresh token presented');

    // Mobile sends a bare token in the body and its session id beside it; web
    // sends the combined cookie.
    const dot = presented.indexOf('.');
    const sessionId = req.body.sessionId ?? (dot > 0 ? presented.slice(0, dot) : null);
    const refreshToken = dot > 0 ? presented.slice(dot + 1) : presented;

    if (!sessionId) throw unauthorised('No session presented');

    // The export is `refresh`. Rotation is what it does, not what it is called.
    let tokens;
    try {
      tokens = await AuthService.refresh({
        sessionId,
        refreshToken,
        device: req.body.device ?? { platform: 'web' },
      });
    } catch (error) {
      if (error?.code === 'token_revoked' || error?.code === 'unauthenticated') {
        res.clearCookie(REFRESH_COOKIE, { ...refreshCookieOptions(), maxAge: undefined });
      }
      throw error;
    }

    const body = issue(res, tokens);
    if (req.body.refreshToken) body.refreshToken = tokens.refreshToken;
    return body;
  }),
);

router.post(
  '/logout',
  route(async (req, res) => {
    const presented = req.body?.refreshToken ?? req.signedCookies?.[REFRESH_COOKIE];
    const dot = presented?.indexOf('.') ?? -1;
    const sessionId = dot > 0 ? presented.slice(0, dot) : null;

    // `logout`, not `revokeSession` — and it takes the session, not the token.
    if (sessionId) {
      await AuthService.logout({
        sessionId,
        jti: req.user?.jti ?? null,
        accessTokenExpiresAt: req.user?.expiresAt ?? null,
      }).catch(() => {});
    }
    res.clearCookie(REFRESH_COOKIE, { ...refreshCookieOptions(), maxAge: undefined });
    noStore(res);
    return { loggedOut: true };
  }),
);

/** Every device, everywhere — the "I lost my phone" button. */
router.post(
  '/logout-all',
  requireAuth,
  route(async (req, res) => {
    const revoked = await AuthService.logoutEverywhere({ userId: req.user.id });
    res.clearCookie(REFRESH_COOKIE, { ...refreshCookieOptions(), maxAge: undefined });
    noStore(res);
    return { revoked };
  }),
);

/* ------------------------------------------------------------------ *
 * Device sessions and push tokens
 * ------------------------------------------------------------------ */

router.get(
  '/devices',
  requireAuth,
  route(async (req, res) => {
    noStore(res);
    return { devices: await DeviceRegistry.listForUser(req.user.id) };
  }),
);

router.delete(
  '/devices/:deviceId',
  requireAuth,
  validate({ params: z.object({ deviceId: z.string().max(128) }) }),
  route(async (req) => {
    await AuthService.revokeDeviceSession(req.user.id, req.params.deviceId);
    return null;
  }),
);

router.put(
  '/devices/push-token',
  requireAuth,
  validate({
    body: z.object({
      deviceId: z.string().max(128),
      platform: z.enum(['ios', 'android', 'web']),
      token: z.string().min(1).max(512),
    }),
  }),
  route(async (req) => {
    const registration = await DeviceRegistry.upsertPushToken({
      userId: req.user.id,
      ...req.body,
    });
    return { registered: true, endpointArn: registration.endpointArn ?? null };
  }),
);

/** Who am I — cheap enough to call on app boot, and it proves the token is live. */
router.get(
  '/me',
  requireAuth,
  route(async (req, res) => {
    noStore(res);
    return AuthService.describeSession({ userId: req.user.id, sessionId: req.user.sessionId });
  }),
);

export default router;
__PC_EOF__
echo "wrote server/src/routes/auth.routes.js"

mkdir -p server/src/routes
cat > server/src/routes/accountSecurity.routes.js <<'__PC_EOF__'
/**
 * accountSecurity.routes — password · two-step sign-in · passkeys · your data
 * (Settings, Phase C)
 *
 * Mounted under /account/security (app.js). Everything is about the person
 * asking; no route takes someone else's id.
 *
 *   GET    /                               what is set up, and a pending deletion
 *   POST   /password                       { currentPassword, newPassword, signOutOthers }
 *   POST   /totp/setup                     { password | code } → a new secret and its QR code
 *   POST   /totp/enable                    { code } → recovery codes, shown once
 *   POST   /totp/disable                   { password | code }
 *   POST   /recovery-codes                 { password | code } → a new set
 *   POST   /passkeys/options               { password | code } → registration options
 *   POST   /passkeys                       { optionsId, response, name }
 *   PATCH  /passkeys/:id                   { name }
 *   POST   /passkeys/:id/remove            { password | code }
 *   GET    /export                         everything, as one JSON document
 *   POST   /deletion                       { password | code } → deletion in 14 days
 *   POST   /deletion/cancel                stops it
 *
 * "{ password | code }" is security/confirmIdentity.js: a signed-in browser
 * alone is not enough to switch protection off or delete an account.
 *
 * Every change is recorded (Recent changes), announced to the person's other
 * tabs (settings:changed) and, where it matters for someone whose account is
 * being taken over, confirmed by email.
 */

import { Router } from 'express';
import { z } from 'zod';

import { pool } from '../db/pool.js';
import * as Users from '../identity/User.js';
import * as SecondFactor from '../identity/secondFactor.js';
import * as Passkeys from '../identity/passkeys.js';
import * as DeviceSessions from '../identity/deviceSessions.js';
import * as AccountDeletion from '../identity/accountDeletion.js';
import { buildExport } from '../identity/dataExport.js';
import { confirmIdentity } from '../security/confirmIdentity.js';
import { exportFileName } from '../security/exportSanitize.js';
import { auditFromRequest } from '../security/auditLog.js';
import { pushToUser } from '../realtime/userEvents.js';
import { rateLimit } from '../middleware/rateLimit.js';
import { logger } from '../observability/logger.js';
import { route, validate, requireAuth, notFound, badRequest, forbidden } from './_helpers.js';

const log = logger.child({ component: 'account-security' });

const router = Router();
router.use(requireAuth);

/** Errors the services raise with a code, as the HTTP answers clients understand. */
const asHttp = (fn) => async (req, res) => {
  try {
    return await fn(req, res);
  } catch (error) {
    switch (error?.code) {
      case 'validation_failed':
        throw badRequest(error.message);
      case 'forbidden':
        throw forbidden(error.message);
      case 'not_found':
        throw notFound(error.message);
      case 'conflict':
        throw Object.assign(badRequest(error.message), { status: 409 });
      default:
        throw error;
    }
  }
};

const handle = (fn) => route(asHttp(fn));

/** Recorded in the history, announced to other tabs; neither may fail the change. */
const recordSecurity = async (req, action, metadata = {}) => {
  try {
    await auditFromRequest(req, { action, targetType: 'user', targetId: req.user.id, metadata });
  } catch (cause) {
    log.warn({ err: cause, action }, 'security change not audited');
  }
  await pushToUser(req.user.id, 'settings:changed', { section: 'security', fields: [action] });
};

/** An email to the account's own address: the alarm if it was not them. */
const alertByEmail = async (userId, kind, title) => {
  try {
    const { enqueueNotification } = await import('../queues/queues.js');
    await enqueueNotification('notification.email', { userId, type: kind, kind, title, href: '/settings/security' });
  } catch (cause) {
    log.warn({ err: cause, kind }, 'security email not queued');
  }
};

const confirmBody = z
  .object({ password: z.string().min(1).max(512).optional(), code: z.string().min(6).max(20).optional() })
  .passthrough();

const confirm = (req) =>
  confirmIdentity({ userId: req.user.id, password: req.body?.password, code: req.body?.code });

const confirmLimit = rateLimit({ key: 'account:confirm', points: 15, durationSec: 900, by: ['user'] });

/* ------------------------------------------------------------------ *
 * Overview
 * ------------------------------------------------------------------ */

const overview = async (userId) => {
  const [{ rows }, twoStep, passkeys, passkeysAvailable, deletion] = await Promise.all([
    pool.query(`SELECT password_hash IS NOT NULL AS has_password, password_changed_at FROM users WHERE id = $1`, [userId]),
    SecondFactor.status(userId),
    Passkeys.list(userId),
    Passkeys.available(),
    AccountDeletion.status(userId),
  ]);
  return {
    password: {
      set: Boolean(rows[0]?.has_password),
      changedAt: rows[0]?.password_changed_at ? new Date(rows[0].password_changed_at).toISOString() : null,
    },
    twoStep,
    passkeys: { available: passkeysAvailable, items: passkeys },
    deletion,
  };
};

router.get(
  '/',
  route(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    return overview(req.user.id);
  }),
);

/* ------------------------------------------------------------------ *
 * Password
 * ------------------------------------------------------------------ */

router.post(
  '/password',
  confirmLimit,
  validate({
    body: z.object({
      currentPassword: z.string().min(1).max(512),
      newPassword: z.string().min(1).max(512),
      signOutOthers: z.boolean().default(true),
    }),
  }),
  handle(async (req) => {
    const userId = req.user.id;
    await confirmIdentity({ userId, password: req.body.currentPassword });

    if (req.body.newPassword === req.body.currentPassword) {
      throw badRequest('The new password has to be different from the current one.');
    }
    const user = await Users.findById(userId);
    const policy = Users.validatePassword(req.body.newPassword, { email: user.email, displayName: user.displayName });
    if (!policy.valid) throw badRequest(policy.errors[0]);

    // Directly rather than Users.updatePassword, which also signs this very
    // device out: here the person just proved who they are.
    await pool.query(
      `UPDATE users SET password_hash = $2, password_changed_at = now(),
              failed_attempts = 0, locked_until = NULL, updated_at = now()
        WHERE id = $1`,
      [userId, await Users.hashPassword(req.body.newPassword)],
    );

    let signedOut = 0;
    if (req.body.signOutOthers) {
      ({ revoked: signedOut } = await DeviceSessions.revokeOthers({ userId, currentSessionId: req.user.sessionId }));
    }

    await recordSecurity(req, 'security.password.changed', { count: signedOut });
    await alertByEmail(userId, 'security.password.changed', 'Your password was changed');
    return { changed: true, signedOut };
  }),
);

/* ------------------------------------------------------------------ *
 * Authenticator app and recovery codes
 * ------------------------------------------------------------------ */

router.post(
  '/totp/setup',
  confirmLimit,
  validate({ body: confirmBody }),
  handle(async (req) => {
    // Confirmed too: someone at an unlocked laptop could otherwise put their
    // own phone on the account and lock its owner out.
    await confirm(req);
    const user = await Users.findById(req.user.id);
    return SecondFactor.startTotpSetup({ userId: req.user.id, accountName: user.email });
  }),
);

router.post(
  '/totp/enable',
  confirmLimit,
  validate({ body: z.object({ code: z.string().min(6).max(12) }) }),
  handle(async (req) => {
    const result = await SecondFactor.confirmTotpSetup({ userId: req.user.id, code: req.body.code });
    await recordSecurity(req, 'security.totp.enabled');
    await alertByEmail(req.user.id, 'security.totp.enabled', 'Two-step sign-in is on');
    return result;
  }),
);

router.post(
  '/totp/disable',
  confirmLimit,
  validate({ body: confirmBody }),
  handle(async (req) => {
    await confirm(req);
    await SecondFactor.disableTotp({ userId: req.user.id });
    await recordSecurity(req, 'security.totp.disabled');
    await alertByEmail(req.user.id, 'security.totp.disabled', 'Your authenticator app was removed');
    return overview(req.user.id);
  }),
);

router.post(
  '/recovery-codes',
  confirmLimit,
  validate({ body: confirmBody }),
  handle(async (req) => {
    await confirm(req);
    const { required } = await SecondFactor.status(req.user.id);
    if (!required) throw badRequest('Recovery codes come with two-step sign-in. Turn that on first.');
    const result = await SecondFactor.regenerateRecoveryCodes({ userId: req.user.id });
    await recordSecurity(req, 'security.recovery_codes.regenerated');
    return result;
  }),
);

/* ------------------------------------------------------------------ *
 * Passkeys
 * ------------------------------------------------------------------ */

router.post(
  '/passkeys/options',
  confirmLimit,
  validate({ body: confirmBody }),
  handle(async (req) => {
    await confirm(req);
    const user = await Users.findById(req.user.id);
    return Passkeys.registrationOptions({ user, requestOrigin: req.get('origin') ?? null });
  }),
);

router.post(
  '/passkeys',
  validate({
    body: z.object({
      optionsId: z.string().uuid(),
      response: z.object({ id: z.string().min(1).max(1024) }).passthrough(),
      name: z.string().trim().max(60).optional(),
    }),
  }),
  handle(async (req) => {
    const passkey = await Passkeys.finishRegistration({
      userId: req.user.id,
      optionsId: req.body.optionsId,
      response: req.body.response,
      name: req.body.name,
    });
    // The first passkey turns two-step sign-in on: recovery codes come with it.
    const recoveryCodes = await SecondFactor.ensureRecoveryCodes({ userId: req.user.id });
    await recordSecurity(req, 'security.passkey.added', { device: passkey.name });
    await alertByEmail(req.user.id, 'security.passkey.added', 'A passkey was added to your account');
    return { passkey, recoveryCodes };
  }),
);

const idParam = z.object({ id: z.string().uuid() });

router.patch(
  '/passkeys/:id',
  validate({ params: idParam, body: z.object({ name: z.string().trim().min(1).max(60) }) }),
  handle(async (req) => {
    if (!(await Passkeys.rename({ userId: req.user.id, id: req.params.id, name: req.body.name }))) {
      throw notFound('No such passkey');
    }
    await pushToUser(req.user.id, 'settings:changed', { section: 'security', fields: [] });
    return { renamed: true };
  }),
);

router.post(
  '/passkeys/:id/remove',
  confirmLimit,
  validate({ params: idParam, body: confirmBody }),
  handle(async (req) => {
    await confirm(req);
    const name = await Passkeys.remove({ userId: req.user.id, id: req.params.id });
    if (!name) throw notFound('No such passkey');
    const { required } = await SecondFactor.status(req.user.id);
    if (!required) await pool.query(`DELETE FROM user_recovery_codes WHERE user_id = $1`, [req.user.id]);
    await recordSecurity(req, 'security.passkey.removed', { device: name });
    await alertByEmail(req.user.id, 'security.passkey.removed', 'A passkey was removed from your account');
    return overview(req.user.id);
  }),
);

/* ------------------------------------------------------------------ *
 * Your data
 * ------------------------------------------------------------------ */

router.get(
  '/export',
  rateLimit({ key: 'account:export', points: 5, durationSec: 3600, by: ['user'] }),
  handle(async (req, res) => {
    const document = await buildExport({ userId: req.user.id });
    await recordSecurity(req, 'account.exported');
    res.set('Cache-Control', 'no-store');
    res.set('Content-Disposition', `attachment; filename="${exportFileName()}"`);
    return document;
  }),
);

router.post(
  '/deletion',
  confirmLimit,
  validate({ body: confirmBody }),
  handle(async (req) => {
    await confirm(req);
    const scheduled = await AccountDeletion.request({ userId: req.user.id });
    const { revoked } = await DeviceSessions.revokeOthers({ userId: req.user.id, currentSessionId: req.user.sessionId });
    await recordSecurity(req, 'account.deletion.requested', { count: revoked });
    await alertByEmail(
      req.user.id,
      'security.account.deletion_requested',
      `Your account will be deleted on ${scheduled.scheduledFor.slice(0, 10)}`,
    );
    return { deletion: scheduled, signedOut: revoked };
  }),
);

router.post(
  '/deletion/cancel',
  handle(async (req) => {
    const cancelled = await AccountDeletion.cancel({ userId: req.user.id });
    if (cancelled) {
      await recordSecurity(req, 'account.deletion.cancelled');
      await alertByEmail(req.user.id, 'security.account.deletion_cancelled', 'Your account will not be deleted');
    }
    return { deletion: null, cancelled };
  }),
);

export default router;
__PC_EOF__
echo "wrote server/src/routes/accountSecurity.routes.js"

mkdir -p server/src/routes
cat > server/src/routes/account.routes.js <<'__PC_EOF__'
/**
 * account.routes — notifications · signed-in devices · history  (Settings, Phase B)
 *
 * Mounted under /account (app.js). Everything here is about the person asking;
 * no route takes someone else's id.
 *
 *   GET    /notifications                 settings, push and email status
 *   PATCH  /notifications                 any part of the settings
 *   POST   /notifications/test            { channel: inApp | push | email }
 *   PUT    /push-subscriptions            this browser receives push
 *   POST   /push-subscriptions/remove     this browser stops
 *   GET    /muted-chats                   every chat muted right now
 *   POST   /muted-chats/:kind/:id/unmute  ends one mute
 *   POST   /muted-chats/:kind/:id/mute    mutes again (the undo of unmute)
 *   GET    /sessions                      signed-in devices, this one marked
 *   DELETE /sessions/:sessionId           sign one device out
 *   POST   /sessions/sign-out-others      sign out everywhere else
 *   GET    /login-history                 sign-ins and failed attempts
 *   GET    /activity                      recent settings and security changes
 *
 * Password, two-step sign-in, passkeys and "your data" are in
 * accountSecurity.routes.js, under /account/security.
 *
 * A test notification is sent from here directly rather than through the
 * queue, so the answer says what actually happened ("sent to 2 browsers",
 * "the mail server refused it") and a test works while the worker is down.
 */

import { Router } from 'express';
import { z } from 'zod';

import { pool } from '../db/pool.js';
import * as NotificationService from '../community/NotificationService.js';
import * as Rules from '../settings/notifications.js';
import * as Subscriptions from '../notifications/webPushSubscriptions.js';
import * as Delivery from '../notifications/delivery.js';
import { deliveryConfig } from '../notifications/config.js';
import * as DeviceSessions from '../identity/deviceSessions.js';
import * as Participant from '../messaging/models/Participant.js';
import { auditFromRequest } from '../security/auditLog.js';
import { SIGN_IN_FAILED, SIGN_IN_SUCCEEDED } from '../security/sessionActivity.js';
import { describeUserAgent } from '../security/userAgent.js';
import { recordChange } from '../settings/changeLog.js';
import { pushToUser } from '../realtime/userEvents.js';
import { rateLimit } from '../middleware/rateLimit.js';
import { route, validate, requireAuth, q, notFound, badRequest, forbidden } from './_helpers.js';

const router = Router();
router.use(requireAuth);

/** Errors the services raise with a code, as the HTTP answers clients understand. */
const asHttp = (fn) => async (req, res) => {
  try {
    return await fn(req, res);
  } catch (error) {
    switch (error?.code) {
      case 'validation_failed':
        throw badRequest(error.message);
      case 'forbidden':
        throw forbidden(error.message);
      case 'not_found':
        throw notFound(error.message);
      default:
        throw error;
    }
  }
};

const iso = (value) => (value ? new Date(value).toISOString() : null);

/* ------------------------------------------------------------------ *
 * Notifications
 * ------------------------------------------------------------------ */

const notificationsView = async (userId) => {
  const context = await NotificationService.getDeliveryContext(userId);
  if (!context) throw notFound('No account');
  return {
    settings: context.settings,
    timeZone: context.timeZone,
    quietNow: Rules.isWithinQuietHours(context.settings.quietHours, new Date(), context.timeZone),
    push: {
      configured: Delivery.webPushConfigured(),
      publicKey: Delivery.webPushPublicKey(),
      devices: await Subscriptions.countForUser(userId),
    },
    email: { address: context.email, suppressed: context.emailSuppressed },
  };
};

router.get('/notifications', route(async (req) => notificationsView(req.user.id)));

router.patch(
  '/notifications',
  route(
    asHttp(async (req) => {
      await NotificationService.updateSettings({ userId: req.user.id, patch: req.body ?? {} });
      await recordChange(req, 'notifications', req.body);
      return notificationsView(req.user.id);
    }),
  ),
);

const TEST_TEXT = {
  title: 'Test notification',
  body: 'If you can read this, notifications reach you here.',
  url: '/settings/notifications',
};

router.post(
  '/notifications/test',
  rateLimit({ key: 'account:notify-test', points: 10, durationSec: 60, by: ['user'] }),
  validate({ body: z.object({ channel: z.enum(['inApp', 'push', 'email']) }) }),
  route(async (req) => {
    const userId = req.user.id;
    const { channel } = req.body;

    if (channel === 'inApp') {
      await NotificationService.createInApp({ userId, kind: 'system.test', ...TEST_TEXT });
      return { channel, delivered: 1, detail: 'Sent. It appears on screen in every open tab of the app.' };
    }

    if (channel === 'push') {
      if (!Delivery.webPushConfigured()) {
        return { channel, delivered: 0, detail: 'Push is not set up on the server: the web push keys are missing.' };
      }
      const result = await Delivery.sendPush({ userId, kind: 'system.test', ...TEST_TEXT });
      if (result.targets === 0) {
        return {
          channel,
          delivered: 0,
          detail: 'No browser receives push on this account yet. Turn on push for this browser first.',
        };
      }
      return {
        channel,
        delivered: result.delivered,
        detail:
          result.failed === 0
            ? `Sent to ${result.delivered} ${result.delivered === 1 ? 'browser' : 'browsers'}.`
            : `Sent to ${result.delivered} of ${result.targets}. Browsers that no longer accept push were removed.`,
      };
    }

    const context = await NotificationService.getDeliveryContext(userId);
    if (!context?.email) return { channel, delivered: 0, detail: 'This account has no email address.' };
    if (context.emailSuppressed) {
      return { channel, delivered: 0, detail: 'Email to this address is paused because an earlier one bounced.' };
    }
    try {
      const rendered = Delivery.renderEmail({ ...TEST_TEXT, recipientName: context.displayName });
      const sent = await Delivery.sendEmail({ to: context.email, ...rendered, kind: 'system.test' });
      const where =
        sent.transport === 'smtp' && deliveryConfig().smtpPort === 1025
          ? ' In development it lands in Mailpit (port 8025).'
          : '';
      return { channel, delivered: 1, detail: `Sent to ${context.email}.${where}` };
    } catch (cause) {
      return {
        channel,
        delivered: 0,
        detail: `The mail server did not accept it (${cause?.code ?? cause?.message ?? 'unknown error'}).`,
      };
    }
  }),
);

/* ------------------------------------------------------------------ *
 * Push registrations (this browser)
 * ------------------------------------------------------------------ */

const subscriptionBody = z
  .object({
    endpoint: z
      .string()
      .url()
      .max(2048)
      .refine((value) => value.startsWith('https://'), 'push endpoints are https'),
    keys: z.object({ p256dh: z.string().min(16).max(256), auth: z.string().min(8).max(64) }).passthrough(),
  })
  .passthrough();

router.put(
  '/push-subscriptions',
  rateLimit({ key: 'account:push-register', points: 20, durationSec: 3600, by: ['user'] }),
  validate({ body: subscriptionBody }),
  route(async (req) => {
    if (!Delivery.webPushConfigured()) throw badRequest('Push is not set up on the server.');
    await Subscriptions.upsert({
      userId: req.user.id,
      sessionId: req.user.sessionId ?? null,
      endpoint: req.body.endpoint,
      p256dh: req.body.keys.p256dh,
      auth: req.body.keys.auth,
      userAgent: req.get('user-agent'),
    });
    return { registered: true, devices: await Subscriptions.countForUser(req.user.id) };
  }),
);

router.post(
  '/push-subscriptions/remove',
  validate({ body: z.object({ endpoint: z.string().max(2048) }) }),
  route(async (req) => {
    await Subscriptions.removeByEndpoint({ userId: req.user.id, endpoint: req.body.endpoint });
    return { registered: false, devices: await Subscriptions.countForUser(req.user.id) };
  }),
);

/* ------------------------------------------------------------------ *
 * Muted chats
 * ------------------------------------------------------------------ */

router.get('/muted-chats', route(async (req) => NotificationService.mutedChats(req.user.id)));

const muteParams = z.object({ kind: z.enum(['conversation', 'channel']), id: z.string().uuid() });

const setChatMute = async ({ userId, kind, id, muted, until = null }) => {
  if (kind === 'conversation') {
    if (!(await Participant.isParticipant({ conversationId: id, userId }))) throw notFound('Chat not found');
    await Participant.setMuted({ conversationId: id, userId, muted, until: muted ? until : null });
    return;
  }
  const { rowCount } = await pool.query(
    `UPDATE channel_participants SET muted = $3, muted_until = $4
      WHERE channel_id = $1 AND user_id = $2`,
    [id, userId, muted, muted ? until : null],
  );
  if (rowCount === 0) throw notFound('Chat not found');
};

router.post(
  '/muted-chats/:kind/:id/unmute',
  validate({ params: muteParams }),
  route(async (req) => {
    await setChatMute({ userId: req.user.id, kind: req.params.kind, id: req.params.id, muted: false });
    await pushToUser(req.user.id, 'settings:changed', { section: 'muted', fields: [] });
    return { muted: false };
  }),
);

router.post(
  '/muted-chats/:kind/:id/mute',
  validate({
    params: muteParams,
    body: z.object({ until: z.string().nullish() }).passthrough().default({}),
  }),
  route(async (req) => {
    const requested = req.body?.until ? new Date(req.body.until) : null;
    const until = requested && !Number.isNaN(requested.getTime()) && requested > new Date() ? requested.toISOString() : null;
    await setChatMute({ userId: req.user.id, kind: req.params.kind, id: req.params.id, muted: true, until });
    await pushToUser(req.user.id, 'settings:changed', { section: 'muted', fields: [] });
    return { muted: true, mutedUntil: until };
  }),
);

/* ------------------------------------------------------------------ *
 * Signed-in devices
 * ------------------------------------------------------------------ */

router.get(
  '/sessions',
  route(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    const sessions = await DeviceSessions.list(req.user.id);
    return {
      items: sessions.map((session) => ({ ...session, current: session.sessionId === req.user.sessionId })),
    };
  }),
);

router.delete(
  '/sessions/:sessionId',
  rateLimit({ key: 'account:sessions', points: 30, durationSec: 300, by: ['user'] }),
  validate({ params: z.object({ sessionId: z.string().min(8).max(128) }) }),
  route(async (req) => {
    if (req.params.sessionId === req.user.sessionId) {
      throw badRequest('This is the device you are using. Use Sign out instead.');
    }
    const result = await DeviceSessions.revoke({ userId: req.user.id, sessionId: req.params.sessionId });
    if (!result) throw notFound('No such device');
    await auditFromRequest(req, {
      action: 'auth.session.revoked',
      targetType: 'user',
      targetId: req.user.id,
      metadata: { device: result.label, count: 1 },
    });
    await pushToUser(req.user.id, 'settings:changed', { section: 'sessions', fields: [] });
    return null;
  }),
);

router.post(
  '/sessions/sign-out-others',
  rateLimit({ key: 'account:sessions', points: 30, durationSec: 300, by: ['user'] }),
  route(async (req) => {
    const { revoked } = await DeviceSessions.revokeOthers({
      userId: req.user.id,
      currentSessionId: req.user.sessionId,
    });
    if (revoked > 0) {
      await auditFromRequest(req, {
        action: 'auth.session.revoked',
        targetType: 'user',
        targetId: req.user.id,
        metadata: { device: null, count: revoked },
      });
      await pushToUser(req.user.id, 'settings:changed', { section: 'sessions', fields: [] });
    }
    return { revoked };
  }),
);

/* ------------------------------------------------------------------ *
 * History (audit_log)
 * ------------------------------------------------------------------ */

const pageQuery = z
  .object({
    cursor: z.string().regex(/^\d+$/).optional(),
    limit: z.coerce.number().int().min(1).max(50).optional(),
  })
  .passthrough();

const readHistory = async ({ userId, actions, cursor, limit }) => {
  const { rows } = await pool.query(
    `SELECT id, action, metadata, host(ip) AS ip, user_agent, created_at
       FROM audit_log
      WHERE actor_id = $1 AND action = ANY($2::text[])
        AND ($3::bigint IS NULL OR id < $3::bigint)
      ORDER BY id DESC
      LIMIT $4`,
    [userId, actions, cursor ?? null, limit + 1],
  );
  const page = rows.slice(0, limit);
  return {
    items: page.map((row) => ({
      id: String(row.id),
      action: row.action,
      at: iso(row.created_at),
      device: describeUserAgent(row.user_agent ?? ''),
      ip: row.ip ?? null,
      section: row.metadata?.section ?? null,
      fields: Array.isArray(row.metadata?.fields) ? row.metadata.fields : [],
      detail: row.metadata?.device ?? row.metadata?.reason ?? row.metadata?.method ?? null,
      count: typeof row.metadata?.count === 'number' ? row.metadata.count : null,
    })),
    nextCursor: rows.length > limit && page.length ? String(page.at(-1).id) : null,
  };
};

router.get(
  '/login-history',
  validate({ query: pageQuery }),
  route(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    return readHistory({
      userId: req.user.id,
      actions: [SIGN_IN_SUCCEEDED, SIGN_IN_FAILED, 'auth.second_factor.failed'],
      cursor: q(req).cursor,
      limit: Number(q(req).limit ?? 20),
    });
  }),
);

router.get(
  '/activity',
  validate({ query: pageQuery }),
  route(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    return readHistory({
      userId: req.user.id,
      actions: [
        'settings.changed',
        'auth.session.revoked',
        // Phase C: password, two-step sign-in, passkeys, your data
        'security.password.changed',
        'security.totp.enabled',
        'security.totp.disabled',
        'security.recovery_codes.regenerated',
        'security.passkey.added',
        'security.passkey.removed',
        'account.exported',
        'account.deletion.requested',
        'account.deletion.cancelled',
      ],
      cursor: q(req).cursor,
      limit: Number(q(req).limit ?? 20),
    });
  }),
);

export default router;
__PC_EOF__
echo "wrote server/src/routes/account.routes.js"

mkdir -p server/src/queues/workers
cat > server/src/queues/workers/notificationWorker.js <<'__PC_EOF__'
/**
 * notificationWorker — in-app · push · email  (F2, F6 · Settings Phase B)
 *
 * Every notification in the product ends here: a thread reply, a mention, a
 * chat message to someone who is away, a lesson reminder, the digest, the
 * summary after a lesson. One worker, because the rules that decide are the
 * same every time — settings/notifications.js#decide — and they must see the
 * settings as they are at delivery, not as they were when the job was queued.
 *
 * Per person:
 *   1. settings        the type × channel matrix from Settings → Notifications
 *   2. focus           in a lesson, chat is held and summarised afterwards
 *   3. presence        someone looking at the app gets no push on top
 *   4. quiet hours     no push, unless a lesson starts and they allow it
 *   5. dedupe          three replies in two minutes are one push, not three
 *
 * Jobs (queue 'notify'):
 *   notification.fanout         one notification, many people
 *   notification.push           v6: push only (the bell entry already exists)
 *   notification.email          one email; account emails always go out
 *   notify.inApp                v6 jobs.notify()
 *   session.reminder            ReminderRules, T-24h and T-10m
 *   digest.daily                community digest by email
 *   notification.focus.flush    the summary after a lesson
 *   account.deletion            anonymises accounts whose grace period is over (Phase C)
 *
 * Push delivery never throws, so a retried job cannot notify everyone twice.
 * An email that fails is logged per person for the same reason; only a
 * single-recipient account email is retried.
 */

import { defineWorker, QUEUE_NAMES, PermanentJobError } from '../queues.js';
import { utilityConnection } from '../connection.js';
import * as NotificationService from '../../community/NotificationService.js';
import * as LiveState from '../../realtime/liveState.js';
import * as ScheduleService from '../../scheduling/ScheduleService.js';
import * as ReminderRules from '../../scheduling/ReminderRules.js';
import * as Rules from '../../settings/notifications.js';
import * as Delivery from '../../notifications/delivery.js';
import * as Focus from '../../notifications/focus.js';
import * as AccountDeletion from '../../identity/accountDeletion.js';

const redis = utilityConnection('notify');

const DEDUPE_TTL_SECONDS = 120;

/* ------------------------------------------------------------------ *
 * Job types
 * ------------------------------------------------------------------ */

const handlers = {
  'notification.fanout': (job, log) => deliver(normalize(job.data), log),
  'notification.push': (job, log) => deliver(normalize({ ...job.data, channels: ['push'] }), log),
  'notification.email': emailJob,
  'notify.inApp': (job, log) =>
    deliver(
      normalize({
        kind: job.data.kind,
        recipientIds: [job.data.userId],
        title: job.data.payload?.title ?? job.data.title,
        body: job.data.payload?.body ?? job.data.body,
        url: job.data.payload?.url ?? job.data.url,
        dedupeKey: job.data.dedupeKey,
      }),
      log,
    ),
  'session.reminder': sessionReminder,
  'digest.daily': digest,
  'notification.focus.flush': focusFlush,
  // Not a notification, but it needs a worker that runs every job it is given
  // (the maintenance worker skips jobs another task holds the lock for).
  'account.deletion': async (_job, log) => {
    const result = await AccountDeletion.runDue();
    log.info(result, 'account deletion: sweep done');
    return result;
  },
};

export function createNotificationWorker() {
  return defineWorker(QUEUE_NAMES.NOTIFY, async (job, log) => {
    const handler = handlers[job.name];
    if (!handler) throw new PermanentJobError(`Unknown notification job: ${job.name}`);
    return handler(job, log);
  });
}

/* ------------------------------------------------------------------ *
 * Fan-out
 * ------------------------------------------------------------------ */

/** Both payload shapes in use: v7 (kind, recipientIds, url) and v6 (type, userIds, href). */
const normalize = (data = {}) => ({
  kind: data.kind ?? data.type ?? null,
  recipientIds: [...new Set(data.recipientIds ?? data.userIds ?? (data.userId ? [data.userId] : []))],
  title: data.title ?? '',
  body: data.body ?? null,
  url: data.url ?? data.href ?? null,
  actorId: data.actorId ?? null,
  dedupeKey: data.dedupeKey ?? null,
  channels: (data.channels ?? ['in-app', 'push', 'email']).map(Rules.normalizeChannel),
  data: data.data ?? {},
  skipHold: Boolean(data.skipHold),
});

/** 'in-class', 'online' or 'offline', from the presence gateway (realtime/liveState.js). */
const presenceOf = (userId) => LiveState.stateOf(userId);

const heldItem = (n, category) => ({
  type: category === 'mentions' ? 'mention' : 'message',
  from: n.data.from ?? n.title ?? null,
  conversationId: n.data.conversationId ?? null,
  channelId: n.data.channelId ?? null,
});

async function deliver(n, log) {
  if (!n.kind || n.recipientIds.length === 0) {
    throw new PermanentJobError('a notification needs a kind and recipients', { kind: n.kind });
  }

  const result = { delivered: 0, suppressed: 0, held: 0, byChannel: { inApp: 0, push: 0, email: 0 } };

  for (const recipientId of n.recipientIds) {
    // Never tell someone about their own action.
    if (recipientId === n.actorId) continue;

    const context = await NotificationService.getDeliveryContext(recipientId);
    if (!context?.active) {
      result.suppressed += 1;
      continue;
    }

    const presence = await presenceOf(recipientId);
    let decision = Rules.decide({
      kind: n.kind,
      settings: context.settings,
      presence,
      requested: n.channels,
      timeZone: context.timeZone,
    });

    if (decision.hold) {
      if (!n.skipHold) {
        await Focus.hold(recipientId, heldItem(n, decision.category));
        result.held += 1;
        continue;
      }
      decision = Rules.decide({
        kind: n.kind,
        settings: context.settings,
        presence: 'online',
        requested: n.channels,
        timeZone: context.timeZone,
      });
    }

    let { channels } = decision;

    if (n.dedupeKey && channels.some((channel) => channel !== 'inApp')) {
      const fresh = await redis.set(`notify:dedupe:${recipientId}:${n.dedupeKey}`, '1', 'EX', DEDUPE_TTL_SECONDS, 'NX');
      if (!fresh) channels = channels.filter((channel) => channel === 'inApp');
    }

    if (channels.length === 0) {
      result.suppressed += 1;
      continue;
    }

    // "Show message text" off: lock screens and inboxes say who, not what.
    const hideText = Rules.CHAT_CATEGORIES.has(decision.category) && !context.settings.showPreviews;
    const outsideBody = hideText ? 'Open Classroom to read it.' : n.body;

    if (channels.includes('inApp')) {
      await NotificationService.createInApp({
        userId: recipientId,
        kind: n.kind,
        title: n.title,
        body: n.body,
        url: n.url,
        actorId: n.actorId,
        data: n.data,
      });
      result.byChannel.inApp += 1;
    }

    if (channels.includes('push')) {
      const sent = await Delivery.sendPush({ userId: recipientId, title: n.title, body: outsideBody, url: n.url, kind: n.kind });
      result.byChannel.push += sent.delivered;
    }

    if (channels.includes('email') && context.email && !context.emailSuppressed) {
      try {
        const rendered = Delivery.renderEmail({
          title: n.title,
          body: outsideBody,
          url: n.url,
          recipientName: context.displayName,
        });
        await Delivery.sendEmail({ to: context.email, ...rendered, kind: n.kind });
        result.byChannel.email += 1;
      } catch (cause) {
        log.error({ err: cause, recipientId, kind: n.kind }, 'notify: email not sent');
      }
    }

    result.delivered += 1;
  }

  log.info({ kind: n.kind, ...result }, 'notify: delivered');
  return result;
}

/* ------------------------------------------------------------------ *
 * Email
 * ------------------------------------------------------------------ */

const ACCOUNT_EMAIL = {
  'email.verify': { actionLabel: 'Confirm email address', body: 'Confirm that this address is yours. The link works for 24 hours.' },
  'password.reset': { actionLabel: 'Choose a new password', body: 'Someone asked to reset your password. If that was not you, ignore this email. The link works for one hour.' },
  // Phase C: changes that matter if someone else has taken over the account.
  'security.password.changed': { actionLabel: 'Check your security settings', body: 'The password of your Classroom account was just changed. If that was not you, reset your password now and sign out every device.' },
  'security.totp.enabled': { actionLabel: 'Check your security settings', body: 'Two-step sign-in with an authenticator app is now on for your account. If that was not you, reset your password now.' },
  'security.totp.disabled': { actionLabel: 'Check your security settings', body: 'The authenticator app was removed from your account. If that was not you, reset your password now.' },
  'security.passkey.added': { actionLabel: 'Check your passkeys', body: 'A passkey was added to your account. If that was not you, remove it and reset your password.' },
  'security.passkey.removed': { actionLabel: 'Check your passkeys', body: 'A passkey was removed from your account. If that was not you, reset your password now.' },
  'security.account.deletion_requested': { actionLabel: 'Keep my account', body: 'You asked us to delete your Classroom account. Until the date in the subject, signing in and pressing Cancel keeps it. After that it cannot be restored.' },
  'security.account.deletion_cancelled': { actionLabel: 'Open Classroom', body: 'Your account will not be deleted. If you did not cancel the deletion yourself, check your security settings.' },
};

/**
 * One email. Account emails (confirm address, reset password) go out whatever
 * the settings say, and are retried when the mail server is unavailable.
 * Anything else follows the settings like every other notification.
 */
async function emailJob(job, log) {
  const kind = job.data.kind ?? job.data.type ?? 'system.email';
  const userId = job.data.userId;
  if (!userId) throw new PermanentJobError('an email needs a userId');

  if (Rules.categoryOf(kind) !== 'security') {
    return deliver(normalize({ ...job.data, kind, recipientIds: [userId], channels: ['email'] }), log);
  }

  const context = await NotificationService.getDeliveryContext(userId);
  if (!context?.email) return { skipped: 'no address' };
  if (context.emailSuppressed) return { skipped: 'address suppressed after a bounce' };

  const account = ACCOUNT_EMAIL[kind] ?? { actionLabel: 'Open Classroom', body: null };
  const rendered = Delivery.renderEmail({
    title: job.data.title ?? 'Classroom',
    body: job.data.body ?? account.body,
    url: job.data.url ?? job.data.href,
    recipientName: context.displayName,
    actionLabel: account.actionLabel,
    footer: 'You get this email because of an action on your Classroom account.',
  });
  // Throws on a mail server problem: BullMQ retries with backoff.
  await Delivery.sendEmail({ to: context.email, ...rendered, kind });
  log.info({ userId, kind }, 'notify: account email sent');
  return { sent: 1 };
}

/* ------------------------------------------------------------------ *
 * Lesson reminders (F1, F3)
 * ------------------------------------------------------------------ */

/**
 * Enqueued by ReminderRules.enqueueDue(). The reminder row is the source of
 * truth, so the audience is resolved at send time.
 */
async function sessionReminder(job, log) {
  const { reminderId, sessionId, ruleKey, template } = job.data;

  const session = await ScheduleService.getSession(sessionId);
  if (!session) {
    await ReminderRules.markSent(reminderId, { recipients: 0 });
    throw new PermanentJobError('Session no longer exists', { sessionId });
  }
  if (session.status !== 'scheduled') {
    await ReminderRules.markSent(reminderId, { recipients: 0 });
    return { skipped: session.status };
  }

  const recipientIds = await ScheduleService.listAudience(sessionId);
  const when = ScheduleService.formatLocal(session);

  const result = await deliver(
    normalize({
      kind: template,
      recipientIds,
      title: session.title,
      body: ruleKey === 'T-10m' ? 'Starts in 10 minutes' : `Starts ${when}`,
      url: session.lessonId ? `/lessons/${session.lessonId}/live` : '/',
      dedupeKey: `session:${sessionId}:${ruleKey}`,
      channels: ruleKey === 'T-10m' ? ['push', 'in-app'] : ['email', 'push', 'in-app'],
      data: { sessionId, lessonId: session.lessonId ?? null },
    }),
    log,
  );

  await ReminderRules.markSent(reminderId, { recipients: result.delivered });
  return result;
}

/* ------------------------------------------------------------------ *
 * Digest (F2)
 * ------------------------------------------------------------------ */

async function digest(job, log) {
  const { userId, date } = job.data;
  const content = await NotificationService.buildDigest({ userId, date });
  if (!content || content.items.length === 0) return { skipped: 'nothing to send' };

  const context = await NotificationService.getDeliveryContext(userId);
  if (!context?.email || context.emailSuppressed) return { skipped: 'no address' };

  const rendered = Delivery.renderEmail({
    title: content.subject,
    body: content.summary,
    url: content.url,
    recipientName: context.displayName,
    actionLabel: 'Open the community',
  });
  await Delivery.sendEmail({ to: context.email, ...rendered, kind: 'digest.daily' });
  log.info({ userId, items: content.items.length }, 'notify: digest sent');
  return { sent: 1, items: content.items.length };
}

/* ------------------------------------------------------------------ *
 * Focus: the summary after a lesson
 * ------------------------------------------------------------------ */

async function focusFlush(job, log) {
  const { userId } = job.data;
  if (!userId) throw new PermanentJobError('focus flush needs a userId');

  await Focus.clearSchedule(userId);

  if (await Focus.isInLesson(userId)) {
    // Still teaching or learning: look again in a minute.
    await Focus.scheduleFlush(userId);
    return { waiting: true };
  }

  const items = await Focus.takeHeld(userId);
  const summary = Focus.summarizeHeld(items);
  if (!summary) return { empty: true };

  return deliver(
    normalize({
      kind: 'chat.focus.summary',
      recipientIds: [userId],
      title: summary.title,
      body: summary.body,
      url: summary.url,
      channels: ['in-app', 'push'],
      skipHold: true,
      data: { held: summary.count, mentions: summary.mentions },
    }),
    log,
  );
}

export default createNotificationWorker;
__PC_EOF__
echo "wrote server/src/queues/workers/notificationWorker.js"

mkdir -p server/test/settings
cat > server/test/settings/security.check.mjs <<'__PC_EOF__'
// Settings, Phase C — the pure parts of two-step sign-in and the data export.
// Run: node --test server/test/settings/*.check.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';

import { base32Decode, base32Encode, codeAt, generateSecret, otpauthUri, stepAt, verifyCode } from '../../src/security/totp.js';
import { generateCodes, hashCode, looksLikeRecoveryCode, normalizeCode } from '../../src/security/recoveryCodes.js';
import { deriveKey, open, seal } from '../../src/security/secretBox.js';
import { exportFileName, stripSensitive } from '../../src/security/exportSanitize.js';

const RFC_SEED = Buffer.from('12345678901234567890', 'ascii');

test('TOTP matches the RFC 6238 test vectors (SHA-1, 8 digits)', () => {
  for (const [seconds, expected] of [
    [59, '94287082'],
    [1111111109, '07081804'],
    [1111111111, '14050471'],
    [1234567890, '89005924'],
    [2000000000, '69279037'],
  ]) {
    assert.equal(codeAt(RFC_SEED, stepAt(seconds * 1000), 8), expected);
  }
});

test('base32 round-trips and secrets are 32 characters', () => {
  const bytes = randomBytes(20);
  assert.deepEqual(base32Decode(base32Encode(bytes)), bytes);
  assert.equal(base32Encode(Buffer.from('foobar')), 'MZXW6YTBOI');
  assert.match(generateSecret(), /^[A-Z2-7]{32}$/);
});

test('codes: current and neighbouring steps pass, a used step never again', () => {
  const secret = generateSecret();
  const now = Date.UTC(2026, 8, 26, 12, 0, 10);
  const step = stepAt(now);
  assert.equal(verifyCode(secret, codeAt(secret, step), { now }), step);
  assert.equal(verifyCode(secret, codeAt(secret, step - 1), { now }), step - 1);
  assert.equal(verifyCode(secret, codeAt(secret, step + 1), { now }), step + 1);
  assert.equal(verifyCode(secret, codeAt(secret, step - 2), { now }), null);
  assert.equal(verifyCode(secret, codeAt(secret, step), { now, lastUsedStep: step }), null);
  assert.equal(verifyCode(secret, '12345', { now }), null);
  const spaced = codeAt(secret, step).replace(/(\d{3})/, '$1 ');
  assert.equal(verifyCode(secret, spaced, { now }), step);
});

test('otpauth link carries issuer, account and parameters', () => {
  const uri = otpauthUri({ secret: 'JBSWY3DPEHPK3PXP', accountName: 'anna@example.com' });
  assert.ok(uri.startsWith('otpauth://totp/Classroom%3Aanna%40example.com?'));
  const params = new URL(uri).searchParams;
  assert.equal(params.get('secret'), 'JBSWY3DPEHPK3PXP');
  assert.equal(params.get('digits'), '6');
  assert.equal(params.get('period'), '30');
});

test('recovery codes: ten, unique, typed any way, hashed', () => {
  const codes = generateCodes();
  assert.equal(codes.length, 10);
  assert.equal(new Set(codes).size, 10);
  for (const code of codes) assert.match(code, /^[a-z2-9]{4}-[a-z2-9]{4}$/);
  assert.equal(normalizeCode(' ABCD efgh '), 'abcd-efgh');
  assert.equal(normalizeCode('abcd-efg'), null);
  assert.equal(looksLikeRecoveryCode('abcd-efgh'), true);
  assert.equal(looksLikeRecoveryCode('123456'), false);
  assert.equal(hashCode('abcd-efgh'), hashCode(normalizeCode('ABCDEFGH')));
  assert.notEqual(hashCode('abcd-efgh'), 'abcd-efgh');
});

test('secretBox: round-trip, wrong key and tampering are refused', () => {
  const key = deriveKey('cookie-secret-for-tests');
  const sealed = seal('JBSWY3DPEHPK3PXP', key);
  assert.ok(sealed.startsWith('v1.'));
  assert.ok(!sealed.includes('JBSWY3DPEHPK3PXP'));
  assert.equal(open(sealed, key), 'JBSWY3DPEHPK3PXP');
  assert.throws(() => open(sealed, deriveKey('another secret')));
  const parts = sealed.split('.');
  parts[3] = parts[3].slice(0, -2) + (parts[3].endsWith('AA') ? 'BB' : 'AA');
  assert.throws(() => open(parts.join('.'), key));
  assert.equal(deriveKey('x').length, 32);
});

test('the export never carries secrets', () => {
  const clean = stripSensitive({
    id: 1,
    body: 'hello',
    password_hash: 'scrypt$…',
    secret_encrypted: 'v1.…',
    refresh_token_hash: 'x',
    p256dh: 'k',
    auth: 'a',
    public_key: Buffer.from('k'),
    created_at: new Date('2026-01-01T00:00:00Z'),
  });
  assert.deepEqual(clean, { id: 1, body: 'hello', created_at: '2026-01-01T00:00:00.000Z' });
  assert.equal(exportFileName(new Date('2026-09-26T10:00:00Z')), 'classroom-export-2026-09-26.json');
});
__PC_EOF__
echo "wrote server/test/settings/security.check.mjs"

mkdir -p packages/core-client/src
cat > packages/core-client/src/CoreProvider.tsx <<'__PC_EOF__'
/**
 * CoreProvider  (F5)
 *
 * Owns the things that are singular per tab: the API client with its refresh
 * and trace ids, the authenticated session, the chat socket, and the room-to-
 * node resolver. Nothing below it constructs a transport of its own.
 *
 * What it deliberately does *not* own: the SfuClient.
 *
 * A tab has one HTTP client and one chat connection for its whole life. A
 * lesson does not — it starts when someone opens a room and ends when they
 * leave, and it drags in mediasoup-client, the largest dependency in the
 * product. Building it here would put mediasoup in the main bundle and make the
 * lazy route split in main.jsx meaningless. The classroom route assembles its
 * own SfuClient from the pieces below, so mediasoup loads only for people who
 * actually join a lesson.
 *
 * Three things are worth reading before changing anything here.
 *
 * Tokens. Both the access token and the refresh token live in memory. The
 * refresh token would normally sit in an httpOnly cookie, and in production it
 * should — but behind a tunnel that serves the page over https while proxying
 * to a plain-http API, browsers discard that cookie without a word: no console
 * warning, no failed request, only a 401 several steps later that looks like an
 * auth bug rather than a storage one. Asking for the token in the response body
 * with `wantsRefreshToken` — the path apps/mobile already uses, because a React
 * Native app has no cookie jar either — removes the browser's cookie policy
 * from the equation entirely.
 *
 * The cost is explicit: nothing survives a reload, so a reload signs you out.
 * That is a development trade, not a design. Restoring the cookie path means
 * dropping `wantsRefreshToken` and letting refresh read the cookie again.
 *
 * Two-step sign-in (Settings, Phase C). For an account with an authenticator
 * app or a passkey, POST /auth/login answers with a challenge instead of
 * tokens. signIn() then throws SecondFactorRequired, and the sign-in page
 * finishes with completeSignIn() (a code) or signInWithPasskey() (a passkey,
 * with or without a password first). Nothing is signed in before that.
 *
 * CSRF. middleware/csrf.js issues the cookie on the way out but validates on
 * the way in, so the very first call to a protected route can never succeed — a
 * client cannot echo a token it has not been given. Bootstrapping therefore
 * runs in two steps: GET /auth/csrf, which is an ignored method and returns the
 * token in its body, then the protected call with that token echoed back.
 */

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react';

import { ApiError, HEADERS } from '@classroom/contracts';

import { createHttpClient, type AuthProvider, type HttpClient } from './http/httpClient.js';
import { createSocketClient, type SocketClient } from './socket/socketClient.js';
import { createNodeResolver, type NodeResolver } from './rtc/nodeResolver.js';

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

export interface Session {
  userId: string;
  displayName: string;
  avatarUrl: string | null;
  /** Tenant role, not the room role — a teacher is still a learner elsewhere. */
  role: 'owner' | 'teacher' | 'learner';
  tenantId: string;
}

export type AuthStatus = 'restoring' | 'authenticated' | 'anonymous';

/** What auth.routes.js `issue()` puts in the body. */
export interface TokenResponse {
  accessToken: string;
  expiresIn: number;
  tokenType: 'Bearer';
  user: Session;
  /** Present only when the request asked for it. */
  refreshToken?: string;
  sessionId?: string;
}

/** POST /auth/login for an account with two-step sign-in. */
interface ChallengeResponse {
  secondFactorRequired: true;
  challengeId: string;
  methods: Array<'totp' | 'recovery' | 'passkey'>;
  expiresInSec?: number;
}

/**
 * Thrown by signIn() when the password was right and a second step is needed.
 * Not an ApiError: nothing failed.
 */
export class SecondFactorRequired extends Error {
  readonly secondFactorRequired = true;
  readonly challengeId: string;
  readonly methods: ChallengeResponse['methods'];
  readonly expiresInSec: number;

  constructor(challenge: ChallengeResponse) {
    super('A second step is needed to sign in.');
    this.name = 'SecondFactorRequired';
    this.challengeId = challenge.challengeId;
    this.methods = challenge.methods ?? [];
    this.expiresInSec = challenge.expiresInSec ?? 300;
  }
}

/** WebAuthn options as the server sends them (JSON, base64url). */
export interface PasskeyOptions {
  optionsId: string;
  options: Record<string, unknown>;
}

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

export interface CoreContextValue {
  http: HttpClient;
  nodeResolver: NodeResolver;
  /** The `/chat` connection. Null until there is a session to authenticate it. */
  chatSocket: SocketClient | null;
  session: Session | null;
  status: AuthStatus;
  release: string;
  apiUrl: string;
  wsUrl: string;
  /** Handed to SfuClient and to any socket the classroom route opens. */
  getAccessToken(): string | null;
  /** Throws SecondFactorRequired when the account has two-step sign-in. */
  signIn(credentials: { email: string; password: string }): Promise<Session>;
  /** The second step with a code from the authenticator app or a recovery code. */
  completeSignIn(input: { challengeId: string; code: string }): Promise<Session>;
  /** Options for a passkey: the second step (with a challengeId) or a sign-in on its own. */
  passkeyOptions(input?: { challengeId?: string | null }): Promise<PasskeyOptions>;
  /** Finishes a passkey sign-in with the browser's answer. */
  signInWithPasskey(input: {
    challengeId?: string | null;
    optionsId: string;
    response: Record<string, unknown>;
  }): Promise<Session>;
  signOut(): Promise<void>;
}

const CoreContext = createContext<CoreContextValue | null>(null);

export const useCore = (): CoreContextValue => {
  const value = useContext(CoreContext);
  if (!value) throw new Error('useCore must be used inside <CoreProvider>');
  return value;
};

/** Convenience accessors, so a component that needs one thing imports one thing. */
export const useHttp = (): HttpClient => useCore().http;
export const useSession = (): Session | null => useCore().session;

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

export interface CoreProviderProps {
  apiUrl: string;
  wsUrl: string;
  release: string;
  children: ReactNode;
  /** Where to send someone whose session expired. Defaults to no redirect. */
  onSessionExpired?(): void;
}

export function CoreProvider({
  apiUrl,
  wsUrl,
  release,
  children,
  onSessionExpired,
}: CoreProviderProps) {
  // Refs, not state: all four are read inside callbacks that must not go stale
  // between renders, and changing any of them should never trigger one.
  const accessTokenRef = useRef<string | null>(null);
  const csrfTokenRef = useRef<string | null>(null);
  const refreshTokenRef = useRef<string | null>(null);
  const sessionIdRef = useRef<string | null>(null);

  const [session, setSession] = useState<Session | null>(null);
  // Nothing persists across a reload, so there is no session to restore and no
  // reason to start in 'restoring' and make everyone wait for a call that
  // cannot succeed.
  const [status, setStatus] = useState<AuthStatus>('anonymous');

  const sessionExpiredRef = useRef(onSessionExpired);
  sessionExpiredRef.current = onSessionExpired;

  // -------------------------------------------------------------------------
  // HTTP
  // -------------------------------------------------------------------------

  const http = useMemo<HttpClient>(() => {
    const auth: AuthProvider = {
      getAccessToken: () => accessTokenRef.current,

      /**
       * httpClient serialises concurrent callers onto one call, so a burst of
       * 401s produces one refresh — which matters because the refresh token
       * rotates on every use and a second concurrent call would present an
       * already-rotated token. AuthService treats that as theft and revokes the
       * whole session family.
       */
      async refresh() {
        // No token in memory means there is nothing to refresh. Saying so here
        // is better than asking the server to tell us the same thing with a
        // 401 that then looks like a failure.
        if (!refreshTokenRef.current || !sessionIdRef.current) return null;

        try {
          // A plain client, because using the outer one would recurse: its own
          // 401 handling would call this method again.
          const bare = createHttpClient({ baseUrl: apiUrl, credentials: 'include' });

          const result = (await bare.post(
            '/auth/refresh',
            {
              refreshToken: refreshTokenRef.current,
              sessionId: sessionIdRef.current,
            },
            { anonymous: true, headers: await csrfHeaders(bare) },
          )) as TokenResponse;

          accessTokenRef.current = result.accessToken;
          // Rotation: the old token is spent, and presenting it again would
          // look like theft.
          if (result.refreshToken) refreshTokenRef.current = result.refreshToken;
          if (result.sessionId) sessionIdRef.current = result.sessionId;

          setSession(result.user);
          setStatus('authenticated');
          return result.accessToken;
        } catch {
          return null;
        }
      },

      onSessionExpired() {
        accessTokenRef.current = null;
        refreshTokenRef.current = null;
        sessionIdRef.current = null;
        setSession(null);
        setStatus('anonymous');
        sessionExpiredRef.current?.();
      },

      // Used by httpClient for every non-GET request that is not anonymous.
      getCsrfToken: () => csrfTokenRef.current,
    };

    return createHttpClient({
      baseUrl: apiUrl,
      auth,
      // Still 'include' so the CSRF cookie round-trips; the refresh token no
      // longer depends on it.
      credentials: 'include',
      defaultHeaders: { 'x-client-release': release },
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [apiUrl, release]);

  /**
   * Ensures a CSRF token exists and returns it as a header pair.
   *
   * Login, refresh and logout are sent with `anonymous: true` — otherwise
   * httpClient would attach a bearer token they do not need and, worse, would
   * run its refresh-on-401 logic against the refresh route itself. Anonymous
   * requests skip httpClient's automatic CSRF header, so these three set it by
   * hand.
   */
  const csrfHeaders = useCallback(
    async (client: HttpClient = http): Promise<Record<string, string>> => {
      if (!csrfTokenRef.current) {
        try {
          const { csrfToken } = (await client.get('/auth/csrf')) as { csrfToken: string };
          csrfTokenRef.current = csrfToken;
        } catch {
          // Let the request proceed and fail on its own terms; a 403 with a
          // clear message beats a silent no-op here.
          return {};
        }
      }
      return { [HEADERS.csrfToken]: csrfTokenRef.current as string };
    },
    [http],
  );

  // -------------------------------------------------------------------------
  // Room to node resolution (F1)
  // -------------------------------------------------------------------------

  // Lives here rather than in the classroom route so its cache survives leaving
  // and rejoining a lesson.
  const nodeResolver = useMemo(() => createNodeResolver({ http }), [http]);

  // -------------------------------------------------------------------------
  // Chat socket (F6)
  // -------------------------------------------------------------------------

  const [chatSocket, setChatSocket] = useState<SocketClient | null>(null);

  useEffect(() => {
    if (status !== 'authenticated') return undefined;

    const socket = createSocketClient({
      namespace: '/chat',
      getAccessToken: () => accessTokenRef.current,
    });

    let cancelled = false;
    void socket
      .connect(wsUrl, {})
      .then(() => {
        if (!cancelled) setChatSocket(socket);
      })
      .catch(() => {
        // A chat socket that will not open must not take the app down with it.
        // Everything else keeps working; the dock shows itself as offline.
      });

    return () => {
      cancelled = true;
      socket.disconnect();
      setChatSocket(null);
    };
  }, [status, wsUrl]);

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  /** Takes the tokens of any successful sign-in: password, second step or passkey. */
  const adopt = useCallback((result: TokenResponse): Session => {
    accessTokenRef.current = result.accessToken;
    refreshTokenRef.current = result.refreshToken ?? null;
    sessionIdRef.current = result.sessionId ?? null;

    setSession(result.user);
    setStatus('authenticated');
    return result.user;
  }, []);

  const signIn = useCallback<CoreContextValue['signIn']>(
    async (credentials) => {
      const headers = await csrfHeaders();

      const result = (await http.post(
        '/auth/login',
        {
          ...credentials,
          device: { platform: 'web' },
          // The whole reason this works behind the tunnel: the token comes back
          // in the body instead of in a cookie the browser may silently drop.
          wantsRefreshToken: true,
        },
        { anonymous: true, headers },
      )) as TokenResponse | ChallengeResponse;

      if ('secondFactorRequired' in result && result.secondFactorRequired) {
        throw new SecondFactorRequired(result);
      }
      return adopt(result as TokenResponse);
    },
    [http, csrfHeaders, adopt],
  );

  const completeSignIn = useCallback<CoreContextValue['completeSignIn']>(
    async ({ challengeId, code }) => {
      const headers = await csrfHeaders();
      const result = (await http.post(
        '/auth/login/second-factor',
        { challengeId, code, device: { platform: 'web' }, wantsRefreshToken: true },
        // Not retried: a code is single-use, a replay would be refused anyway.
        { anonymous: true, headers, retry: { attempts: 1 } },
      )) as TokenResponse;
      return adopt(result);
    },
    [http, csrfHeaders, adopt],
  );

  const passkeyOptions = useCallback<CoreContextValue['passkeyOptions']>(
    async ({ challengeId = null } = {}) => {
      const headers = await csrfHeaders();
      return (await http.post(
        challengeId ? '/auth/login/second-factor/passkey/options' : '/auth/passkey/options',
        challengeId ? { challengeId } : {},
        { anonymous: true, headers, retry: { attempts: 1 } },
      )) as PasskeyOptions;
    },
    [http, csrfHeaders],
  );

  const signInWithPasskey = useCallback<CoreContextValue['signInWithPasskey']>(
    async ({ challengeId = null, optionsId, response }) => {
      const headers = await csrfHeaders();
      const body = { optionsId, response, device: { platform: 'web' }, wantsRefreshToken: true };
      const result = (await http.post(
        challengeId ? '/auth/login/second-factor/passkey' : '/auth/passkey',
        challengeId ? { ...body, challengeId } : body,
        { anonymous: true, headers, retry: { attempts: 1 } },
      )) as TokenResponse;
      return adopt(result);
    },
    [http, csrfHeaders, adopt],
  );

  const signOut = useCallback<CoreContextValue['signOut']>(async () => {
    try {
      const headers = await csrfHeaders();
      await http.post(
        '/auth/logout',
        { refreshToken: refreshTokenRef.current, sessionId: sessionIdRef.current },
        { headers },
      );
    } catch (cause) {
      // A logout that fails server-side still has to clear the client, or the
      // user stays signed in on a machine they just tried to leave.
      if (!ApiError.is(cause)) throw cause;
    } finally {
      accessTokenRef.current = null;
      refreshTokenRef.current = null;
      sessionIdRef.current = null;
      // The old token is bound to the session that just ended.
      csrfTokenRef.current = null;
      nodeResolver.clear();
      setSession(null);
      setStatus('anonymous');
    }
  }, [http, csrfHeaders, nodeResolver]);

  /**
   * Stable across renders, deliberately.
   *
   * An inline arrow here is a new function every time the context value is
   * rebuilt — which is on every session, status and socket change. Anything
   * memoised against it downstream rebuilds too, and useSfuClient memoises the
   * whole SfuClient against exactly this. The result was a client torn down and
   * recreated on unrelated state changes, which the server sees as the peer
   * leaving and a new one arriving.
   *
   * It reads a ref, so it never needs to change.
   */
  const getAccessToken = useCallback(() => accessTokenRef.current, []);

  const value = useMemo<CoreContextValue>(
    () => ({
      http,
      nodeResolver,
      chatSocket,
      session,
      status,
      release,
      apiUrl,
      wsUrl,
      getAccessToken,
      signIn,
      completeSignIn,
      passkeyOptions,
      signInWithPasskey,
      signOut,
    }),
    [
      http,
      nodeResolver,
      chatSocket,
      session,
      status,
      release,
      apiUrl,
      wsUrl,
      getAccessToken,
      signIn,
      completeSignIn,
      passkeyOptions,
      signInWithPasskey,
      signOut,
    ],
  );

  return <CoreContext.Provider value={value}>{children}</CoreContext.Provider>;
}

export default CoreProvider;
__PC_EOF__
echo "wrote packages/core-client/src/CoreProvider.tsx"

mkdir -p packages/core-client/src/api
cat > packages/core-client/src/api/accountSecurityApi.ts <<'__PC_EOF__'
/**
 * Account security API  (Settings, Phase C)
 *
 * Password, two-step sign-in, passkeys and "your data". Paths are the
 * server's (server/src/routes/accountSecurity.routes.js, mounted under
 * /account/security).
 *
 * Calls that switch protection off or delete something take a
 * confirmation: the password, or a code when two-step sign-in is on.
 */

import { z } from 'zod';
import type { HttpClient } from '../http/httpClient.js';

export interface Confirmation {
  password?: string;
  code?: string;
}

export const PasskeyViewSchema = z
  .object({
    id: z.string(),
    name: z.string(),
    deviceType: z.string().nullable().default(null),
    backedUp: z.boolean().default(false),
    site: z.string().nullable().default(null),
    createdAt: z.string().nullable().default(null),
    lastUsedAt: z.string().nullable().default(null),
  })
  .passthrough();
export type PasskeyView = z.infer<typeof PasskeyViewSchema>;

export const SecurityOverviewSchema = z
  .object({
    password: z.object({ set: z.boolean(), changedAt: z.string().nullable().default(null) }).passthrough(),
    twoStep: z
      .object({
        totp: z.object({ enabled: z.boolean(), enabledAt: z.string().nullable().default(null) }).passthrough(),
        recoveryCodesRemaining: z.number().default(0),
        passkeyCount: z.number().default(0),
        required: z.boolean().default(false),
      })
      .passthrough(),
    passkeys: z.object({ available: z.boolean().default(false), items: z.array(PasskeyViewSchema) }).passthrough(),
    deletion: z
      .object({ requestedAt: z.string().nullable().default(null), scheduledFor: z.string() })
      .passthrough()
      .nullable()
      .default(null),
  })
  .passthrough();
export type SecurityOverview = z.infer<typeof SecurityOverviewSchema>;

const TotpSetupSchema = z
  .object({ secret: z.string(), uri: z.string(), qr: z.string().nullable().default(null), expiresInSec: z.number() })
  .passthrough();
export type TotpSetup = z.infer<typeof TotpSetupSchema>;

const RecoveryCodesSchema = z.object({ recoveryCodes: z.array(z.string()) }).passthrough();

const RegistrationOptionsSchema = z
  .object({ optionsId: z.string(), options: z.record(z.string(), z.unknown()) })
  .passthrough();

const PasskeyAddedSchema = z
  .object({ passkey: PasskeyViewSchema, recoveryCodes: z.array(z.string()).nullable().default(null) })
  .passthrough();

const DeletionSchema = z
  .object({
    deletion: z
      .object({ requestedAt: z.string().nullable().default(null), scheduledFor: z.string() })
      .passthrough()
      .nullable(),
  })
  .passthrough();

export interface AccountSecurityApi {
  overview(signal?: AbortSignal): Promise<SecurityOverview>;
  changePassword(input: {
    currentPassword: string;
    newPassword: string;
    signOutOthers?: boolean;
  }): Promise<{ changed: boolean; signedOut: number }>;
  startTotpSetup(confirmation: Confirmation): Promise<TotpSetup>;
  enableTotp(code: string): Promise<{ recoveryCodes: string[] }>;
  disableTotp(confirmation: Confirmation): Promise<SecurityOverview>;
  regenerateRecoveryCodes(confirmation: Confirmation): Promise<{ recoveryCodes: string[] }>;
  passkeyRegistrationOptions(confirmation: Confirmation): Promise<z.infer<typeof RegistrationOptionsSchema>>;
  addPasskey(input: {
    optionsId: string;
    response: Record<string, unknown>;
    name?: string;
  }): Promise<z.infer<typeof PasskeyAddedSchema>>;
  renamePasskey(id: string, name: string): Promise<unknown>;
  removePasskey(id: string, confirmation: Confirmation): Promise<SecurityOverview>;
  /** Everything as one JSON document; the caller offers it as a download. */
  exportData(): Promise<unknown>;
  requestDeletion(confirmation: Confirmation): Promise<z.infer<typeof DeletionSchema>>;
  cancelDeletion(): Promise<z.infer<typeof DeletionSchema>>;
}

const BASE = '/account/security';
const once = { retry: { attempts: 1 } } as const;

export const createAccountSecurityApi = (http: HttpClient): AccountSecurityApi => ({
  overview: (signal) => http.get(BASE, { schema: SecurityOverviewSchema, signal }),

  changePassword: (input) =>
    http.post(`${BASE}/password`, { signOutOthers: true, ...input }, {
      schema: z.object({ changed: z.boolean(), signedOut: z.number().default(0) }).passthrough(),
      ...once,
    }),

  startTotpSetup: (confirmation) => http.post(`${BASE}/totp/setup`, confirmation, { schema: TotpSetupSchema, ...once }),

  enableTotp: (code) => http.post(`${BASE}/totp/enable`, { code }, { schema: RecoveryCodesSchema, ...once }),

  disableTotp: (confirmation) =>
    http.post(`${BASE}/totp/disable`, confirmation, { schema: SecurityOverviewSchema, ...once }),

  regenerateRecoveryCodes: (confirmation) =>
    http.post(`${BASE}/recovery-codes`, confirmation, { schema: RecoveryCodesSchema, ...once }),

  passkeyRegistrationOptions: (confirmation) =>
    http.post(`${BASE}/passkeys/options`, confirmation, { schema: RegistrationOptionsSchema, ...once }),

  addPasskey: (input) => http.post(`${BASE}/passkeys`, input, { schema: PasskeyAddedSchema, ...once }),

  renamePasskey: (id, name) => http.patch(`${BASE}/passkeys/${encodeURIComponent(id)}`, { name }),

  removePasskey: (id, confirmation) =>
    http.post(`${BASE}/passkeys/${encodeURIComponent(id)}/remove`, confirmation, {
      schema: SecurityOverviewSchema,
      ...once,
    }),

  // A large account can take a while to collect.
  exportData: () => http.get(`${BASE}/export`, { timeoutMs: 120_000, retry: { attempts: 1 } }),

  requestDeletion: (confirmation) => http.post(`${BASE}/deletion`, confirmation, { schema: DeletionSchema, ...once }),

  cancelDeletion: () => http.post(`${BASE}/deletion/cancel`, {}, { schema: DeletionSchema }),
});
__PC_EOF__
echo "wrote packages/core-client/src/api/accountSecurityApi.ts"

mkdir -p apps/web/src/lib
cat > apps/web/src/lib/webauthn.js <<'__PC_EOF__'
/**
 * Passkeys in the browser  (Settings, Phase C)
 *
 * The server speaks WebAuthn as JSON with base64url strings
 * (@simplewebauthn/server); the browser API wants ArrayBuffers and returns
 * them. This converts both ways, so no extra browser library is needed.
 *
 *   createPasskey(options)  navigator.credentials.create → registration JSON
 *   signWithPasskey(options) navigator.credentials.get    → authentication JSON
 */

export const passkeysSupported = () =>
  typeof window !== 'undefined' &&
  typeof window.PublicKeyCredential === 'function' &&
  typeof navigator.credentials?.create === 'function';

export const toBase64Url = (buffer) => {
  const bytes = buffer instanceof Uint8Array ? buffer : new Uint8Array(buffer);
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};

export const fromBase64Url = (text) => {
  const base64 = String(text).replace(/-/g, '+').replace(/_/g, '/');
  const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
};

const credentialDescriptors = (list) =>
  (list ?? []).map((entry) => ({ ...entry, type: 'public-key', id: fromBase64Url(entry.id) }));

/** Registration options (JSON) → what navigator.credentials.create takes. */
export const creationOptionsFromJSON = (json) => ({
  ...json,
  challenge: fromBase64Url(json.challenge),
  user: { ...json.user, id: fromBase64Url(json.user.id) },
  excludeCredentials: credentialDescriptors(json.excludeCredentials),
});

/** Authentication options (JSON) → what navigator.credentials.get takes. */
export const requestOptionsFromJSON = (json) => {
  const options = { ...json, challenge: fromBase64Url(json.challenge) };
  if (json.allowCredentials?.length) options.allowCredentials = credentialDescriptors(json.allowCredentials);
  else delete options.allowCredentials;
  return options;
};

const friendlyError = (cause) => {
  if (cause?.name === 'NotAllowedError') return new Error('The passkey prompt was closed or timed out.');
  if (cause?.name === 'InvalidStateError') return new Error('This device already has a passkey for your account.');
  if (cause?.name === 'SecurityError') return new Error('Passkeys cannot be used on this address.');
  return cause instanceof Error ? cause : new Error('The passkey did not work.');
};

export const createPasskey = async (optionsJSON) => {
  let credential;
  try {
    credential = await navigator.credentials.create({ publicKey: creationOptionsFromJSON(optionsJSON) });
  } catch (cause) {
    throw friendlyError(cause);
  }
  const { response } = credential;
  return {
    id: credential.id,
    rawId: toBase64Url(credential.rawId),
    type: credential.type,
    authenticatorAttachment: credential.authenticatorAttachment ?? undefined,
    clientExtensionResults: credential.getClientExtensionResults?.() ?? {},
    response: {
      clientDataJSON: toBase64Url(response.clientDataJSON),
      attestationObject: toBase64Url(response.attestationObject),
      transports: response.getTransports?.() ?? [],
    },
  };
};

export const signWithPasskey = async (optionsJSON) => {
  let credential;
  try {
    credential = await navigator.credentials.get({ publicKey: requestOptionsFromJSON(optionsJSON) });
  } catch (cause) {
    throw friendlyError(cause);
  }
  const { response } = credential;
  return {
    id: credential.id,
    rawId: toBase64Url(credential.rawId),
    type: credential.type,
    authenticatorAttachment: credential.authenticatorAttachment ?? undefined,
    clientExtensionResults: credential.getClientExtensionResults?.() ?? {},
    response: {
      clientDataJSON: toBase64Url(response.clientDataJSON),
      authenticatorData: toBase64Url(response.authenticatorData),
      signature: toBase64Url(response.signature),
      userHandle: response.userHandle ? toBase64Url(response.userHandle) : undefined,
    },
  };
};

/** A name for a new passkey from this browser, e.g. "Chrome on Windows". */
export const suggestedPasskeyName = (userAgent = globalThis.navigator?.userAgent ?? '') => {
  const browser =
    /Edg\//.test(userAgent) ? 'Edge'
      : /Firefox\//.test(userAgent) ? 'Firefox'
        : /Chrome\//.test(userAgent) ? 'Chrome'
          : /Safari\//.test(userAgent) ? 'Safari'
            : 'Browser';
  const system =
    /iPhone|iPad/.test(userAgent) ? 'iPhone or iPad'
      : /Android/.test(userAgent) ? 'Android'
        : /Windows/.test(userAgent) ? 'Windows'
          : /Mac OS X/.test(userAgent) ? 'Mac'
            : /Linux/.test(userAgent) ? 'Linux'
              : null;
  return system ? `${browser} on ${system}` : browser;
};
__PC_EOF__
echo "wrote apps/web/src/lib/webauthn.js"

mkdir -p apps/web/src/pages
cat > apps/web/src/pages/LoginPage.jsx <<'__PC_EOF__'
import { useState } from 'react';
import { Navigate, useLocation, useNavigate } from 'react-router-dom';
import { useCore } from '@classroom/core-client';
import { passkeysSupported, signWithPasskey } from '../lib/webauthn.js';

/**
 * Sign in  (F5 · Settings Phase C)
 *
 * CoreProvider owns the session; this is the one screen that asks it to start
 * one. The access token never reaches this component.
 *
 * Phase C adds the second step. For an account with two-step sign-in the
 * password alone signs nobody in: signIn() throws SecondFactorRequired and
 * this page asks for a code from the authenticator app, a recovery code, or
 * a passkey. "Sign in with a passkey" on the first screen skips the password
 * entirely — the device checks fingerprint, face or PIN.
 */
export default function LoginPage() {
  const { signIn, completeSignIn, passkeyOptions, signInWithPasskey, status } = useCore();
  const navigate = useNavigate();
  const location = useLocation();

  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [challenge, setChallenge] = useState(null);
  const [code, setCode] = useState('');
  const [useRecovery, setUseRecovery] = useState(false);
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);

  // Where they were headed before being bounced here, e.g. a room link from a
  // calendar invite. Landing on the dashboard instead would lose the lesson.
  const destination = location.state?.from ?? '/';
  const signedOutElsewhere = location.state?.reason === 'signed-out-remotely';

  if (status === 'authenticated') {
    return <Navigate to={destination} replace />;
  }

  const finish = () => navigate(destination, { replace: true });

  const run = async (action) => {
    setBusy(true);
    setError(null);
    try {
      await action();
    } finally {
      setBusy(false);
    }
  };

  const handlePassword = (event) => {
    event.preventDefault();
    run(async () => {
      try {
        await signIn({ email, password });
        finish();
      } catch (cause) {
        if (cause?.secondFactorRequired) {
          setChallenge({ id: cause.challengeId, methods: cause.methods });
          setUseRecovery(!cause.methods.includes('totp') && !cause.methods.includes('passkey'));
          setPassword('');
          return;
        }
        // The server deliberately does not say which half was wrong.
        setError(cause?.detail ?? 'Email or password is incorrect.');
      }
    });
  };

  const handleCode = (event) => {
    event.preventDefault();
    run(async () => {
      try {
        await completeSignIn({ challengeId: challenge.id, code });
        finish();
      } catch (cause) {
        setCode('');
        const detail = cause?.detail ?? 'That code is not right.';
        setError(detail);
        // Too many wrong codes or too slow: the password has to be entered again.
        if (/password again|took too long/i.test(detail)) setChallenge(null);
      }
    });
  };

  const handlePasskey = (challengeId = null) =>
    run(async () => {
      try {
        const { optionsId, options } = await passkeyOptions({ challengeId });
        const response = await signWithPasskey(options);
        await signInWithPasskey({ challengeId, optionsId, response });
        finish();
      } catch (cause) {
        setError(cause?.detail ?? cause?.message ?? 'The passkey was not accepted.');
      }
    });

  const canUsePasskeys = passkeysSupported();

  if (challenge) {
    const hasApp = challenge.methods.includes('totp');
    const hasRecovery = challenge.methods.includes('recovery');
    const hasPasskey = challenge.methods.includes('passkey') && canUsePasskeys;

    return (
      <div className="join">
        <form className="card" onSubmit={handleCode}>
          <h1>Two-step sign-in</h1>

          {hasPasskey ? (
            <>
              <p>Confirm with the passkey on this device, or enter a code.</p>
              <button type="button" className="btn btn--primary" disabled={busy} onClick={() => handlePasskey(challenge.id)}>
                Use a passkey
              </button>
            </>
          ) : null}

          {hasApp || hasRecovery ? (
            <>
              <label htmlFor="code">
                {useRecovery || !hasApp ? 'Recovery code' : 'Code from your authenticator app'}
              </label>
              <input
                id="code"
                inputMode={useRecovery || !hasApp ? 'text' : 'numeric'}
                autoComplete="one-time-code"
                placeholder={useRecovery || !hasApp ? 'abcd-efgh' : '123 456'}
                value={code}
                onChange={(event) => setCode(event.target.value)}
                maxLength={20}
                required
                autoFocus={!hasPasskey}
              />
              <button type="submit" className="btn btn--primary" disabled={busy || code.trim().length < 6}>
                {busy ? 'Checking…' : 'Continue'}
              </button>
            </>
          ) : null}

          {error && (
            <p className="banner banner--warn" role="alert">
              {error}
            </p>
          )}

          {hasApp && hasRecovery ? (
            <button type="button" className="btn btn--link" onClick={() => { setUseRecovery((v) => !v); setCode(''); }}>
              {useRecovery ? 'Use the authenticator app instead' : 'Lost your phone? Use a recovery code'}
            </button>
          ) : null}
          <button type="button" className="btn btn--link" onClick={() => { setChallenge(null); setError(null); setCode(''); }}>
            Back
          </button>
        </form>
      </div>
    );
  }

  return (
    <div className="join">
      <form className="card" onSubmit={handlePassword}>
        <h1>Sign in</h1>

        {signedOutElsewhere ? (
          <p className="banner" role="status">
            This device was signed out from another device.
          </p>
        ) : null}

        <label htmlFor="email">Email</label>
        <input
          id="email"
          type="email"
          autoComplete="username webauthn"
          value={email}
          onChange={(event) => setEmail(event.target.value)}
          required
          autoFocus
        />

        <label htmlFor="password">Password</label>
        <input
          id="password"
          type="password"
          autoComplete="current-password"
          value={password}
          onChange={(event) => setPassword(event.target.value)}
          required
        />

        {error && (
          <p className="banner banner--warn" role="alert">
            {error}
          </p>
        )}

        <button type="submit" className="btn btn--primary" disabled={busy}>
          {busy ? 'Signing in…' : 'Sign in'}
        </button>

        {canUsePasskeys ? (
          <button type="button" className="btn" disabled={busy} onClick={() => handlePasskey(null)}>
            Sign in with a passkey
          </button>
        ) : null}
      </form>
    </div>
  );
}
__PC_EOF__
echo "wrote apps/web/src/pages/LoginPage.jsx"

mkdir -p apps/web/src/pages
cat > apps/web/src/pages/SettingsPage.jsx <<'__PC_EOF__'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { createAccountApi, createProfileApi, useCore } from '@classroom/core-client';

import ProfileSettings from '../components/Settings/ProfileSettings.jsx';
import PrivacySettings from '../components/Settings/PrivacySettings.jsx';
import RegionSettings from '../components/Settings/RegionSettings.jsx';
import LessonSettings from '../components/Settings/LessonSettings.jsx';
import AppearanceSettings from '../components/Settings/AppearanceSettings.jsx';
import TeachingSettings from '../components/Settings/TeachingSettings.jsx';
import NotificationSettings from '../components/Settings/NotificationSettings.jsx';
import SecuritySettings from '../components/Settings/SecuritySettings.jsx';
import ActivitySettings from '../components/Settings/ActivitySettings.jsx';
import DataSettings from '../components/Settings/DataSettings.jsx';
import { searchSettings } from '../components/Settings/settingsIndex.js';
import { mergeDeep, pickDeep } from '../components/Settings/notificationsModel.js';
import { cacheLocale, cachePreferences } from '../lib/preferences.js';
import { liveEventsAvailable, onUserEvent } from '../lib/userEvents.js';
import '../components/Settings/settings.css';

/**
 * Settings  (Phase A + B + C)
 *
 * One tab per topic, each with its own address (/settings/<tab>), a search
 * across every setting, and no Save button: every change is saved the moment
 * it is made and can be undone from the notice that confirms it.
 *
 *   profile        how others see you, and a preview of exactly that
 *   privacy        check-up, private messages, visibility, blocked people
 *   notifications  type × channel, push, tests, quiet hours, focus, muted chats
 *   security       password, two-step sign-in, passkeys, signed-in devices,
 *                  sign out elsewhere, sign-in history
 *   activity       recent changes to your settings
 *   region         language, time zone, date and time format
 *   lessons        how you join, sound processing, device test
 *   appearance     text size, motion
 *   teaching       how your lessons start (teachers and owners only)
 *   data           download your data, delete your account
 *
 * A change made on another device arrives live (settings:changed) and the
 * page reloads what it shows; without a live connection it reloads when the
 * window regains focus.
 */

const ALL_TABS = [
  { id: 'profile', label: 'Profile' },
  { id: 'privacy', label: 'Privacy' },
  { id: 'notifications', label: 'Notifications' },
  { id: 'security', label: 'Sign-in & devices' },
  { id: 'activity', label: 'Recent changes' },
  { id: 'region', label: 'Language & region' },
  { id: 'lessons', label: 'Lessons' },
  { id: 'appearance', label: 'Appearance' },
  { id: 'teaching', label: 'Teaching', roles: ['teacher', 'owner'] },
  { id: 'data', label: 'Your data' },
];

/** An own save echoes back as settings:changed; ignore echoes this soon after one. */
const OWN_ECHO_MS = 2_000;

const pick = (source, keys) => Object.fromEntries(keys.map((key) => [key, source?.[key] ?? null]));

export default function SettingsPage() {
  const core = useCore();
  const { http } = core;
  const profiles = useMemo(() => createProfileApi(http), [http]);
  const account = useMemo(() => createAccountApi(http), [http]);
  const { tab: tabParam } = useParams();
  const navigate = useNavigate();

  const [own, setOwn] = useState(null);
  const [privacy, setPrivacy] = useState(null);
  const [preferences, setPreferences] = useState(null);
  const [blocks, setBlocks] = useState([]);
  const [notifications, setNotifications] = useState(null);
  const [notificationsError, setNotificationsError] = useState(false);
  const [loadError, setLoadError] = useState(false);
  const [notice, setNotice] = useState(null);
  const [query, setQuery] = useState('');
  const [highlight, setHighlight] = useState(null);
  const [reloadKey, setReloadKey] = useState(0);
  const noticeTimer = useRef(null);
  const lastOwnSave = useRef(0);

  const loadNotifications = useCallback(async () => {
    try {
      setNotifications(await account.getNotifications());
      setNotificationsError(false);
    } catch {
      setNotificationsError(true);
    }
  }, [account]);

  const load = useCallback(async () => {
    setLoadError(false);
    try {
      const [ownProfile, ownPrivacy, ownPreferences, ownBlocks] = await Promise.all([
        profiles.getOwn(),
        profiles.getPrivacy(),
        profiles.getPreferences(),
        profiles.listBlocks({ limit: 100 }),
      ]);
      setOwn(ownProfile);
      setPrivacy(ownPrivacy);
      setPreferences(cachePreferences(ownPreferences));
      setBlocks(ownBlocks.items);
      cacheLocale(ownProfile.locale);
    } catch {
      setLoadError(true);
    }
    // Separate: a problem with notifications must not hide the other tabs.
    await loadNotifications();
  }, [profiles, loadNotifications]);

  useEffect(() => {
    load();
    return () => window.clearTimeout(noticeTimer.current);
  }, [load]);

  /* ---- changes made elsewhere ---- */

  useEffect(() => {
    const refresh = () => {
      if (Date.now() - lastOwnSave.current < OWN_ECHO_MS) return;
      load();
      setReloadKey((key) => key + 1);
    };

    if (liveEventsAvailable(core)) {
      let timer = null;
      const off = onUserEvent(core, 'settings:changed', () => {
        // The event may arrive on more than one socket: one reload is enough.
        window.clearTimeout(timer);
        timer = window.setTimeout(refresh, 150);
      });
      return () => {
        window.clearTimeout(timer);
        off();
      };
    }

    const onFocus = () => refresh();
    window.addEventListener('focus', onFocus);
    return () => window.removeEventListener('focus', onFocus);
  }, [core, load]);

  const tabs = useMemo(
    () => ALL_TABS.filter((tab) => !tab.roles || tab.roles.includes(own?.role)),
    [own?.role],
  );
  const tab = tabs.some((t) => t.id === tabParam) ? tabParam : 'profile';

  /* ---- saving, with undo ---- */

  const announce = useCallback((text, undo = null, error = false) => {
    window.clearTimeout(noticeTimer.current);
    setNotice({ text, undo, error });
    noticeTimer.current = window.setTimeout(() => setNotice(null), undo ? 8_000 : 4_000);
  }, []);

  const failed = useCallback(
    (cause) => {
      announce(cause?.detail ?? cause?.message ?? 'That change was not saved. Try again.', null, true);
      throw cause;
    },
    [announce],
  );

  const markOwnSave = () => {
    lastOwnSave.current = Date.now();
  };

  const saveProfile = useCallback(
    async (patch, label, { undoable = true } = {}) => {
      const before = pick(own, Object.keys(patch));
      markOwnSave();
      try {
        const next = await profiles.update(patch);
        setOwn(next);
        if (patch.locale) cacheLocale(next.locale);
        announce(
          `${label} saved.`,
          undoable ? () => saveProfile(before, label, { undoable: false }).then(() => announce(`${label} restored.`)) : null,
        );
      } catch (cause) {
        failed(cause);
      }
    },
    [own, profiles, announce, failed],
  );

  const savePrivacy = useCallback(
    async (patch, label, { undoable = true } = {}) => {
      const before = pick(privacy, Object.keys(patch));
      setPrivacy((current) => ({ ...current, ...patch }));
      markOwnSave();
      try {
        setPrivacy(await profiles.updatePrivacy(patch));
        announce(
          `${label} saved.`,
          undoable ? () => savePrivacy(before, label, { undoable: false }).then(() => announce(`${label} restored.`)) : null,
        );
      } catch (cause) {
        setPrivacy((current) => ({ ...current, ...before }));
        failed(cause);
      }
    },
    [privacy, profiles, announce, failed],
  );

  const savePreferences = useCallback(
    async (section, patch, label, { undoable = true } = {}) => {
      const before = pick(preferences?.[section], Object.keys(patch));
      setPreferences((current) => ({ ...current, [section]: { ...current[section], ...patch } }));
      markOwnSave();
      try {
        const next = await profiles.updatePreferences({ [section]: patch });
        setPreferences(cachePreferences(next));
        announce(
          `${label} saved.`,
          undoable
            ? () => savePreferences(section, before, label, { undoable: false }).then(() => announce(`${label} restored.`))
            : null,
        );
      } catch (cause) {
        setPreferences((current) => ({ ...current, [section]: { ...current[section], ...before } }));
        failed(cause);
      }
    },
    [preferences, profiles, announce, failed],
  );

  const saveNotifications = useCallback(
    async (patch, label, { undoable = true } = {}) => {
      const before = pickDeep(notifications?.settings, patch);
      setNotifications((current) => ({ ...current, settings: mergeDeep(current.settings, patch) }));
      markOwnSave();
      try {
        setNotifications(await account.updateNotifications(patch));
        announce(
          `${label} saved.`,
          undoable
            ? () => saveNotifications(before, label, { undoable: false }).then(() => announce(`${label} restored.`))
            : null,
        );
      } catch (cause) {
        setNotifications((current) => ({ ...current, settings: mergeDeep(current.settings, before) }));
        failed(cause);
      }
    },
    [notifications, account, announce, failed],
  );

  const unblock = useCallback(
    async (block) => {
      try {
        await profiles.unblock(block.blockedUserId);
        setBlocks((current) => current.filter((b) => b.blockedUserId !== block.blockedUserId));
        announce(`${block.profile.displayName} is no longer blocked.`, async () => {
          await profiles.block({ userId: block.blockedUserId });
          setBlocks((current) => [block, ...current]);
          announce(`${block.profile.displayName} is blocked again.`);
        });
      } catch (cause) {
        announce(cause?.detail ?? 'That person could not be unblocked.', null, true);
      }
    },
    [profiles, announce],
  );

  /* ---- navigation and search ---- */

  const jumpTo = useCallback(
    (tabId, anchor) => {
      setQuery('');
      navigate(`/settings/${tabId}`);
      setHighlight(anchor);
    },
    [navigate],
  );

  useEffect(() => {
    if (!highlight) return undefined;
    const frame = requestAnimationFrame(() => {
      const el = document.getElementById(`setting-${highlight}`);
      el?.scrollIntoView({ behavior: 'smooth', block: 'center' });
      el?.classList.add('st-flash');
    });
    const timer = window.setTimeout(() => {
      document.getElementById(`setting-${highlight}`)?.classList.remove('st-flash');
      setHighlight(null);
    }, 1_600);
    return () => {
      cancelAnimationFrame(frame);
      window.clearTimeout(timer);
    };
  }, [highlight, tab]);

  const results = useMemo(() => searchSettings(query, tabs), [query, tabs]);

  /* ---- render ---- */

  if (loadError) {
    return (
      <section className="page st-page">
        <h1>Settings</h1>
        <p className="st-error">Your settings could not be loaded.</p>
        <button type="button" className="btn" onClick={load}>
          Try again
        </button>
      </section>
    );
  }

  if (!own || !privacy || !preferences) {
    return (
      <section className="page st-page">
        <h1>Settings</h1>
        <p className="st-hint">Loading your settings…</p>
      </section>
    );
  }

  const tabProps = { own, privacy, preferences, blocks, saveProfile, savePrivacy, savePreferences, unblock };

  const notificationsTab = notifications ? (
    <NotificationSettings
      account={account}
      notifications={notifications}
      saveNotifications={saveNotifications}
      announce={announce}
      reloadNotifications={loadNotifications}
    />
  ) : notificationsError ? (
    <>
      <p className="st-error">Your notification settings could not be loaded.</p>
      <button type="button" className="btn" onClick={loadNotifications}>
        Try again
      </button>
    </>
  ) : (
    <p className="st-hint">Loading…</p>
  );

  return (
    <section className="page st-page">
      <header className="st-header">
        <h1>Settings</h1>
        <input
          className="st-search"
          type="search"
          placeholder="Search settings, e.g. microphone, push or devices"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          aria-label="Search settings"
        />
      </header>

      <div className="st-layout">
        <nav className="st-nav" aria-label="Settings sections">
          {tabs.map((t) => (
            <button
              key={t.id}
              type="button"
              className={t.id === tab && !query ? 'st-nav__item is-active' : 'st-nav__item'}
              aria-current={t.id === tab && !query ? 'page' : undefined}
              onClick={() => {
                setQuery('');
                navigate(`/settings/${t.id}`);
              }}
            >
              {t.label}
            </button>
          ))}
        </nav>

        <div className="st-content">
          {query.trim() ? (
            <div className="st-results" aria-live="polite">
              {results.length === 0 ? <p className="st-hint">No setting matches “{query}”.</p> : null}
              {results.map((entry) => (
                <button key={`${entry.tab}-${entry.anchor}`} type="button" className="st-result" onClick={() => jumpTo(entry.tab, entry.anchor)}>
                  <span className="st-result__label">{entry.label}</span>
                  <span className="st-hint">{tabs.find((t) => t.id === entry.tab)?.label}</span>
                </button>
              ))}
            </div>
          ) : (
            <>
              {tab === 'profile' && <ProfileSettings {...tabProps} />}
              {tab === 'privacy' && <PrivacySettings {...tabProps} onJump={(anchor) => jumpTo('privacy', anchor)} />}
              {tab === 'notifications' && notificationsTab}
              {tab === 'security' && <SecuritySettings account={account} announce={announce} reloadKey={reloadKey} />}
              {tab === 'activity' && <ActivitySettings account={account} onJump={jumpTo} reloadKey={reloadKey} />}
              {tab === 'region' && <RegionSettings {...tabProps} />}
              {tab === 'lessons' && <LessonSettings {...tabProps} />}
              {tab === 'appearance' && <AppearanceSettings {...tabProps} />}
              {tab === 'teaching' && <TeachingSettings {...tabProps} />}
              {tab === 'data' && <DataSettings announce={announce} reloadKey={reloadKey} />}
            </>
          )}
        </div>
      </div>

      {notice ? (
        <div className={notice.error ? 'st-notice st-notice--error' : 'st-notice'} role="status" aria-live="polite">
          <span>{notice.text}</span>
          {notice.undo ? (
            <button
              type="button"
              className="st-notice__undo"
              onClick={() => {
                const undo = notice.undo;
                setNotice(null);
                undo().catch(() => undefined);
              }}
            >
              Undo
            </button>
          ) : null}
        </div>
      ) : null}
    </section>
  );
}
__PC_EOF__
echo "wrote apps/web/src/pages/SettingsPage.jsx"

mkdir -p apps/web/src/pages
cat > apps/web/src/pages/AppLayout.jsx <<'__PC_EOF__'
import { useEffect, useMemo, useRef } from 'react';
import { NavLink, Outlet, useNavigate } from 'react-router-dom';
import { createAccountApi, createProfileApi, useCore } from '@classroom/core-client';
import ErrorBoundary from '../components/system/ErrorBoundary.jsx';
import NotificationToasts from '../components/system/NotificationToasts.jsx';
import DeletionBanner from '../components/system/DeletionBanner.jsx';
import { cacheLocale, cachePreferences } from '../lib/preferences.js';
import { onServiceWorkerMessage, resyncPush } from '../lib/pushClient.js';
import { onUserEvent } from '../lib/userEvents.js';

/**
 * The shell every page except the classroom renders inside.
 *
 * The boundary sits around <Outlet/> rather than around the whole layout, so a
 * page that throws loses the page and keeps the navigation — a user who can
 * still click away from a broken screen is not stuck.
 *
 * Phase C adds the banner for an account that is scheduled for deletion.
 *
 * Phase B adds three invisible helpers: SessionWatch (a device signed out
 * from elsewhere goes back to the sign-in page), NotificationToasts (a new
 * notification shows on screen) and live preference sync.
 */
export default function AppLayout() {
  return (
    <div className="app">
      <PreferencesSync />
      <SessionWatch />
      <header className="app__bar">
        <span className="app__brand">Classroom</span>
        <nav className="app__nav">
          <NavLink to="/" end>
            Dashboard
          </NavLink>
          <NavLink to="/community">Community</NavLink>
          <NavLink to="/messages">Messages</NavLink>
          <NavLink to="/media">Media</NavLink>
          <NavLink to="/settings">Settings</NavLink>
        </nav>
      </header>

      <DeletionBanner />

      <main className="app__content">
        <ErrorBoundary area="page">
          <Outlet />
        </ErrorBoundary>
      </main>

      <NotificationToasts />
    </div>
  );
}

/**
 * Brings this device's copy of the account preferences up to date once per
 * sign-in and whenever they change on another device, so a change made there
 * (font size, how lessons start) applies here too. Also keeps this browser's
 * push registration current. Renders nothing; a failure leaves the cached
 * copy in use.
 */
function PreferencesSync() {
  const core = useCore();
  const { http, status } = core;
  const profiles = useMemo(() => createProfileApi(http), [http]);
  const account = useMemo(() => createAccountApi(http), [http]);

  useEffect(() => {
    if (status !== 'authenticated') return undefined;
    let cancelled = false;

    const sync = () =>
      Promise.all([profiles.getPreferences(), profiles.getOwn()])
        .then(([preferences, own]) => {
          if (cancelled) return;
          cachePreferences(preferences);
          cacheLocale(own.locale);
        })
        .catch(() => undefined);

    sync();
    resyncPush({ account }).catch(() => undefined);

    let timer = null;
    const offLive = onUserEvent(core, 'settings:changed', (payload) => {
      if (payload?.section && !['preferences', 'profile'].includes(payload.section)) return;
      window.clearTimeout(timer);
      timer = window.setTimeout(sync, 150);
    });
    const offWorker = onServiceWorkerMessage((message) => {
      if (message.type === 'push-subscription-changed') resyncPush({ account }).catch(() => undefined);
    });

    return () => {
      cancelled = true;
      window.clearTimeout(timer);
      offLive();
      offWorker();
    };
  }, [core, profiles, account, status]);

  return null;
}

/** Core states that mean nobody is signed in (a refresh in progress is not one of them). */
const SIGNED_OUT = new Set(['anonymous', 'unauthenticated', 'signed-out', 'signedOut', 'logged-out']);

/**
 * This device was signed out — from Settings on another device, or because
 * its session expired. The server tells open tabs (session:revoked); the core
 * learns it at the latest on its next request. Either way: back to sign-in.
 */
function SessionWatch() {
  const core = useCore();
  const { status } = core;
  const navigate = useNavigate();
  const previous = useRef(status);

  useEffect(() => {
    if (previous.current === 'authenticated' && SIGNED_OUT.has(status)) {
      navigate('/login', { replace: true, state: { reason: 'signed-out' } });
    }
    previous.current = status;
  }, [status, navigate]);

  useEffect(() => {
    if (status !== 'authenticated') return undefined;
    return onUserEvent(core, 'session:revoked', () => {
      const signOut = core.signOut ?? core.logout ?? core.auth?.signOut ?? core.auth?.logout;
      Promise.resolve(typeof signOut === 'function' ? signOut() : undefined)
        .catch(() => undefined)
        .finally(() => navigate('/login', { replace: true, state: { reason: 'signed-out-remotely' } }));
    });
  }, [core, status, navigate]);

  return null;
}
__PC_EOF__
echo "wrote apps/web/src/pages/AppLayout.jsx"

mkdir -p apps/web/src/components/Settings
cat > apps/web/src/components/Settings/ConfirmIdentity.jsx <<'__PC_EOF__'
import { useId, useState } from 'react';

/**
 * "Confirm it's you"  (Settings, Phase C)
 *
 * Asks for the password — or, with two-step sign-in on, lets someone use a
 * code instead — before a change that switches protection off or cannot be
 * undone. The server checks it again (security/confirmIdentity.js); this is
 * only the form.
 */
export default function ConfirmIdentity({ action, danger = false, codeAllowed = false, onConfirm, onCancel }) {
  const id = useId();
  const [mode, setMode] = useState('password');
  const [value, setValue] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  const submit = async (event) => {
    event.preventDefault();
    setBusy(true);
    setError(null);
    try {
      await onConfirm(mode === 'password' ? { password: value } : { code: value.trim() });
    } catch (cause) {
      setError(cause?.detail ?? cause?.message ?? 'That did not work.');
      setValue('');
    } finally {
      setBusy(false);
    }
  };

  return (
    <form className="st-confirm" onSubmit={submit}>
      <label className="st-label" htmlFor={id}>
        {mode === 'password' ? 'Your password' : 'A code from your authenticator app, or a recovery code'}
      </label>
      <div className="st-inline">
        <input
          id={id}
          className="st-input__field"
          type={mode === 'password' ? 'password' : 'text'}
          autoComplete={mode === 'password' ? 'current-password' : 'one-time-code'}
          value={value}
          onChange={(event) => setValue(event.target.value)}
          autoFocus
          required
        />
        <button type="submit" className={danger ? 'btn btn--danger' : 'btn'} disabled={busy || !value}>
          {busy ? 'Checking…' : action}
        </button>
        <button type="button" className="btn btn--tiny" onClick={onCancel} disabled={busy}>
          Cancel
        </button>
      </div>
      {codeAllowed ? (
        <button
          type="button"
          className="st-linkbutton"
          onClick={() => {
            setMode((current) => (current === 'password' ? 'code' : 'password'));
            setValue('');
            setError(null);
          }}
        >
          {mode === 'password' ? 'Use a code instead' : 'Use your password instead'}
        </button>
      ) : null}
      {error ? <p className="st-error">{error}</p> : null}
    </form>
  );
}
__PC_EOF__
echo "wrote apps/web/src/components/Settings/ConfirmIdentity.jsx"

mkdir -p apps/web/src/components/Settings
cat > apps/web/src/components/Settings/RecoveryCodes.jsx <<'__PC_EOF__'
import { useState } from 'react';

/**
 * Recovery codes, shown exactly once  (Settings, Phase C)
 *
 * The server keeps only hashes, so this is the one moment they can be saved.
 * Copy, download and print; the list stays until "I saved them" is pressed.
 */
export default function RecoveryCodes({ codes, onDone }) {
  const [copied, setCopied] = useState(false);
  const text = `Classroom recovery codes\nEach code works once.\n\n${codes.join('\n')}\n`;

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
    } catch {
      setCopied(false);
    }
  };

  const download = () => {
    const url = URL.createObjectURL(new Blob([text], { type: 'text/plain' }));
    const link = document.createElement('a');
    link.href = url;
    link.download = 'classroom-recovery-codes.txt';
    link.click();
    URL.revokeObjectURL(url);
  };

  return (
    <div className="st-codes" role="region" aria-label="Recovery codes">
      <p className="st-label">Save these recovery codes now</p>
      <p className="st-hint">
        If you lose your phone or your passkeys, each code signs you in once. They are not shown again.
      </p>
      <ol className="st-codes__list">
        {codes.map((code) => (
          <li key={code}>
            <code>{code}</code>
          </li>
        ))}
      </ol>
      <div className="st-inline">
        <button type="button" className="btn btn--tiny" onClick={copy}>
          {copied ? 'Copied' : 'Copy'}
        </button>
        <button type="button" className="btn btn--tiny" onClick={download}>
          Download
        </button>
        <button type="button" className="btn" onClick={onDone}>
          I saved them
        </button>
      </div>
    </div>
  );
}
__PC_EOF__
echo "wrote apps/web/src/components/Settings/RecoveryCodes.jsx"

mkdir -p apps/web/src/components/Settings
cat > apps/web/src/components/Settings/AccountProtection.jsx <<'__PC_EOF__'
import { useState } from 'react';
import { Section } from './fields.jsx';
import ConfirmIdentity from './ConfirmIdentity.jsx';
import RecoveryCodes from './RecoveryCodes.jsx';
import { relativeTime } from './notificationsModel.js';
import { createPasskey, passkeysSupported, suggestedPasskeyName } from '../../lib/webauthn.js';
import { formatDate } from '../../lib/preferences.js';

/**
 * Password, two-step sign-in and passkeys  (Settings, Phase C)
 *
 * Shown at the top of Settings → Sign-in & devices. Every change that lowers
 * protection asks "confirm it's you" first; every change is recorded under
 * Recent changes and confirmed by email.
 */

const detail = (cause, fallback) => cause?.detail ?? cause?.message ?? fallback;

/* ------------------------------------------------------------------ *
 * Password
 * ------------------------------------------------------------------ */

export function PasswordSection({ security, overview, announce, reload }) {
  const [open, setOpen] = useState(false);
  const [current, setCurrent] = useState('');
  const [next, setNext] = useState('');
  const [repeat, setRepeat] = useState('');
  const [signOutOthers, setSignOutOthers] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  const mismatch = repeat.length > 0 && next !== repeat;
  const tooShort = next.length > 0 && next.length < 12;

  const reset = () => {
    setOpen(false);
    setCurrent('');
    setNext('');
    setRepeat('');
    setError(null);
  };

  const submit = async (event) => {
    event.preventDefault();
    if (mismatch || tooShort) return;
    setBusy(true);
    setError(null);
    try {
      const result = await security.changePassword({ currentPassword: current, newPassword: next, signOutOthers });
      reset();
      announce(
        result.signedOut > 0
          ? `Password changed. ${result.signedOut} other ${result.signedOut === 1 ? 'device was' : 'devices were'} signed out.`
          : 'Password changed.',
      );
      reload();
    } catch (cause) {
      setError(detail(cause, 'The password was not changed.'));
    } finally {
      setBusy(false);
    }
  };

  const changed = overview.password.changedAt;

  return (
    <Section
      id="password"
      title="Password"
      hint={changed ? `Last changed ${relativeTime(changed) || formatDate(changed)}.` : 'At least 12 characters. Length matters more than symbols.'}
    >
      {!open ? (
        <button type="button" className="btn" onClick={() => setOpen(true)}>
          Change password
        </button>
      ) : (
        <form className="st-form" onSubmit={submit}>
          <label className="st-label">
            Current password
            <input className="st-input__field" type="password" autoComplete="current-password" value={current} onChange={(e) => setCurrent(e.target.value)} required autoFocus />
          </label>
          <label className="st-label">
            New password
            <input className="st-input__field" type="password" autoComplete="new-password" value={next} onChange={(e) => setNext(e.target.value)} required minLength={12} aria-invalid={tooShort} />
            {tooShort ? <span className="st-hint">At least 12 characters.</span> : null}
          </label>
          <label className="st-label">
            New password again
            <input className="st-input__field" type="password" autoComplete="new-password" value={repeat} onChange={(e) => setRepeat(e.target.value)} required aria-invalid={mismatch} />
            {mismatch ? <span className="st-error">The two new passwords are not the same.</span> : null}
          </label>
          <label className="st-check-row">
            <input type="checkbox" className="st-check" checked={signOutOthers} onChange={(e) => setSignOutOthers(e.target.checked)} />
            <span>Sign out every other device</span>
          </label>
          {error ? <p className="st-error">{error}</p> : null}
          <div className="st-inline">
            <button type="submit" className="btn" disabled={busy || mismatch || tooShort || !current || !next}>
              {busy ? 'Saving…' : 'Change password'}
            </button>
            <button type="button" className="btn btn--tiny" onClick={reset} disabled={busy}>
              Cancel
            </button>
          </div>
        </form>
      )}
    </Section>
  );
}

/* ------------------------------------------------------------------ *
 * Authenticator app and recovery codes
 * ------------------------------------------------------------------ */

export function TwoStepSection({ security, overview, announce, reload }) {
  // idle · confirm-setup · scanning · codes · confirm-disable · confirm-codes
  const [step, setStep] = useState('idle');
  const [setup, setSetup] = useState(null);
  const [code, setCode] = useState('');
  const [codes, setCodes] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  const { twoStep } = overview;
  const appOn = twoStep.totp.enabled;
  const codeAllowed = twoStep.required;

  const done = () => {
    setStep('idle');
    setSetup(null);
    setCode('');
    setCodes(null);
    setError(null);
    reload();
  };

  const verify = async (event) => {
    event.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const result = await security.enableTotp(code);
      setCodes(result.recoveryCodes);
      setStep('codes');
      announce('Two-step sign-in is on.');
    } catch (cause) {
      setError(detail(cause, 'That code is not right.'));
      setCode('');
    } finally {
      setBusy(false);
    }
  };

  let body;
  if (step === 'confirm-setup') {
    body = (
      <ConfirmIdentity
        action="Continue"
        codeAllowed={codeAllowed}
        onCancel={done}
        onConfirm={async (confirmation) => {
          setSetup(await security.startTotpSetup(confirmation));
          setStep('scanning');
        }}
      />
    );
  } else if (step === 'scanning' && setup) {
    body = (
      <form className="st-totp" onSubmit={verify}>
        <ol className="st-steps">
          <li>Open an authenticator app on your phone (Google Authenticator, Microsoft Authenticator, 1Password, …).</li>
          <li>Scan this code, or enter the key by hand.</li>
          <li>Type the 6-digit code the app shows.</li>
        </ol>
        <div className="st-totp__pair">
          {setup.qr ? <img className="st-totp__qr" src={setup.qr} alt="QR code for your authenticator app" width={180} height={180} /> : null}
          <div className="st-totp__key">
            <span className="st-hint">Key</span>
            <code className="st-totp__secret">{setup.secret.replace(/(.{4})/g, '$1 ').trim()}</code>
            <a className="st-hint" href={setup.uri}>Open in an authenticator app on this device</a>
          </div>
        </div>
        <label className="st-label">
          Code from the app
          <input className="st-input__field st-code-input" inputMode="numeric" autoComplete="one-time-code" maxLength={7} value={code} onChange={(e) => setCode(e.target.value)} placeholder="123456" autoFocus required />
        </label>
        {error ? <p className="st-error">{error}</p> : null}
        <div className="st-inline">
          <button type="submit" className="btn" disabled={busy || code.replace(/\s/g, '').length !== 6}>
            {busy ? 'Checking…' : 'Turn on'}
          </button>
          <button type="button" className="btn btn--tiny" onClick={done}>
            Cancel
          </button>
        </div>
      </form>
    );
  } else if (step === 'codes' && codes) {
    body = <RecoveryCodes codes={codes} onDone={done} />;
  } else if (step === 'confirm-disable') {
    body = (
      <ConfirmIdentity
        action="Remove the app"
        danger
        codeAllowed={codeAllowed}
        onCancel={done}
        onConfirm={async (confirmation) => {
          await security.disableTotp(confirmation);
          announce('The authenticator app was removed.');
          done();
        }}
      />
    );
  } else if (step === 'confirm-codes') {
    body = (
      <ConfirmIdentity
        action="Make new codes"
        codeAllowed={codeAllowed}
        onCancel={done}
        onConfirm={async (confirmation) => {
          const result = await security.regenerateRecoveryCodes(confirmation);
          setCodes(result.recoveryCodes);
          setStep('codes');
        }}
      />
    );
  } else {
    body = (
      <>
        <p>
          {appOn
            ? `On since ${formatDate(twoStep.totp.enabledAt)}. Signing in needs your password and a code from the app.`
            : 'Off. With it on, a stolen password alone cannot sign in to your account.'}
        </p>
        <div className="st-inline">
          {appOn ? (
            <button type="button" className="btn btn--tiny" onClick={() => setStep('confirm-disable')}>
              Remove the app
            </button>
          ) : (
            <button type="button" className="btn" onClick={() => setStep('confirm-setup')}>
              Set up an authenticator app
            </button>
          )}
        </div>
        {twoStep.required ? (
          <div className="st-inline">
            <span className={twoStep.recoveryCodesRemaining <= 2 ? 'st-error' : 'st-hint'}>
              {twoStep.recoveryCodesRemaining} recovery {twoStep.recoveryCodesRemaining === 1 ? 'code' : 'codes'} left.
            </span>
            <button type="button" className="btn btn--tiny" onClick={() => setStep('confirm-codes')}>
              Make new recovery codes
            </button>
          </div>
        ) : null}
      </>
    );
  }

  return (
    <Section id="two-step" title="Two-step sign-in" hint="A code from your phone in addition to your password.">
      {body}
    </Section>
  );
}

/* ------------------------------------------------------------------ *
 * Passkeys
 * ------------------------------------------------------------------ */

export function PasskeySection({ security, overview, announce, reload }) {
  const [step, setStep] = useState('idle'); // idle · confirm-add · codes · remove:<id>
  const [codes, setCodes] = useState(null);
  const [renaming, setRenaming] = useState(null);
  const [error, setError] = useState(null);

  const { passkeys, twoStep } = overview;
  const supported = passkeysSupported();

  const done = () => {
    setStep('idle');
    setCodes(null);
    setError(null);
    reload();
  };

  const add = async (confirmation) => {
    const { optionsId, options } = await security.passkeyRegistrationOptions(confirmation);
    const response = await createPasskey(options);
    const result = await security.addPasskey({ optionsId, response, name: suggestedPasskeyName() });
    announce(`Passkey "${result.passkey.name}" added.`);
    if (result.recoveryCodes?.length) {
      setCodes(result.recoveryCodes);
      setStep('codes');
    } else {
      done();
    }
  };

  const rename = async (passkey, name) => {
    setRenaming(null);
    if (!name.trim() || name.trim() === passkey.name) return;
    try {
      await security.renamePasskey(passkey.id, name.trim());
      reload();
    } catch (cause) {
      setError(detail(cause, 'The passkey was not renamed.'));
    }
  };

  let hint = 'Sign in with your fingerprint, face or device PIN — no password, nothing to phish.';
  if (!passkeys.available) hint = 'Passkeys are not set up on the server yet.';
  else if (!supported) hint = 'This browser cannot create passkeys.';

  const removing = step.startsWith('remove:') ? step.slice(7) : null;

  return (
    <Section id="passkeys" title="Passkeys" hint={hint}>
      {step === 'codes' && codes ? <RecoveryCodes codes={codes} onDone={done} /> : null}

      {passkeys.items.map((passkey) => (
        <div key={passkey.id} className="st-session">
          <div className="st-session__info">
            {renaming === passkey.id ? (
              <input
                className="st-input__field"
                defaultValue={passkey.name}
                maxLength={60}
                autoFocus
                aria-label="Passkey name"
                onBlur={(event) => rename(passkey, event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === 'Enter') event.currentTarget.blur();
                  if (event.key === 'Escape') setRenaming(null);
                }}
              />
            ) : (
              <span className="st-label">
                {passkey.name}
                {passkey.backedUp ? <span className="st-badge">Synced</span> : null}
              </span>
            )}
            <span className="st-hint">
              Added {formatDate(passkey.createdAt)}
              {passkey.lastUsedAt ? ` · last used ${relativeTime(passkey.lastUsedAt)}` : ' · not used yet'}
            </span>
          </div>
          {removing === passkey.id ? null : (
            <span className="st-inline">
              <button type="button" className="btn btn--tiny" onClick={() => setRenaming(passkey.id)}>
                Rename
              </button>
              <button type="button" className="btn btn--tiny" onClick={() => setStep(`remove:${passkey.id}`)}>
                Remove…
              </button>
            </span>
          )}
          {removing === passkey.id ? (
            <ConfirmIdentity
              action="Remove passkey"
              danger
              codeAllowed={twoStep.required}
              onCancel={done}
              onConfirm={async (confirmation) => {
                await security.removePasskey(passkey.id, confirmation);
                announce(`Passkey "${passkey.name}" removed.`);
                done();
              }}
            />
          ) : null}
        </div>
      ))}

      {step === 'confirm-add' ? (
        <ConfirmIdentity action="Continue" codeAllowed={twoStep.required} onCancel={done} onConfirm={add} />
      ) : passkeys.available && supported && step === 'idle' ? (
        <button type="button" className="btn" onClick={() => setStep('confirm-add')}>
          Add a passkey
        </button>
      ) : null}
      {error ? <p className="st-error">{error}</p> : null}
    </Section>
  );
}
__PC_EOF__
echo "wrote apps/web/src/components/Settings/AccountProtection.jsx"

mkdir -p apps/web/src/components/Settings
cat > apps/web/src/components/Settings/SecuritySettings.jsx <<'__PC_EOF__'
import { useCallback, useEffect, useMemo, useState } from 'react';
import { createAccountSecurityApi, useCore } from '@classroom/core-client';
import { Section } from './fields.jsx';
import { PasskeySection, PasswordSection, TwoStepSection } from './AccountProtection.jsx';
import { describeHistoryEntry, relativeTime } from './notificationsModel.js';
import { formatDate, formatTime } from '../../lib/preferences.js';

/**
 * Sign-in & devices  (Settings, Phase B + C)
 *
 * Phase C puts password, two-step sign-in and passkeys at the top
 * (AccountProtection.jsx).
 *
 * Every device signed in to the account, this one marked, each with a way to
 * sign it out; "sign out everywhere else"; and the sign-ins and failed
 * attempts of the last weeks. A device that is signed out here stops at once:
 * its next request is refused and its open tabs return to the sign-in page.
 */

const when = (value) => (value ? `${formatDate(value)}, ${formatTime(value)}` : '');

export function HistoryList({ load, empty, reloadKey }) {
  const [items, setItems] = useState(null);
  const [cursor, setCursor] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(false);

  const fetchPage = useCallback(
    async (from = null) => {
      setBusy(true);
      setError(false);
      try {
        const page = await load({ cursor: from, limit: 20 });
        setItems((current) => (from ? [...(current ?? []), ...page.items] : page.items));
        setCursor(page.nextCursor);
      } catch {
        setError(true);
        setItems((current) => current ?? []);
      } finally {
        setBusy(false);
      }
    },
    [load],
  );

  useEffect(() => {
    fetchPage(null);
  }, [fetchPage, reloadKey]);

  if (items === null) return <p className="st-hint">Loading…</p>;

  return (
    <>
      {error ? <p className="st-error">The history could not be loaded.</p> : null}
      {items.length === 0 && !error ? <p className="st-hint">{empty}</p> : null}
      <ul className="st-history">
        {items.map((entry) => (
          <li key={entry.id} className={entry.action === 'auth.login.failed' ? 'st-history__item is-warning' : 'st-history__item'}>
            <span className="st-history__what">{describeHistoryEntry(entry)}</span>
            <span className="st-hint">
              {when(entry.at)}
              {entry.device ? ` · ${entry.device}` : ''}
              {entry.ip ? ` · ${entry.ip}` : ''}
            </span>
          </li>
        ))}
      </ul>
      {cursor ? (
        <button type="button" className="btn btn--tiny" disabled={busy} onClick={() => fetchPage(cursor)}>
          {busy ? 'Loading…' : 'Show older'}
        </button>
      ) : null}
    </>
  );
}

/** Password, two-step sign-in and passkeys, loaded together. */
function Protection({ announce, reloadKey }) {
  const { http } = useCore();
  const security = useMemo(() => createAccountSecurityApi(http), [http]);
  const [overview, setOverview] = useState(null);
  const [failed, setFailed] = useState(false);

  const reload = useCallback(async () => {
    try {
      setOverview(await security.overview());
      setFailed(false);
    } catch {
      setFailed(true);
    }
  }, [security]);

  useEffect(() => {
    reload();
  }, [reload, reloadKey]);

  if (failed && !overview) {
    return (
      <Section id="password" title="Password and two-step sign-in">
        <p className="st-error">These settings could not be loaded.</p>
        <button type="button" className="btn" onClick={reload}>
          Try again
        </button>
      </Section>
    );
  }
  if (!overview) return <p className="st-hint">Loading…</p>;

  const props = { security, overview, announce, reload };
  return (
    <>
      <PasswordSection {...props} />
      <TwoStepSection {...props} />
      <PasskeySection {...props} />
    </>
  );
}

export default function SecuritySettings({ account, announce, reloadKey }) {
  const [sessions, setSessions] = useState(null);
  const [confirming, setConfirming] = useState(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      setSessions((await account.listSessions()).items);
    } catch {
      setSessions([]);
    }
  }, [account]);

  useEffect(() => {
    load();
  }, [load, reloadKey]);

  const signOut = async (session) => {
    setBusy(true);
    try {
      await account.signOutSession(session.sessionId);
      announce(`${session.label} was signed out.`);
      setConfirming(null);
      await load();
    } catch (cause) {
      announce(cause?.detail ?? 'That device could not be signed out.', null, true);
    } finally {
      setBusy(false);
    }
  };

  const signOutOthers = async () => {
    setBusy(true);
    try {
      const { revoked } = await account.signOutOtherSessions();
      announce(revoked === 0 ? 'No other device was signed in.' : `Signed out ${revoked} ${revoked === 1 ? 'device' : 'devices'}.`);
      setConfirming(null);
      await load();
    } catch (cause) {
      announce(cause?.detail ?? 'The other devices could not be signed out.', null, true);
    } finally {
      setBusy(false);
    }
  };

  const others = (sessions ?? []).filter((session) => !session.current);
  const loadHistory = useCallback((query) => account.loginHistory(query), [account]);

  return (
    <>
      <Protection announce={announce} reloadKey={reloadKey} />

      <Section
        id="sessions"
        title="Where you are signed in"
        hint="Something you do not recognise? Sign it out, then change your password."
      >
        {sessions === null ? <p className="st-hint">Loading…</p> : null}
        {sessions?.map((session) => (
          <div key={session.sessionId} className="st-session">
            <div className="st-session__info">
              <span className="st-label">
                {session.label}
                {session.current ? <span className="st-badge">This device</span> : null}
              </span>
              <span className="st-hint">
                {session.current ? 'Active now' : `Last active ${relativeTime(session.lastActiveAt) || 'unknown'}`}
                {session.ip ? ` · ${session.ip}` : ''}
                {session.createdAt ? ` · signed in ${when(session.createdAt)}` : ''}
              </span>
            </div>
            {session.current ? null : confirming === session.sessionId ? (
              <span className="st-inline">
                <button type="button" className="btn btn--tiny btn--danger" disabled={busy} onClick={() => signOut(session)}>
                  Sign out
                </button>
                <button type="button" className="btn btn--tiny" onClick={() => setConfirming(null)}>
                  Cancel
                </button>
              </span>
            ) : (
              <button type="button" className="btn btn--tiny" onClick={() => setConfirming(session.sessionId)}>
                Sign out…
              </button>
            )}
          </div>
        ))}
      </Section>

      <Section id="sign-out-others" title="Sign out everywhere else" hint="Every device except this one has to sign in again.">
        {confirming === 'others' ? (
          <span className="st-inline">
            <span>Sign out {others.length} {others.length === 1 ? 'device' : 'devices'}?</span>
            <button type="button" className="btn btn--tiny btn--danger" disabled={busy} onClick={signOutOthers}>
              Sign them out
            </button>
            <button type="button" className="btn btn--tiny" onClick={() => setConfirming(null)}>
              Cancel
            </button>
          </span>
        ) : (
          <button type="button" className="btn" disabled={others.length === 0} onClick={() => setConfirming('others')}>
            Sign out all other devices
          </button>
        )}
      </Section>

      <Section id="login-history" title="Sign-in history" hint="Sign-ins and failed attempts on your account.">
        <HistoryList load={loadHistory} empty="No sign-ins recorded yet." reloadKey={reloadKey} />
      </Section>
    </>
  );
}
__PC_EOF__
echo "wrote apps/web/src/components/Settings/SecuritySettings.jsx"

mkdir -p apps/web/src/components/Settings
cat > apps/web/src/components/Settings/DataSettings.jsx <<'__PC_EOF__'
import { useCallback, useEffect, useMemo, useState } from 'react';
import { createAccountSecurityApi, useCore } from '@classroom/core-client';
import { Section } from './fields.jsx';
import ConfirmIdentity from './ConfirmIdentity.jsx';
import { formatDate } from '../../lib/preferences.js';

/**
 * Your data  (Settings, Phase C)
 *
 *   export     everything the platform keeps about you, as one JSON file
 *   delete     the account, after 14 days in which signing in and pressing
 *              Cancel keeps it. Messages and posts stay in their chats and
 *              courses as "Deleted user"; everything personal goes.
 */

const saveJson = (data) => {
  const date = new Date().toISOString().slice(0, 10);
  const url = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' }));
  const link = document.createElement('a');
  link.href = url;
  link.download = `classroom-export-${date}.json`;
  document.body.appendChild(link);
  link.click();
  link.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 10_000);
};

export default function DataSettings({ announce, reloadKey }) {
  const { http, signOut } = useCore();
  const security = useMemo(() => createAccountSecurityApi(http), [http]);
  const [overview, setOverview] = useState(null);
  const [exporting, setExporting] = useState(false);
  const [confirming, setConfirming] = useState(false);

  const load = useCallback(async () => {
    try {
      setOverview(await security.overview());
    } catch {
      setOverview((current) => current ?? { deletion: null, twoStep: { required: false } });
    }
  }, [security]);

  useEffect(() => {
    load();
  }, [load, reloadKey]);

  const exportData = async () => {
    setExporting(true);
    try {
      saveJson(await security.exportData());
      announce('Your data was downloaded.');
    } catch (cause) {
      announce(cause?.detail ?? 'The download could not be prepared. Try again later.', null, true);
    } finally {
      setExporting(false);
    }
  };

  const cancelDeletion = async () => {
    try {
      await security.cancelDeletion();
      announce('Your account will not be deleted.');
      await load();
    } catch (cause) {
      announce(cause?.detail ?? 'The deletion could not be cancelled.', null, true);
    }
  };

  if (!overview) return <p className="st-hint">Loading…</p>;
  const scheduled = overview.deletion?.scheduledFor ?? null;

  return (
    <>
      <Section
        id="export"
        title="Download your data"
        hint="Your account, profile and settings, devices and history, messages and posts you wrote, courses, progress and notifications — as one JSON file. Passwords and keys are never included."
      >
        <button type="button" className="btn" onClick={exportData} disabled={exporting}>
          {exporting ? 'Preparing…' : 'Download my data'}
        </button>
      </Section>

      <Section id="delete-account" title="Delete your account">
        {scheduled ? (
          <div className="st-danger-zone">
            <p className="st-label">Your account will be deleted on {formatDate(scheduled)}.</p>
            <p className="st-hint">Until then it works as usual. After that date it cannot be restored.</p>
            <button type="button" className="btn" onClick={cancelDeletion}>
              Keep my account
            </button>
          </div>
        ) : (
          <div className="st-danger-zone">
            <p className="st-hint">
              Your name, email, profile, settings, notifications, passkeys and two-step sign-in are removed. Messages,
              posts and grades stay in their chats and courses, shown as “Deleted user”. You have 14 days to change your
              mind: sign in and press “Keep my account”. Every other device is signed out now.
            </p>
            {confirming ? (
              <ConfirmIdentity
                action="Delete my account"
                danger
                codeAllowed={overview.twoStep?.required}
                onCancel={() => setConfirming(false)}
                onConfirm={async (confirmation) => {
                  const result = await security.requestDeletion(confirmation);
                  setConfirming(false);
                  announce(`Your account will be deleted on ${formatDate(result.deletion.scheduledFor)}.`);
                  await load();
                }}
              />
            ) : (
              <div className="st-inline">
                <button type="button" className="btn btn--danger" onClick={() => setConfirming(true)}>
                  Delete my account…
                </button>
                <button type="button" className="btn btn--tiny" onClick={() => signOut().catch(() => undefined)}>
                  Just sign out
                </button>
              </div>
            )}
          </div>
        )}
      </Section>
    </>
  );
}
__PC_EOF__
echo "wrote apps/web/src/components/Settings/DataSettings.jsx"

mkdir -p apps/web/src/components/Settings
cat > apps/web/src/components/Settings/notificationsModel.js <<'__PC_EOF__'
/**
 * Pure helpers for Settings → Notifications, Sign-in & devices and Recent
 * changes (Settings, Phase B). No React, no network: tested in
 * __checks__/notificationsModel.check.mjs.
 */

export const CATEGORY_ROWS = Object.freeze([
  { id: 'directMessages', label: 'Private messages', hint: 'Chats with one person or a group.' },
  { id: 'mentions', label: 'Mentions', hint: 'Someone writes your @handle.' },
  {
    id: 'channelMessages',
    label: 'Chatroom messages',
    hint: 'Every message in the chatrooms you can read. Off by default — mentions still reach you.',
  },
  { id: 'lessonReminders', label: 'Lesson reminders', hint: 'A day before, and 10 minutes before a lesson.' },
  { id: 'coursework', label: 'Courses', hint: 'Recordings, assignments and course updates.' },
  { id: 'community', label: 'Community', hint: 'Replies to threads you follow, and other activity.' },
]);

export const CHANNEL_COLUMNS = Object.freeze([
  { id: 'inApp', label: 'In the app' },
  { id: 'push', label: 'Push' },
  { id: 'email', label: 'Email' },
]);

const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);

/** The values `source` holds at every path `patch` touches — the undo of that patch. */
export const pickDeep = (source, patch) => {
  if (!isObject(patch)) return source;
  const result = {};
  for (const [key, value] of Object.entries(patch)) {
    result[key] = isObject(value) ? pickDeep(source?.[key] ?? {}, value) : source?.[key];
  }
  return result;
};

/** A copy of `target` with `patch` merged in, object by object. */
export const mergeDeep = (target, patch) => {
  if (!isObject(patch)) return patch;
  const result = { ...(isObject(target) ? target : {}) };
  for (const [key, value] of Object.entries(patch)) {
    result[key] = isObject(value) ? mergeDeep(result[key], value) : value;
  }
  return result;
};

/** "for 3 more hours", "until Mon 14:00", "until you turn it back on". */
export const describeMuteEnd = (mutedUntil, now = new Date(), format = defaultFormat) => {
  if (!mutedUntil) return 'until you turn it back on';
  const end = new Date(mutedUntil);
  const minutes = Math.round((end.getTime() - now.getTime()) / 60_000);
  if (Number.isNaN(minutes) || minutes <= 0) return 'ending now';
  if (minutes < 60) return `for ${minutes} more ${minutes === 1 ? 'minute' : 'minutes'}`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `for ${hours} more ${hours === 1 ? 'hour' : 'hours'}`;
  return `until ${format(end)}`;
};

function defaultFormat(date) {
  return date.toISOString().slice(0, 16).replace('T', ' ');
}

/** "just now", "5 minutes ago", "3 hours ago", "2 days ago". */
export const relativeTime = (value, now = new Date()) => {
  if (!value) return '';
  const seconds = Math.round((now.getTime() - new Date(value).getTime()) / 1000);
  if (Number.isNaN(seconds)) return '';
  if (seconds < 60) return 'just now';
  const units = [
    [60 * 60 * 24, 'day'],
    [60 * 60, 'hour'],
    [60, 'minute'],
  ];
  for (const [size, name] of units) {
    const count = Math.floor(seconds / size);
    if (count >= 1) return `${count} ${name}${count === 1 ? '' : 's'} ago`;
  }
  return 'just now';
};

const SECTION_LABELS = {
  profile: 'Profile',
  privacy: 'Privacy',
  preferences: 'Preferences',
  notifications: 'Notifications',
};

const FIELD_LABELS = {
  displayName: 'display name',
  handle: 'handle',
  headline: 'headline',
  bio: 'about me',
  links: 'links',
  locale: 'language',
  timeZone: 'time zone',
  dmPolicy: 'who can message you',
  visibility: 'profile visibility',
  showPresence: 'online status',
  sendReadReceipts: 'read receipts',
  appearance: 'appearance',
  region: 'date and time format',
  lesson: 'lesson settings',
  roomDefaults: 'lesson defaults',
  categories: 'which notifications you get',
  quietHours: 'quiet hours',
  focusDuringLessons: 'focus during lessons',
  showPreviews: 'message previews',
  digest: 'community digest',
};

/** One line of Recent changes or Sign-in history, in plain words. */
export const describeHistoryEntry = (entry) => {
  switch (entry.action) {
    case 'auth.login.succeeded':
      return 'Signed in';
    case 'auth.login.failed':
      return entry.detail === 'too-many-attempts'
        ? 'Sign-in blocked after too many attempts'
        : 'Failed sign-in attempt (wrong password)';
    case 'auth.second_factor.failed':
      return entry.detail === 'passkey'
        ? 'Password right, passkey refused'
        : 'Password right, wrong second-step code';
    case 'security.password.changed':
      return (entry.count ?? 0) > 0
        ? `Password changed; ${entry.count} other ${entry.count === 1 ? 'device' : 'devices'} signed out`
        : 'Password changed';
    case 'security.totp.enabled':
      return 'Two-step sign-in turned on (authenticator app)';
    case 'security.totp.disabled':
      return 'Authenticator app removed';
    case 'security.recovery_codes.regenerated':
      return 'New recovery codes made; the old ones stopped working';
    case 'security.passkey.added':
      return entry.detail ? `Passkey added: ${entry.detail}` : 'Passkey added';
    case 'security.passkey.removed':
      return entry.detail ? `Passkey removed: ${entry.detail}` : 'Passkey removed';
    case 'account.exported':
      return 'Your data was downloaded';
    case 'account.deletion.requested':
      return 'Account deletion requested';
    case 'account.deletion.cancelled':
      return 'Account deletion cancelled';
    case 'auth.session.revoked':
      if ((entry.count ?? 1) > 1) return `Signed out ${entry.count} other devices`;
      return entry.detail ? `Signed out ${entry.detail}` : 'Signed out another device';
    case 'settings.changed': {
      const section = SECTION_LABELS[entry.section] ?? 'Settings';
      const tops = [...new Set((entry.fields ?? []).map((field) => field.split('.')[0]))];
      const names = tops.map((field) => FIELD_LABELS[field] ?? field);
      return names.length ? `${section}: changed ${names.join(', ')}` : `${section} changed`;
    }
    default:
      return entry.action;
  }
};

/** Quiet hours as words: "22:00 – 07:00 (overnight)". */
export const describeQuietHours = ({ start, end }) =>
  `${start} – ${end}${start > end ? ' (overnight)' : ''}`;
__PC_EOF__
echo "wrote apps/web/src/components/Settings/notificationsModel.js"

mkdir -p apps/web/src/components/Settings/__checks__
cat > apps/web/src/components/Settings/__checks__/security.check.mjs <<'__PC_EOF__'
// Settings, Phase C — passkey conversion in the browser and history wording.
// Run: node --test apps/web/src/components/Settings/__checks__/*.check.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  creationOptionsFromJSON,
  fromBase64Url,
  requestOptionsFromJSON,
  suggestedPasskeyName,
  toBase64Url,
} from '../../../lib/webauthn.js';
import { describeHistoryEntry } from '../notificationsModel.js';

test('base64url round-trips bytes the way WebAuthn sends them', () => {
  const bytes = new Uint8Array([0, 1, 250, 251, 252, 253, 254, 255, 62, 63]);
  const text = toBase64Url(bytes);
  assert.doesNotMatch(text, /[+/=]/);
  assert.deepEqual(new Uint8Array(fromBase64Url(text)), bytes);
});

test('registration options become buffers where the browser wants them', () => {
  const options = creationOptionsFromJSON({
    challenge: toBase64Url(new Uint8Array([1, 2, 3])),
    rp: { id: 'localhost', name: 'Classroom' },
    user: { id: toBase64Url(new TextEncoder().encode('user-1')), name: 'a@b.c', displayName: 'A' },
    pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
    excludeCredentials: [{ id: toBase64Url(new Uint8Array([9])), transports: ['internal'] }],
  });
  assert.ok(options.challenge instanceof ArrayBuffer);
  assert.equal(new TextDecoder().decode(options.user.id), 'user-1');
  assert.equal(options.excludeCredentials[0].type, 'public-key');
  assert.deepEqual(new Uint8Array(options.excludeCredentials[0].id), new Uint8Array([9]));
});

test('sign-in options without allowed credentials let the browser choose', () => {
  const discoverable = requestOptionsFromJSON({ challenge: 'AQID', allowCredentials: [] });
  assert.equal('allowCredentials' in discoverable, false);
  const specific = requestOptionsFromJSON({ challenge: 'AQID', allowCredentials: [{ id: 'CQ', type: 'public-key' }] });
  assert.equal(specific.allowCredentials.length, 1);
});

test('a new passkey gets a readable name', () => {
  assert.equal(
    suggestedPasskeyName('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'),
    'Chrome on Windows',
  );
  assert.equal(
    suggestedPasskeyName('Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1'),
    'Safari on iPhone or iPad',
  );
});

test('security changes read as sentences', () => {
  assert.equal(describeHistoryEntry({ action: 'security.totp.enabled' }), 'Two-step sign-in turned on (authenticator app)');
  assert.equal(describeHistoryEntry({ action: 'security.password.changed', count: 2 }), 'Password changed; 2 other devices signed out');
  assert.equal(describeHistoryEntry({ action: 'security.passkey.added', detail: 'Chrome on Mac' }), 'Passkey added: Chrome on Mac');
  assert.equal(describeHistoryEntry({ action: 'auth.second_factor.failed', detail: 'code' }), 'Password right, wrong second-step code');
  assert.equal(describeHistoryEntry({ action: 'account.deletion.requested' }), 'Account deletion requested');
});
__PC_EOF__
echo "wrote apps/web/src/components/Settings/__checks__/security.check.mjs"

mkdir -p apps/web/src/components/system
cat > apps/web/src/components/system/DeletionBanner.jsx <<'__PC_EOF__'
import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { createAccountSecurityApi, useCore } from '@classroom/core-client';
import { onUserEvent } from '../../lib/userEvents.js';
import { formatDate } from '../../lib/preferences.js';
import './notifications.css';

/**
 * "Your account will be deleted on …"  (Settings, Phase C)
 *
 * Shown on every page while an account is in its grace period, with the one
 * button that matters. Reloads when security settings change on another
 * device, so cancelling on the phone clears it on the laptop.
 */
export default function DeletionBanner() {
  const core = useCore();
  const { http, status } = core;
  const security = useMemo(() => createAccountSecurityApi(http), [http]);
  const [scheduledFor, setScheduledFor] = useState(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      setScheduledFor((await security.overview()).deletion?.scheduledFor ?? null);
    } catch {
      // No banner is better than a wrong one.
    }
  }, [security]);

  useEffect(() => {
    if (status !== 'authenticated') {
      setScheduledFor(null);
      return undefined;
    }
    load();
    return onUserEvent(core, 'settings:changed', (payload) => {
      if (!payload?.section || payload.section === 'security') load();
    });
  }, [core, status, load]);

  if (!scheduledFor) return null;

  const keep = async () => {
    setBusy(true);
    try {
      await security.cancelDeletion();
      setScheduledFor(null);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="nt-banner" role="alert">
      <span>
        Your account will be deleted on <strong>{formatDate(scheduledFor)}</strong>.{' '}
        <Link to="/settings/data">Details</Link>
      </span>
      <button type="button" className="nt-banner__action" onClick={keep} disabled={busy}>
        Keep my account
      </button>
    </div>
  );
}
__PC_EOF__
echo "wrote apps/web/src/components/system/DeletionBanner.jsx"

mkdir -p apps/web/src/components/system
cat > apps/web/src/components/system/notifications.css <<'__PC_EOF__'
/* On-screen notifications — see components/system/NotificationToasts.jsx */

.nt-stack { position: fixed; inset-block-start: 16px; inset-inline-end: 16px; z-index: 60; display: flex; flex-direction: column; gap: 8px; width: min(360px, calc(100vw - 32px)); }
.nt-toast { display: flex; align-items: flex-start; gap: 4px; border-radius: 12px; background: var(--color-surface, #fff); color: inherit; border: 1px solid rgba(127,127,127,.25); box-shadow: 0 10px 28px rgba(0,0,0,.18); animation: nt-in .18s ease-out; }
.nt-toast__body { flex: 1 1 auto; min-width: 0; display: flex; flex-direction: column; gap: 2px; padding: 12px 4px 12px 14px; border: 0; background: transparent; color: inherit; font: inherit; text-align: start; cursor: pointer; }
.nt-toast__title { font-weight: 700; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.nt-toast__text { font-size: .9rem; opacity: .8; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
.nt-toast__close { border: 0; background: transparent; color: inherit; font-size: 1.2rem; line-height: 1; padding: 10px 12px; cursor: pointer; opacity: .6; }
.nt-toast__close:hover, .nt-toast__close:focus-visible { opacity: 1; }
@keyframes nt-in { from { opacity: 0; transform: translateY(-6px); } to { opacity: 1; transform: none; } }
@media (prefers-reduced-motion: reduce) { .nt-toast { animation: none; } }

/* Account scheduled for deletion — see components/system/DeletionBanner.jsx (Phase C) */
.nt-banner { display: flex; flex-wrap: wrap; align-items: center; justify-content: center; gap: 12px; padding: 10px 16px; background: #fef3c7; color: #78350f; border-bottom: 1px solid #f59e0b; }
.nt-banner a { color: inherit; font-weight: 600; }
.nt-banner__action { border: 1px solid #b45309; border-radius: 8px; padding: 6px 12px; background: #fff; color: #78350f; font: inherit; font-weight: 700; cursor: pointer; }
.nt-banner__action:disabled { opacity: .6; cursor: default; }
__PC_EOF__
echo "wrote apps/web/src/components/system/notifications.css"

cat > .phaseC-patch.mjs <<'__PC_EOF__'
import { existsSync, readFileSync, writeFileSync } from 'node:fs';

/*
 * Settings, Phase C — edits to files that stay otherwise untouched.
 * Every anchor must be found exactly once; if one is not, nothing is written
 * to any of these files and the installer stops.
 */

const CSS_C = `

/* ---- Phase C: password, two-step sign-in, passkeys, your data ---- */

.st-form { display: flex; flex-direction: column; gap: 12px; max-width: 420px; }
.st-check-row { display: flex; align-items: center; gap: 10px; cursor: pointer; }
.st-confirm { display: flex; flex-direction: column; gap: 8px; padding: 12px; border-radius: 10px; background: rgba(127,127,127,.08); max-width: 560px; }
.st-confirm .st-linkbutton { align-self: flex-start; }

.st-codes { display: flex; flex-direction: column; gap: 10px; padding: 14px; border-radius: 10px; border: 2px dashed #f59e0b; background: rgba(245,158,11,.07); max-width: 520px; }
.st-codes__list { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 6px 24px; margin: 0; padding-inline-start: 22px; }
.st-codes__list code { font-size: 1rem; letter-spacing: .06em; }

.st-totp { display: flex; flex-direction: column; gap: 12px; max-width: 560px; }
.st-steps { margin: 0; padding-inline-start: 20px; display: flex; flex-direction: column; gap: 4px; }
.st-totp__pair { display: flex; flex-wrap: wrap; gap: 16px; align-items: center; }
.st-totp__qr { border-radius: 8px; background: #fff; padding: 6px; }
.st-totp__key { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
.st-totp__secret { font-size: .95rem; letter-spacing: .08em; word-break: break-all; }
.st-code-input { max-width: 10em; font-size: 1.2rem; letter-spacing: .2em; }

.st-danger-zone { display: flex; flex-direction: column; gap: 10px; padding: 14px; border-radius: 10px; border: 1px solid rgba(185,28,28,.35); }
`;

const INDEX_C =
  "  { tab: 'security', anchor: 'password', label: 'Change password', keywords: 'password change new security' },\n" +
  "  { tab: 'security', anchor: 'two-step', label: 'Two-step sign-in', keywords: '2fa two factor two-step authenticator app code otp totp recovery codes security' },\n" +
  "  { tab: 'security', anchor: 'passkeys', label: 'Passkeys', keywords: 'passkey webauthn fingerprint face id touch id windows hello passwordless security key' },\n" +
  "  { tab: 'data', anchor: 'export', label: 'Download your data', keywords: 'export download data copy gdpr takeout' },\n" +
  "  { tab: 'data', anchor: 'delete-account', label: 'Delete your account', keywords: 'delete remove close account deactivate gdpr' },\n";

const plan = [
  {
    file: 'server/src/app.js',
    marker: 'accountSecurityRoutes',
    edits: [
      {
        name: 'import the account security routes',
        regex: /^import\s+accountRoutes\s+from\s+['"]([^'"]*)account\.routes\.js['"];?[ \t]*\r?\n/m,
        replace: (m, dir) => `${m}import accountSecurityRoutes from '${dir}accountSecurity.routes.js';\n`,
      },
      {
        name: 'mount them under /account/security',
        regex: /^([ \t]*)app\.use\(\s*['"]\/account['"],\s*accountRoutes\s*\);[^\n]*\r?\n/m,
        replace: (m, indent) => `${m}${indent}app.use('/account/security', accountSecurityRoutes); // Settings, Phase C\n`,
      },
    ],
  },
  {
    file: 'packages/core-client/src/index.ts',
    marker: 'accountSecurityApi',
    edits: [
      {
        name: 'export the account security API',
        find: "export * from './api/accountApi.js';\n",
        replace: "export * from './api/accountApi.js';\nexport * from './api/accountSecurityApi.js';\n",
      },
    ],
  },
  {
    file: 'server/src/signaling/authSocket.js',
    marker: 'SessionActivity.isRevoked',
    edits: [
      {
        name: 'import the sign-out marks',
        find: "import { logger } from '../observability/logger.js';\n",
        replace:
          "import { logger } from '../observability/logger.js';\n" +
          "import * as SessionActivity from '../security/sessionActivity.js';\n",
      },
      {
        name: 'a device signed out in Settings cannot open a socket with its last token',
        find: '  let identity;\n  try {\n    identity = await loadIdentity(claims.userId);\n',
        replace:
          '  // Settings → Sign-in & devices (Phase B) marks a signed-out session at once;\n' +
          '  // its access token would otherwise open sockets until it expires.\n' +
          '  if (await SessionActivity.isRevoked(claims.sessionId)) {\n' +
          "    log.debug({ socketId: socket.id, traceId }, 'handshake for a signed-out device');\n" +
          "    return next(reject('token_revoked', 'This device was signed out.'));\n" +
          '  }\n' +
          '\n' +
          '  let identity;\n  try {\n    identity = await loadIdentity(claims.userId);\n',
      },
    ],
  },
  {
    file: 'apps/web/src/components/Settings/settingsIndex.js',
    marker: "anchor: 'two-step'",
    edits: [
      {
        name: 'password, two-step sign-in, passkeys and your data can be searched',
        find: "  { tab: 'activity', anchor: 'changes', label: 'Recent changes', keywords: 'history changes activity log audit' },\n];\n",
        replace:
          "  { tab: 'activity', anchor: 'changes', label: 'Recent changes', keywords: 'history changes activity log audit' },\n" +
          INDEX_C +
          '];\n',
      },
    ],
  },
  {
    file: 'apps/web/src/components/Settings/settings.css',
    marker: 'Phase C: password',
    edits: [
      {
        name: 'styles for the new sections',
        find: '.btn--danger { background: #b91c1c; color: #fff; border-color: #b91c1c; }\n',
        replace: '.btn--danger { background: #b91c1c; color: #fff; border-color: #b91c1c; }' + CSS_C,
      },
    ],
  },
];

const count = (src, edit) => {
  if (edit.regex) {
    const global = new RegExp(edit.regex.source, edit.regex.flags.includes('g') ? edit.regex.flags : `${edit.regex.flags}g`);
    return [...src.matchAll(global)].length;
  }
  return src.split(edit.find).length - 1;
};

const apply = (src, edit) =>
  edit.regex ? src.replace(edit.regex, edit.replace) : src.replace(edit.find, () => edit.replace);

const results = [];
for (const entry of plan) {
  if (!existsSync(entry.file)) {
    console.error(`${entry.file}: not found. Nothing was changed in any patched file.`);
    process.exit(1);
  }
  let src = readFileSync(entry.file, 'utf8');
  if (src.includes(entry.marker)) {
    console.log(`${entry.file}: already patched, nothing to do`);
    continue;
  }
  for (const edit of entry.edits) {
    const n = count(src, edit);
    if (n !== 1) {
      console.error(`${entry.file}: "${edit.name}": expected the anchor exactly once, found ${n}. Nothing was changed in any patched file.`);
      process.exit(1);
    }
  }
  for (const edit of entry.edits) src = apply(src, edit);
  results.push({ ...entry, src });
}

for (const entry of results) {
  writeFileSync(entry.file, entry.src);
  console.log('patched', entry.file);
  for (const edit of entry.edits) console.log('  -', edit.name);
}
__PC_EOF__
node .phaseC-patch.mjs
rm -f .phaseC-patch.mjs

# ---------------------------------------------------------------------------
# Libraries: @simplewebauthn/server (passkeys) and qrcode (the QR code for
# authenticator apps). Without them the rest works; passkeys say "not
# available" and the app setup shows the key without a picture.
# ---------------------------------------------------------------------------
echo "--- libraries"
SERVER_PKG=$(node -p "require('./server/package.json').name" 2>/dev/null || echo "")
if (cd server && node --input-type=module -e "await import('@simplewebauthn/server'); await import('qrcode')") >/dev/null 2>&1; then
  echo "@simplewebauthn/server and qrcode are already installed"
elif [ -n "$SERVER_PKG" ] && npm install @simplewebauthn/server@^13 qrcode@^1.5 -w "$SERVER_PKG" --no-audit --no-fund; then
  echo "@simplewebauthn/server and qrcode installed in $SERVER_PKG"
else
  echo "WARN the libraries could not be installed. Everything else works; passkeys stay off until"
  echo "     you run: npm install @simplewebauthn/server@^13 qrcode@^1.5 -w ${SERVER_PKG:-@classroom/server}"
fi

# ---------------------------------------------------------------------------
# Encryption key for authenticator secrets. Generated once and then kept:
# a new key makes every authenticator app that is already set up unreadable.
# ---------------------------------------------------------------------------
echo "--- encryption key"
ENV_FILES=()
for e in .env server/.env; do [ -f "$e" ] && ENV_FILES+=("$e"); done
if [ ${#ENV_FILES[@]} -eq 0 ]; then
  echo "WARN no .env found. Authenticator secrets are encrypted with a key derived from COOKIE_SECRET."
else
  KEY=""
  for e in "${ENV_FILES[@]}"; do
    if grep -q '^TWO_FACTOR_ENCRYPTION_KEY=.\+' "$e"; then
      KEY=$(grep '^TWO_FACTOR_ENCRYPTION_KEY=' "$e" | tail -1 | cut -d= -f2-)
      echo "keeping the key in $e"
      break
    fi
  done
  if [ -z "$KEY" ]; then
    KEY=$(node -e "console.log(require('node:crypto').randomBytes(32).toString('base64'))")
    echo "generated a new key"
  fi
  for e in "${ENV_FILES[@]}"; do
    if ! grep -q '^TWO_FACTOR_ENCRYPTION_KEY=.\+' "$e"; then
      sed -i '/^TWO_FACTOR_ENCRYPTION_KEY=/d' "$e"
      [ -n "$(tail -c1 "$e")" ] && echo >> "$e"
      {
        echo "# Two-step sign-in (Settings, Phase C). Keep it: a new key makes every authenticator app unreadable."
        echo "TWO_FACTOR_ENCRYPTION_KEY=$KEY"
      } >> "$e"
      echo "added the key to $e"
    fi
  done
fi

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
echo "--- checks"
ESBUILD=""
[ -x node_modules/.bin/esbuild ] && ESBUILD=node_modules/.bin/esbuild
FAILED=0
for f in "${TOUCHED[@]}"; do
  [ -f "$f" ] || continue
  case "$f" in
    *.js|*.mjs) if node --check "$f"; then echo "ok  $f"; else FAILED=1; fi ;;
    *.ts) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.ts=ts --log-level=error >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
    *.tsx) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.tsx=tsx --jsx=automatic --log-level=error >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
    *.jsx) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.jsx=jsx --jsx=automatic --log-level=error >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
    *.json) if node -e "JSON.parse(require('fs').readFileSync('$f','utf8'))"; then echo "ok  $f"; else FAILED=1; fi ;;
    *) echo "ok  $f" ;;
  esac
done
if [ "$FAILED" -ne 0 ]; then
  echo
  echo "A file did not pass its check (see above). Undo with: bash phaseC-install.sh --restore" >&2
  exit 1
fi

echo "--- rules (node --test)"
if node --test server/test/settings/*.check.mjs apps/web/src/components/Settings/__checks__/*.check.mjs > .phaseC-test.log 2>&1; then
  # Node 22 prints "# pass N", Node 24 "ℹ pass N".
  PASSED=$(grep -E '^(# |ℹ )pass [0-9]+' .phaseC-test.log | tail -1 | awk '{print $NF}')
  echo "ok  ${PASSED:-all} rule tests passed"
  rm -f .phaseC-test.log
else
  cat .phaseC-test.log
  rm -f .phaseC-test.log
  echo "The rule checks failed (see above). Undo with: bash phaseC-install.sh --restore" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Database and restart
# ---------------------------------------------------------------------------
echo "--- database"
if SERVICE_ROLE=api npm run db:migrate; then
  # node --watch waits for a file change after a failed start; this is one.
  touch server/src/server.js
  [ -f server/src/worker.js ] && touch server/src/worker.js
  echo
  echo "Phase C installed and migration 023 applied. The API restarts on its own;"
  echo "reload the browser tabs with Ctrl+Shift+R. You will have to sign in again"
  echo "(the tokens live in memory, and the sign-in code changed)."
  if command -v pgrep >/dev/null 2>&1 && ! pgrep -f "src/worker.js" >/dev/null 2>&1; then
    echo
    echo "Note: the worker is not running. Security emails and the scheduled account"
    echo "deletion are handled by it. Start it in a second terminal:"
    echo "  npm run dev:worker -w ${SERVER_PKG:-@classroom/server}"
  fi
else
  echo
  echo "The files are installed, but the migration did not run. Start the containers"
  echo "(./dev-up.sh), then: SERVICE_ROLE=api npm run db:migrate && touch server/src/server.js"
  exit 1
fi