// server/src/rtc/TurnPoolSelector.js
//
// Chooses the TURN nodes whose addresses go into a client's ICE configuration.
//
//   primary  least-loaded healthy node in the room's media region, so the relay leg to the SFU stays
//            inside one region. If that region has no capacity: the configured fallback regions.
//   backup   a node in the client's nearest region when it differs from the relay region (helps
//            clients far away on lossy access networks), otherwise a node in another availability zone
//            of the same region, otherwise any other node in that region, otherwise none.
//
// Load = max(allocations / maxAllocations, relayMbps / capacityMbps) from the heartbeat. Registry data is
// up to ~5 s old, so always picking the single least-loaded node would send every join in that window to
// the same machine. Instead the selector picks at random among nodes within `spread` of the best load
// ("best-bucket random"), which spreads bursts while still favouring headroom. Nodes at or above
// `saturation` are only used when nothing else is left (the caller is told via `degraded`).
//
// Data residency: regions outside the tenant's allowedRegions are never used, not even as fallback.
//
// Owner: F8 Real-Time Connectivity. Used by IceServerService.js.

/**
 * @typedef {import('./TurnPoolRegistry.js').TurnNode} TurnNode
 * @typedef {{ primary: TurnNode, backup: TurnNode | null, degraded: boolean }} TurnSelection
 */

export class TurnPoolSelector {
  /**
   * @param {object} options
   * @param {import('./TurnPoolRegistry.js').TurnPoolRegistry} options.registry
   * @param {Record<string, string[]>} [options.fallbacks]  e.g. { 'eu-central-1': ['us-east-1'] } (config/ice.config.js)
   * @param {number} [options.saturation=0.9]
   * @param {number} [options.spread=0.1]
   * @param {() => number} [options.random]
   */
  constructor({ registry, fallbacks = {}, saturation = 0.9, spread = 0.1, random = Math.random }) {
    if (!registry) throw new TypeError('TurnPoolSelector: registry is required');
    this.#registry = registry;
    this.#fallbacks = fallbacks;
    this.#saturation = saturation;
    this.#spread = spread;
    this.#random = random;
  }

  #registry;
  #fallbacks;
  #saturation;
  #spread;
  #random;

  /**
   * @param {object} request
   * @param {string} request.relayRegion             room's media region (or, for probes, the client's region)
   * @param {string | null} [request.clientRegion]   from RegionHint.js
   * @param {readonly string[] | null} [request.allowedRegions]
   * @returns {Promise<TurnSelection | null>} null when no allowed region has a healthy node
   */
  async select({ relayRegion, clientRegion = null, allowedRegions = null }) {
    const allowed = (region) => allowedRegions === null || allowedRegions.includes(region);
    const chain = [relayRegion, ...(this.#fallbacks[relayRegion] ?? [])].filter(
      (region, i, all) => region && allowed(region) && all.indexOf(region) === i,
    );

    let primary = null;
    let primaryNodes = [];
    let degraded = false;
    for (const region of chain) {
      const nodes = await this.#nodesOrEmpty(region);
      if (nodes.length === 0) continue;
      const pick = this.#pick(nodes);
      primary = pick.node;
      degraded = pick.saturated || region !== relayRegion;
      primaryNodes = nodes;
      break;
    }
    if (!primary) return null;

    let backup = null;
    if (clientRegion && clientRegion !== primary.region && allowed(clientRegion)) {
      const nodes = await this.#nodesOrEmpty(clientRegion);
      if (nodes.length > 0) backup = this.#pick(nodes).node;
    }
    if (!backup) {
      const others = primaryNodes.filter((n) => n.node !== primary.node);
      const otherAz = others.filter((n) => n.az !== primary.az);
      const pool = otherAz.length > 0 ? otherAz : others;
      if (pool.length > 0) backup = this.#pick(pool).node;
    }

    return { primary, backup, degraded };
  }

  async #nodesOrEmpty(region) {
    try {
      return await this.#registry.getRegionNodes(region);
    } catch {
      return []; // one unavailable region must not fail selection when others can serve
    }
  }

  /** @param {TurnNode[]} nodes non-empty */
  #pick(nodes) {
    const healthy = nodes.filter((n) => n.load < this.#saturation);
    const pool = healthy.length > 0 ? healthy : nodes;
    const best = Math.min(...pool.map((n) => n.load));
    const bucket = pool.filter((n) => n.load <= best + this.#spread);
    const node = bucket[Math.floor(this.#random() * bucket.length) % bucket.length];
    return { node, saturated: healthy.length === 0 };
  }
}