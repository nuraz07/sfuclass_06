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
