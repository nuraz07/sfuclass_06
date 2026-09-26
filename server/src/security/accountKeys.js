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
