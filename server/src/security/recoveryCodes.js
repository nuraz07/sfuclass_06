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
