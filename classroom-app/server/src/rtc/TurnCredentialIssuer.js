// server/src/rtc/TurnCredentialIssuer.js
//
// Mints temporary TURN credentials following the TURN REST API scheme that coturn verifies natively
// when started with `use-auth-secret` (turn/config/turnserver.conf.tmpl):
//
//   username   = "<expiresAtUnixSeconds>:<opaqueId>"
//   credential = base64( HMAC-SHA1( sharedSecret, username ) )
//
// coturn recomputes the HMAC with each configured static-auth-secret and rejects the request once
// the timestamp in the username lies in the past. HMAC-SHA1 is what coturn implements; as a MAC it
// is not affected by SHA-1 collision attacks.
//
// Nothing here is stored: credentials are derived, so the TURN hot path has no database and issuance
// scales with the API. They cannot be revoked one by one; the bounds are the TTL, coturn's per-user
// quota and emergency secret rotation (ops/runbooks/rotate-secrets.md).
//
// Test vectors shared with the TURN service: turn/test/rest-credential.vectors.json.
// Owner: F8 Real-Time Connectivity (+ security review). Used by IceServerService.js.

import { createHmac, timingSafeEqual } from 'node:crypto';

const SEPARATOR = ':'; // coturn rest-api-separator default
const OPAQUE_ID_PATTERN = /^[A-Za-z0-9_-]{8,64}$/;

/**
 * @typedef {object} TurnCredential
 * @property {string} username
 * @property {string} credential
 * @property {number} ttlSeconds
 * @property {string} issuedAt      ISO-8601
 * @property {string} expiresAt     ISO-8601
 * @property {string} refreshAfter  ISO-8601, when clients call updateIceServers()
 * @property {string} secretVersion Secrets Manager version id used for signing (for audit, not secret)
 */

export class TurnCredentialIssuer {
  /**
   * @param {object} options
   * @param {import('./TurnSecretRing.js').TurnSecretRing} options.secretRing
   * @param {number} [options.minTtlSeconds=60]      lower bound (probe credentials use 300 s)
   * @param {number} [options.maxTtlSeconds=86400]   upper bound (24 h, equals rotation phase 3 wait)
   * @param {number} [options.refreshRatio=0.8]      refreshAfter = issuedAt + ratio * ttl
   * @param {() => number} [options.now]
   */
  constructor({ secretRing, minTtlSeconds = 60, maxTtlSeconds = 86_400, refreshRatio = 0.8, now = Date.now }) {
    if (!secretRing) throw new TypeError('TurnCredentialIssuer: secretRing is required');
    if (!(refreshRatio > 0 && refreshRatio < 1)) throw new RangeError('TurnCredentialIssuer: refreshRatio must be in (0, 1)');
    this.#ring = secretRing;
    this.#minTtl = minTtlSeconds;
    this.#maxTtl = maxTtlSeconds;
    this.#refreshRatio = refreshRatio;
    this.#now = now;
  }

  #ring;
  #minTtl;
  #maxTtl;
  #refreshRatio;
  #now;

  /**
   * @param {{ opaqueId: string, ttlSeconds: number }} request
   * @returns {TurnCredential}
   */
  issue({ opaqueId, ttlSeconds }) {
    if (typeof opaqueId !== 'string' || !OPAQUE_ID_PATTERN.test(opaqueId)) {
      throw new TypeError('TurnCredentialIssuer: opaqueId must be 8-64 base64url characters');
    }
    if (!Number.isInteger(ttlSeconds) || ttlSeconds < this.#minTtl || ttlSeconds > this.#maxTtl) {
      throw new RangeError(`TurnCredentialIssuer: ttlSeconds must be an integer in [${this.#minTtl}, ${this.#maxTtl}]`);
    }

    const secret = this.#ring.signingSecret();
    const issuedAtMs = this.#now();
    const issuedAtSec = Math.floor(issuedAtMs / 1000);
    const expiresAtSec = issuedAtSec + ttlSeconds;
    const username = `${expiresAtSec}${SEPARATOR}${opaqueId}`;

    return {
      username,
      credential: sign(secret.value, username),
      ttlSeconds,
      issuedAt: new Date(issuedAtSec * 1000).toISOString(),
      expiresAt: new Date(expiresAtSec * 1000).toISOString(),
      refreshAfter: new Date((issuedAtSec + Math.floor(ttlSeconds * this.#refreshRatio)) * 1000).toISOString(),
      secretVersion: secret.versionId,
    };
  }

  /**
   * Verifies a credential the way coturn does (any accepted secret, not expired).
   * Used by tests, the connectivity canary tooling and ops/scripts/mint-ice-credentials.js — never on the hot path.
   * @returns {{ valid: boolean, reason?: 'malformed'|'expired'|'signature', secretVersion?: string }}
   */
  verify(username, credential) {
    if (typeof username !== 'string' || typeof credential !== 'string') return { valid: false, reason: 'malformed' };
    const sep = username.indexOf(SEPARATOR);
    const expiresAtSec = Number(username.slice(0, sep));
    if (sep <= 0 || !Number.isInteger(expiresAtSec)) return { valid: false, reason: 'malformed' };
    if (expiresAtSec * 1000 <= this.#now()) return { valid: false, reason: 'expired' };

    const given = Buffer.from(credential, 'utf8');
    for (const secret of this.#ring.acceptedSecrets()) {
      const expected = Buffer.from(sign(secret.value, username), 'utf8');
      if (expected.length === given.length && timingSafeEqual(expected, given)) {
        return { valid: true, secretVersion: secret.versionId };
      }
    }
    return { valid: false, reason: 'signature' };
  }
}

/** base64(HMAC-SHA1(secret, username)) — exported for the shared test vectors. */
export function sign(secret, username) {
  return createHmac('sha1', secret).update(username, 'utf8').digest('base64');
}