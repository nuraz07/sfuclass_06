// server/src/classroom/RoomPlacementService.js
//
// Decides which SFU node carries a room. Runs in the realtime service; reads the SFU node registry that
// every node publishes through sfu-node/NodeRegistrar.js (state Redis, TTL 15 s).
//
// New room
//   1. Allowed regions: tenant data-residency policy (tenant_rtc_policy.allowed_media_regions via IcePolicy).
//   2. Region order: the host's region hint (RegionHint, lowest measured RTT among live, allowed regions),
//      then the configured media regions in order.
//   3. Node: among healthy, non-draining nodes without a drain flag and with loadScore below newRoomMaxLoad
//      (headroom for the room to grow and for breakouts), pick at random within `spread` of the lowest load —
//      heartbeats are up to 5 s old, so always taking the single least-loaded node would herd a burst of new
//      rooms onto one machine.
//   4. Claim atomically in RoomRegistry. If another realtime task placed the same room a moment earlier,
//      its placement wins and is returned: every participant ends up on the same node.
//
// Existing room
//   Returned as is while its node heartbeats (draining nodes keep their rooms). If the node is gone (crash,
//   AZ loss), the room is re-placed — same region first — with compare-and-set, and `moved: true` tells
//   signalling to make clients rejoin (their ICE restarts against the new node).
//
// Cascading
//   pickEdgeNode() returns another node in the room's region for RouterPipeManager when a room outgrows
//   one node (see sfuControlClient.pipeProducer).
//
// RoomRegistry contract (classroom/RoomRegistry.js):
//   get(roomId) → Promise<Placement | null>
//   claim(roomId, placement) → Promise<{ placement: Placement, won: boolean }>                  SET NX
//   compareAndSet(roomId, expectedNodeId, placement) → Promise<{ placement: Placement, won: boolean }>
//   Placement: { roomId, region, nodeId, controlAddress, placedAt }
//
// Owner: F1 Live Classrooms + F8 Real-Time Connectivity.

import { sfuNodeRecordSchema, sfuRegistryKeys } from '../sfu-node/NodeRegistrar.js';

const REGION = /^[a-z]{2}(-[a-z]+)+-\d{1,2}$/;

export class RoomPlacementService {
  /**
   * @param {object} options
   * @param {import('ioredis').Redis | import('ioredis').Cluster} options.redis   STATE cluster
   * @param {object} options.roomRegistry                                      see contract above
   * @param {import('../rtc/RegionHint.js').RegionHint} options.regionHint
   * @param {string[]} options.regions                                         enabled media regions, in preference order
   * @param {import('../rtc/IcePolicy.js').IcePolicy} [options.policy]         tenant residency; without it callers pass allowedRegions
   * @param {number} [options.newRoomMaxLoad=0.75]
   * @param {number} [options.edgeMaxLoad=0.8]
   * @param {number} [options.spread=0.1]
   * @param {number} [options.staleAfterMs=15000]
   * @param {number} [options.snapshotTtlMs=1000]
   * @param {{ info: Function, warn: Function }} [options.logger]
   * @param {{ increment: Function }} [options.metrics]
   * @param {() => number} [options.now]
   * @param {() => number} [options.random]
   */
  constructor({
    redis, roomRegistry, regionHint, regions, policy = null,
    newRoomMaxLoad = 0.75, edgeMaxLoad = 0.8, spread = 0.1, staleAfterMs = 15_000, snapshotTtlMs = 1_000,
    logger = console, metrics, now = Date.now, random = Math.random,
  }) {
    if (!redis || !roomRegistry || !regionHint) throw new TypeError('RoomPlacementService: redis, roomRegistry and regionHint are required');
    if (!Array.isArray(regions) || regions.length === 0 || regions.some((r) => !REGION.test(r))) {
      throw new TypeError('RoomPlacementService: regions must be a non-empty array of region codes');
    }
    this.#redis = redis;
    this.#rooms = roomRegistry;
    this.#regionHint = regionHint;
    this.#regions = Object.freeze([...new Set(regions)]);
    this.#policy = policy;
    this.#newRoomMaxLoad = newRoomMaxLoad;
    this.#edgeMaxLoad = edgeMaxLoad;
    this.#spread = spread;
    this.#staleAfterMs = staleAfterMs;
    this.#snapshotTtlMs = snapshotTtlMs;
    this.#logger = logger;
    this.#metrics = metrics ?? { increment: () => {} };
    this.#now = now;
    this.#random = random;
  }

  #redis;
  #rooms;
  #regionHint;
  #regions;
  #policy;
  #newRoomMaxLoad;
  #edgeMaxLoad;
  #spread;
  #staleAfterMs;
  #snapshotTtlMs;
  #logger;
  #metrics;
  #now;
  #random;
  /** @type {Map<string, { nodes: object[], at: number }>} */ #snapshots = new Map();

  /**
   * Returns where a room lives, placing or re-placing it when necessary.
   * @param {{ roomId: string, tenantId: string, regionHint?: unknown, allowedRegions?: string[] | null }} request
   * @returns {Promise<{ roomId: string, region: string, nodeId: string, controlAddress: string,
   *                     created: boolean, moved: boolean }>}
   */
  async resolve({ roomId, tenantId, regionHint, allowedRegions }) {
    if (typeof roomId !== 'string' || roomId.length === 0) throw placementError('roomId is required', 'BAD_REQUEST', 400);

    const existing = await this.#rooms.get(roomId);
    if (existing) {
      const node = await this.#liveNode(existing.region, existing.nodeId);
      if (node) return { ...existing, controlAddress: node.controlAddress, created: false, moved: false };
      return this.#replace(existing, await this.#allowedFor(tenantId, allowedRegions));
    }

    const allowed = await this.#allowedFor(tenantId, allowedRegions);
    const hinted = await this.#regionHint.resolve({ hint: regionHint, allowedRegions: allowed });
    const order = [hinted, ...this.#regions].filter(
      (region, i, all) => region && all.indexOf(region) === i && (allowed === null || allowed.includes(region)),
    );

    for (const region of order) {
      const node = await this.#pickNode(region, { maxLoad: this.#newRoomMaxLoad });
      if (!node) continue;
      const placement = { roomId, region, nodeId: node.nodeId, controlAddress: node.controlAddress, placedAt: this.#now() };
      const { placement: stored, won } = await this.#rooms.claim(roomId, placement);
      this.#metrics.increment('placement.room_placed', { region: stored.region, won: String(won), hinted: String(region === hinted) });
      return { ...stored, created: won, moved: false };
    }

    this.#metrics.increment('placement.no_capacity', { tenantResidency: String(allowed !== null) });
    throw placementError('No SFU capacity in any allowed media region', 'NO_SFU_CAPACITY', 503);
  }

  /**
   * Another node in the room's region for cascading, or null.
   * @param {{ region: string, excludeNodeIds?: string[] }} request
   */
  async pickEdgeNode({ region, excludeNodeIds = [] }) {
    const node = await this.#pickNode(region, { maxLoad: this.#edgeMaxLoad, exclude: new Set(excludeNodeIds) });
    return node ? { nodeId: node.nodeId, address: node.controlAddress, region } : null;
  }

  /** Healthy, non-draining nodes of a region (ops endpoints, dashboards). */
  async nodes(region) {
    return this.#regionNodes(region);
  }

  // ------------------------------------------------------------------ internals

  async #replace(previous, allowed) {
    const order = [previous.region, ...this.#regions].filter(
      (region, i, all) => all.indexOf(region) === i && (allowed === null || allowed.includes(region)),
    );
    for (const region of order) {
      const node = await this.#pickNode(region, { maxLoad: this.#edgeMaxLoad, exclude: new Set([previous.nodeId]) });
      if (!node) continue;
      const next = { roomId: previous.roomId, region, nodeId: node.nodeId, controlAddress: node.controlAddress, placedAt: this.#now() };
      const { placement, won } = await this.#rooms.compareAndSet(previous.roomId, previous.nodeId, next);
      if (won) {
        this.#metrics.increment('placement.room_moved', { from: previous.region, to: region });
        this.#logger.warn({ roomId: previous.roomId, from: previous.nodeId, to: node.nodeId }, 'room moved: owning sfu node is gone');
      }
      return { ...placement, created: won, moved: true };
    }
    throw placementError('Owning SFU node is gone and no replacement has capacity', 'NO_SFU_CAPACITY', 503);
  }

  async #allowedFor(tenantId, explicit) {
    if (explicit !== undefined) return explicit;
    if (!this.#policy) return null;
    const policy = await this.#policy.resolve(tenantId); // fails closed (503) if residency cannot be read
    return policy.allowedRegions;
  }

  async #liveNode(region, nodeId) {
    return (await this.#regionNodes(region, { includeDraining: true })).find((n) => n.nodeId === nodeId) ?? null;
  }

  async #pickNode(region, { maxLoad, exclude = new Set() }) {
    const candidates = (await this.#regionNodes(region)).filter((n) => !exclude.has(n.nodeId) && n.loadScore < maxLoad);
    if (candidates.length === 0) return null;
    const best = Math.min(...candidates.map((n) => n.loadScore));
    const bucket = candidates.filter((n) => n.loadScore <= best + this.#spread);
    return bucket[Math.floor(this.#random() * bucket.length) % bucket.length];
  }

  async #regionNodes(region, { includeDraining = false } = {}) {
    if (!REGION.test(region ?? '')) return [];
    const cached = this.#snapshots.get(region);
    let all;
    if (cached && this.#now() - cached.at < this.#snapshotTtlMs) {
      all = cached.nodes;
    } else {
      try {
        all = await this.#load(region);
        this.#snapshots.set(region, { nodes: all, at: this.#now() });
      } catch (err) {
        this.#logger.warn({ region, err: { message: err.message } }, 'sfu registry read failed');
        if (!cached) throw placementError('SFU registry unavailable', 'REGISTRY_UNAVAILABLE', 503);
        all = cached.nodes;
      }
    }
    return includeDraining ? all : all.filter((n) => !n.draining && !n.drainFlag);
  }

  async #load(region) {
    const now = this.#now();
    const ids = await this.#redis.zrangebyscore(sfuRegistryKeys.index(region), now - this.#staleAfterMs, '+inf');
    if (ids.length === 0) return [];
    const [raw, flags] = await Promise.all([
      this.#redis.mget(...ids.map((id) => sfuRegistryKeys.node(region, id))),
      Promise.all(ids.map((id) => this.#redis.exists(sfuRegistryKeys.drain(id)))),
    ]);
    const nodes = [];
    raw.forEach((value, i) => {
      if (!value) return;
      let parsed;
      try {
        parsed = sfuNodeRecordSchema.safeParse(JSON.parse(value));
      } catch {
        parsed = { success: false };
      }
      if (!parsed.success || parsed.data.region !== region || parsed.data.nodeId !== ids[i]) return;
      if (now - parsed.data.heartbeatAt > this.#staleAfterMs) return;
      nodes.push(Object.freeze({ ...parsed.data, drainFlag: Boolean(flags[i]) }));
    });
    return nodes;
  }
}

function placementError(message, code, status) {
  const err = new Error(message);
  err.code = code;
  err.status = status;
  return err;
}