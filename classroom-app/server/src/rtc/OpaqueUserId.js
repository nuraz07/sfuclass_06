// server/src/rtc/OpaqueUserId.js
//
// Pseudonymous, stable identifier that goes into the TURN username ("<expiry>:<opaqueId>").
// coturn logs usernames, so nothing that identifies a person may appear there: no e-mail,
// no name, no raw user id. The id is an HMAC over (tenantId, userId, deviceSessionId) keyed with
// a server-side pepper (Secrets Manager: ICE_OPAQUE_ID_PEPPER), so it cannot be reversed or
// recomputed without the pepper, yet support can correlate a TURN log line with a session by
// deriving the id for a known user through ops/scripts/mint-ice-credentials.js.
//
// Properties:
//   - deterministic per (tenant, user, device session): one device = one TURN identity, which
//     makes coturn's per-user quota (user-quota) meaningful per device session;
//   - unambiguous encoding: components are length-prefixed, so ("a|b","c") and ("a","b|c") differ;
//   - 22 base64url characters = 132 bits, never contains ':' (the TURN REST separator).
//
// Owner: F8 Real-Time Connectivity. Used by IceServerService.js.

import { createHmac } from 'node:crypto';

const OPAQUE_ID_LENGTH = 22;
const MIN_PEPPER_BYTES = 32;
const MAX_COMPONENT_LENGTH = 256;

/**
 * @typedef {object} OpaqueUserIdOptions
 * @property {() => (string | Buffer)} getPepper  Returns the current pepper (loaded by config/secrets.js).
 */

export class OpaqueUserId {
  /** @param {OpaqueUserIdOptions} options */
  constructor({ getPepper }) {
    if (typeof getPepper !== 'function') {
      throw new TypeError('OpaqueUserId: getPepper must be a function');
    }
    this.#getPepper = getPepper;
  }

  #getPepper;

  /**
   * @param {{ tenantId: string, userId: string, deviceSessionId: string }} subject
   * @returns {string} 22-character base64url pseudonym
   */
  derive({ tenantId, userId, deviceSessionId }) {
    const pepper = this.#pepper();
    const hmac = createHmac('sha256', pepper);
    for (const [name, value] of [
      ['tenantId', tenantId],
      ['userId', userId],
      ['deviceSessionId', deviceSessionId],
    ]) {
      if (typeof value !== 'string' || value.length === 0 || value.length > MAX_COMPONENT_LENGTH) {
        throw new TypeError(`OpaqueUserId: ${name} must be a non-empty string (max ${MAX_COMPONENT_LENGTH})`);
      }
      const bytes = Buffer.from(value, 'utf8');
      const length = Buffer.alloc(4);
      length.writeUInt32BE(bytes.length);
      hmac.update(length);
      hmac.update(bytes);
    }
    return hmac.digest('base64url').slice(0, OPAQUE_ID_LENGTH);
  }

  #pepper() {
    const raw = this.#getPepper();
    const pepper = Buffer.isBuffer(raw) ? raw : Buffer.from(String(raw ?? ''), 'utf8');
    if (pepper.length < MIN_PEPPER_BYTES) {
      const err = new Error('ICE opaque-id pepper is missing or shorter than 32 bytes');
      err.code = 'RTC_PEPPER_UNAVAILABLE';
      err.status = 503;
      throw err;
    }
    return pepper;
  }
}