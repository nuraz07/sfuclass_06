// server/src/rtc/IceServerService.js
//
// Builds the ICE configuration a client needs to reach the media plane. Architecture doc, section 4.5.
// The SFU is ICE-lite and never talks to TURN: STUN/TURN addresses and temporary credentials reach the
// client only through this service, via
//   - the room.join acknowledgement (signaling/socketHandlers.js, realtime service), and
//   - POST /rtc/ice-servers (routes/rtc.routes.js) for refreshes and the pre-join network test.
//
// Response (exactly what mediasoup-client transports and RTCPeerConnection accept):
//   {
//     iceServers: [
//       { urls: ['stun:<primary>:3478'] },                                   // only when policy = all and udp allowed
//       { urls: ['turn:<primary>:3478?transport=udp',
//                'turn:<primary>:3478?transport=tcp',
//                'turns:<primary>:443?transport=tcp'], username, credential },
//       { urls: ['turns:<backup>:443?transport=tcp'], username, credential }  // backup: one URL
//     ],
//     iceTransportPolicy: 'all' | 'relay',
//     ttlSeconds, expiresAt, refreshAfter,
//     relay: { region, degraded }
//   }
// At most maxUrls (5) URLs: more only slows candidate gathering in browsers.
//
// Authorisation is the caller's job and is a precondition here:
//   purpose 'room'  → caller has verified the user is ADMITTED to roomId (after the waiting room);
//   purpose 'probe' → authenticated user, short-lived credentials (5 min) for ConnectivityProbe.
// Rate limiting happens in middleware (config/rateLimit.config.js: ICE credential issuance budget).
//
// Owner: F8 Real-Time Connectivity.

const PURPOSES = Object.freeze(['room', 'probe']);

/**
 * @typedef {object} IceServiceConfig        from config/ice.config.js
 * @property {string} defaultRegion          region used for probes when the client sent no usable hint
 * @property {{ stun: number, turn: number, tls: number }} [ports]  default 3478 / 3478 / 443
 * @property {number} [maxUrls=5]
 * @property {number} [probeTtlSeconds=300]
 */

/**
 * @typedef {object} IceConfigRequest
 * @property {'room'|'probe'} [purpose='room']
 * @property {string} tenantId
 * @property {string} userId
 * @property {string} deviceSessionId
 * @property {string} [roomId]          required for purpose 'room'
 * @property {string} [roomRegion]      required for purpose 'room' (RoomRegistry / RoomPlacementService)
 * @property {unknown} [regionHint]     raw client input, see RegionHint.js
 * @property {boolean} [forceRelay]     set by IceRecovery after two failed ICE restarts
 * @property {string} [requestId]       for logs and audit correlation
 */

export class IceServerService {
  /**
   * @param {object} deps
   * @param {IceServiceConfig} deps.config
   * @param {import('./IcePolicy.js').IcePolicy} deps.policy
   * @param {import('./RegionHint.js').RegionHint} deps.regionHint
   * @param {import('./TurnPoolSelector.js').TurnPoolSelector} deps.selector
   * @param {import('./TurnCredentialIssuer.js').TurnCredentialIssuer} deps.issuer
   * @param {import('./OpaqueUserId.js').OpaqueUserId} deps.opaqueUserId
   * @param {{ record: (entry: object) => Promise<void> }} [deps.audit]     security/auditLog.js
   * @param {{ increment: (name: string, tags?: object) => void }} [deps.metrics]  observability/metrics.js
   * @param {{ info: Function, warn: Function, error: Function }} [deps.logger]  observability/logger.js
   */
  constructor({ config, policy, regionHint, selector, issuer, opaqueUserId, audit, metrics, logger = console }) {
    for (const [name, dep] of Object.entries({ config, policy, regionHint, selector, issuer, opaqueUserId })) {
      if (!dep) throw new TypeError(`IceServerService: ${name} is required`);
    }
    if (!config.defaultRegion) throw new TypeError('IceServerService: config.defaultRegion is required');
    this.#config = Object.freeze({
      ports: { stun: 3478, turn: 3478, tls: 443, ...config.ports },
      maxUrls: config.maxUrls ?? 5,
      probeTtlSeconds: config.probeTtlSeconds ?? 300,
      defaultRegion: config.defaultRegion,
    });
    this.#policy = policy;
    this.#regionHint = regionHint;
    this.#selector = selector;
    this.#issuer = issuer;
    this.#opaqueUserId = opaqueUserId;
    this.#audit = audit ?? { record: async () => {} };
    this.#metrics = metrics ?? { increment: () => {} };
    this.#logger = logger;
  }

  #config;
  #policy;
  #regionHint;
  #selector;
  #issuer;
  #opaqueUserId;
  #audit;
  #metrics;
  #logger;

  /** @param {IceConfigRequest} request */
  async getIceConfig(request) {
    const {
      purpose = 'room', tenantId, userId, deviceSessionId,
      roomId, roomRegion, regionHint, forceRelay = false, requestId,
    } = request ?? {};

    if (!PURPOSES.includes(purpose)) throw badRequest(`unknown purpose '${purpose}'`);
    if (purpose === 'room' && (!roomId || !roomRegion)) throw badRequest('roomId and roomRegion are required');

    const policy = await this.#policy.resolve(tenantId, { forceRelay });
    const clientRegion = await this.#regionHint.resolve({ hint: regionHint, allowedRegions: policy.allowedRegions });

    const relayRegion = purpose === 'room'
      ? roomRegion
      : clientRegion ?? this.#firstAllowed(policy.allowedRegions);

    const selection = await this.#selector.select({
      relayRegion,
      clientRegion,
      allowedRegions: policy.allowedRegions,
    });

    const tags = { purpose, region: relayRegion, policy: policy.iceTransportPolicy };

    if (!selection) {
      this.#metrics.increment('rtc.ice_config.no_turn_capacity', tags);
      if (policy.iceTransportPolicy === 'relay') {
        // Relay-only without a relay cannot connect at all: tell the caller instead of handing out a dead config.
        throw unavailable('No TURN capacity in any allowed region', 'RTC_NO_TURN_CAPACITY');
      }
      this.#logger.warn({ requestId, tenantId, relayRegion }, 'no TURN capacity; issuing direct-only ICE configuration');
      return Object.freeze({
        iceServers: [],
        iceTransportPolicy: 'all',
        ttlSeconds: null,
        expiresAt: null,
        refreshAfter: null,
        relay: { region: null, degraded: true },
      });
    }

    const opaqueId = this.#opaqueUserId.derive({ tenantId, userId, deviceSessionId });
    const ttlSeconds = purpose === 'probe'
      ? Math.min(this.#config.probeTtlSeconds, policy.credentialTtlSeconds)
      : policy.credentialTtlSeconds;
    const credential = this.#issuer.issue({ opaqueId, ttlSeconds });

    const iceServers = this.#buildIceServers(selection, policy, credential);

    try {
      await this.#audit.record({
        action: 'rtc.turn_credential.issued',
        tenantId,
        actorUserId: userId,
        target: purpose === 'room' ? { type: 'room', id: roomId } : { type: 'probe' },
        requestId,
        metadata: {
          purpose,
          opaqueId,
          expiresAt: credential.expiresAt,
          secretVersion: credential.secretVersion,
          iceTransportPolicy: policy.iceTransportPolicy,
          forcedRelay: policy.forcedRelay,
          nodes: [selection.primary.node, selection.backup?.node].filter(Boolean),
        },
      });
    } catch (err) {
      // The credential is already bounded by its TTL; blocking a live lesson on an audit-store hiccup is
      // worse than a missing line. The failure itself is logged and alarmed on.
      this.#metrics.increment('rtc.ice_config.audit_failed', tags);
      this.#logger.error({ requestId, err: { message: err.message } }, 'audit record for TURN credential failed');
    }

    this.#metrics.increment('rtc.ice_config.issued', { ...tags, degraded: String(selection.degraded) });

    return Object.freeze({
      iceServers,
      iceTransportPolicy: policy.iceTransportPolicy,
      ttlSeconds: credential.ttlSeconds,
      expiresAt: credential.expiresAt,
      refreshAfter: credential.refreshAfter,
      relay: { region: selection.primary.region, degraded: selection.degraded },
    });
  }

  #firstAllowed(allowedRegions) {
    if (allowedRegions === null || allowedRegions.includes(this.#config.defaultRegion)) return this.#config.defaultRegion;
    return allowedRegions[0];
  }

  /**
   * @param {import('./TurnPoolSelector.js').TurnSelection} selection
   * @param {import('./IcePolicy.js').EffectiveIcePolicy} policy
   * @param {import('./TurnCredentialIssuer.js').TurnCredential} credential
   */
  #buildIceServers({ primary, backup }, policy, credential) {
    const { ports, maxUrls } = this.#config;
    const urlFor = (host, transport) => {
      switch (transport) {
        case 'udp': return `turn:${host}:${ports.turn}?transport=udp`;
        case 'tcp': return `turn:${host}:${ports.turn}?transport=tcp`;
        case 'tls': return `turns:${host}:${ports.tls}?transport=tcp`;
        default: throw new RangeError(`unknown transport ${transport}`);
      }
    };
    const auth = { username: credential.username, credential: credential.credential };

    const servers = [];
    let budget = maxUrls;

    // STUN is useless under relay-only and pointless without UDP.
    const wantStun = policy.iceTransportPolicy === 'all' && policy.transports.includes('udp');
    const primaryUrls = policy.transports.map((t) => urlFor(primary.hostname, t));
    const backupTransport = policy.transports.includes('tls') ? 'tls' : policy.transports[0];
    const backupUrls = backup ? [urlFor(backup.hostname, backupTransport)] : [];

    // Reserve room for the primary TURN URLs and one backup URL before adding STUN.
    const stunFits = wantStun && budget - primaryUrls.length - backupUrls.length >= 1;
    if (stunFits) {
      servers.push({ urls: [`stun:${primary.hostname}:${ports.stun}`] });
      budget -= 1;
    }

    const primaryTake = primaryUrls.slice(0, budget);
    servers.push({ urls: primaryTake, ...auth });
    budget -= primaryTake.length;

    if (backupUrls.length > 0 && budget > 0) {
      servers.push({ urls: backupUrls.slice(0, budget), ...auth });
    }
    return servers;
  }
}

function badRequest(message) {
  const err = new Error(message);
  err.code = 'RTC_BAD_REQUEST';
  err.status = 400;
  return err;
}

function unavailable(message, code) {
  const err = new Error(message);
  err.code = code;
  err.status = 503;
  return err;
}