// server/src/rtc/IcePolicy.js
//
// Resolves the effective ICE policy for a tenant: defaults from config/ice.config.js, overridden per
// tenant by table tenant_rtc_policy (server/src/db/migrations/011_rtc_policy.sql):
//
//   tenant_id              uuid primary key
//   ice_transport_policy   text   'all' | 'relay'          (relay = neither side learns the other's IP)
//   credential_ttl_s       int    TURN credential lifetime, clamped to [minTtlSeconds, maxTtlSeconds]
//   turn_transports        text[] subset of {'udp','tcp','tls'}
//   allowed_media_regions  text[] data residency: regions media may be placed or relayed in (NULL = any)
//
// Security posture: a tenant that demands relay-only or region pinning must never silently fall back
// to looser defaults. If the database cannot be read and no cached row exists, resolution FAILS
// CLOSED (503) instead of returning defaults.
//
// Owner: F8 Real-Time Connectivity. Used by IceServerService.js.

const TRANSPORTS = Object.freeze(['udp', 'tcp', 'tls']);
const POLICIES = Object.freeze(['all', 'relay']);
const REGION_PATTERN = /^[a-z]{2}(-[a-z]+)+-\d{1,2}$/;

const SELECT_POLICY = `
  SELECT ice_transport_policy, credential_ttl_s, turn_transports, allowed_media_regions
    FROM tenant_rtc_policy
   WHERE tenant_id = $1`;

/**
 * @typedef {object} EffectiveIcePolicy
 * @property {'all'|'relay'} iceTransportPolicy
 * @property {number} credentialTtlSeconds
 * @property {Array<'udp'|'tcp'|'tls'>} transports   ordered by preference
 * @property {string[] | null} allowedRegions         null = unrestricted
 * @property {boolean} forcedRelay                    true when the client requested relay after failed ICE restarts
 */

/**
 * @typedef {object} IcePolicyDefaults
 * @property {'all'|'relay'} iceTransportPolicy
 * @property {number} credentialTtlSeconds    default 28800 (8 h)
 * @property {number} minTtlSeconds           default 3600
 * @property {number} maxTtlSeconds           default 86400
 * @property {Array<'udp'|'tcp'|'tls'>} transports
 */

export class IcePolicy {
  /**
   * @param {object} options
   * @param {{ query: (sql: string, params: unknown[]) => Promise<{ rows: any[] }> }} options.db  pg Pool (db/pool.js)
   * @param {IcePolicyDefaults} options.defaults  from config/ice.config.js
   * @param {number} [options.cacheTtlMs=60000]
   * @param {number} [options.maxEntries=10000]
   * @param {{ warn: Function }} [options.logger]
   * @param {() => number} [options.now]
   */
  constructor({ db, defaults, cacheTtlMs = 60_000, maxEntries = 10_000, logger = console, now = Date.now }) {
    if (!db) throw new TypeError('IcePolicy: db is required');
    this.#db = db;
    this.#defaults = validateDefaults(defaults);
    this.#cacheTtlMs = cacheTtlMs;
    this.#maxEntries = maxEntries;
    this.#logger = logger;
    this.#now = now;
  }

  #db;
  #defaults;
  #cacheTtlMs;
  #maxEntries;
  #logger;
  #now;
  /** @type {Map<string, { row: object | null, at: number }>} insertion-ordered = LRU */ #cache = new Map();

  /**
   * @param {string} tenantId
   * @param {{ forceRelay?: boolean }} [options]
   * @returns {Promise<EffectiveIcePolicy>}
   */
  async resolve(tenantId, { forceRelay = false } = {}) {
    if (typeof tenantId !== 'string' || tenantId.length === 0) {
      throw new TypeError('IcePolicy: tenantId is required');
    }
    const row = await this.#row(tenantId);
    return this.#merge(row, forceRelay);
  }

  /** Call after the tenant's policy row changes (admin API) so the next join sees it. */
  invalidate(tenantId) {
    this.#cache.delete(tenantId);
  }

  async #row(tenantId) {
    const hit = this.#cache.get(tenantId);
    if (hit && this.#now() - hit.at < this.#cacheTtlMs) {
      this.#cache.delete(tenantId); // refresh LRU position
      this.#cache.set(tenantId, hit);
      return hit.row;
    }
    try {
      const { rows } = await this.#db.query(SELECT_POLICY, [tenantId]);
      const row = rows[0] ?? null;
      this.#remember(tenantId, row);
      return row;
    } catch (err) {
      if (hit) {
        this.#logger.warn({ tenantId, err: { message: err.message } }, 'rtc policy read failed; using cached row');
        return hit.row;
      }
      const wrapped = new Error('ICE policy unavailable');
      wrapped.code = 'RTC_POLICY_UNAVAILABLE';
      wrapped.status = 503;
      wrapped.cause = err;
      throw wrapped;
    }
  }

  #remember(tenantId, row) {
    this.#cache.delete(tenantId);
    this.#cache.set(tenantId, { row, at: this.#now() });
    while (this.#cache.size > this.#maxEntries) {
      this.#cache.delete(this.#cache.keys().next().value);
    }
  }

  /** @returns {EffectiveIcePolicy} */
  #merge(row, forceRelay) {
    const d = this.#defaults;

    let iceTransportPolicy = POLICIES.includes(row?.ice_transport_policy) ? row.ice_transport_policy : d.iceTransportPolicy;

    let ttl = Number.isInteger(row?.credential_ttl_s) ? row.credential_ttl_s : d.credentialTtlSeconds;
    ttl = Math.min(Math.max(ttl, d.minTtlSeconds), d.maxTtlSeconds);

    let transports = Array.isArray(row?.turn_transports)
      ? TRANSPORTS.filter((t) => row.turn_transports.includes(t))
      : [...d.transports];
    if (transports.length === 0) transports = [...d.transports];

    const allowedRegions = Array.isArray(row?.allowed_media_regions) && row.allowed_media_regions.length > 0
      ? row.allowed_media_regions.filter((r) => REGION_PATTERN.test(r))
      : null;

    if (forceRelay) {
      // Recovery path after two failed ICE restarts (core-client IceRecovery): relay only,
      // TLS 443 first because the failure pattern points at a restrictive network.
      iceTransportPolicy = 'relay';
      if (!transports.includes('tls')) transports = [...transports, 'tls'];
      transports = ['tls', ...transports.filter((t) => t !== 'tls')];
    }

    return Object.freeze({
      iceTransportPolicy,
      credentialTtlSeconds: ttl,
      transports: Object.freeze(transports),
      allowedRegions: allowedRegions ? Object.freeze(allowedRegions) : null,
      forcedRelay: forceRelay,
    });
  }
}

function validateDefaults(defaults) {
  const d = {
    iceTransportPolicy: 'all',
    credentialTtlSeconds: 28_800,
    minTtlSeconds: 3_600,
    maxTtlSeconds: 86_400,
    transports: ['udp', 'tcp', 'tls'],
    ...defaults,
  };
  if (!POLICIES.includes(d.iceTransportPolicy)) throw new RangeError('IcePolicy: invalid default iceTransportPolicy');
  if (!(d.minTtlSeconds > 0 && d.minTtlSeconds <= d.credentialTtlSeconds && d.credentialTtlSeconds <= d.maxTtlSeconds)) {
    throw new RangeError('IcePolicy: default TTLs must satisfy min <= default <= max');
  }
  if (!Array.isArray(d.transports) || d.transports.length === 0 || d.transports.some((t) => !TRANSPORTS.includes(t))) {
    throw new RangeError('IcePolicy: default transports must be a non-empty subset of udp, tcp, tls');
  }
  return Object.freeze({ ...d, transports: Object.freeze([...d.transports]) });
}