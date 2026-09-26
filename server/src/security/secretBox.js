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
