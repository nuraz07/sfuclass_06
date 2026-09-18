// server/src/rtc/TurnPoolRegistry.js
//
// Read side of the TURN node registry. Every coturn node's agent (turn/agent/src/heartbeat.js)
// writes a heartbeat every 5 s into the STATE Redis cluster (noeviction, db/redis.js):
//
//   media:turn:{<region>}:node:<nodeName>   JSON record (below), PX 15000
//   media:turn:{<region>}:index             ZSET member <nodeName>, score = heartbeatAt (ms)
//   media:drain:<nodeName>                  optional drain flag (node-lifecycle Lambda, runbooks)
//
// The braces are a Redis Cluster hash tag: all keys of one region live in one slot, so MGET works in
// cluster mode. A node disappears from selection when it stops heartbeating (crash, drain via
// POST /drain, scale-in), when it reports draining=true, or when a drain flag is set.
//
// Reads are cached per region for snapshotTtlMs (1 s) and de-duplicated, so a burst of room joins
// costs one Redis round trip per region per second. If Redis is unavailable, the last snapshot is
// served for up to staleOnErrorMs (60 s) — relays keep being handed out through a short outage.
//
// Owner: F8 Real-Time Connectivity. Used by TurnPoolSelector.js and RegionHint.js.

import { isIPv4, isIPv6 } from 'node:net';
import { z } from 'zod';

const REGION_PATTERN = /^[a-z]{2}(-[a-z]+)+-\d{1,2}$/;
const HOSTNAME_PATTERN = /^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)(\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/;

export const turnRegistryKeys = Object.freeze({
  node: (region, nodeName) => `media:turn:{${region}}:node:${nodeName}`,
  index: (region) => `media:turn:{${region}}:index`,
  drain: (nodeName) => `media:drain:${nodeName}`,
});

/** Heartbeat record contract — turn/agent/src/heartbeat.js must write exactly this shape. */
export const turnNodeRecordSchema = z.object({
  node: z.string().regex(/^[a-z0-9-]{3,63}$/),
  region: z.string().regex(REGION_PATTERN),
  az: z.string().min(1).max(32),
  hostname: z.string().regex(HOSTNAME_PATTERN), // lowercase FQDN, e.g. turn-euc1-07.rtc.example.com
  publicIpv4: z.string().refine((v) => isIPv4(v), 'publicIpv4 must be an IPv4 address'),
  publicIpv6: z.string().refine((v) => isIPv6(v), 'publicIpv6 must be an IPv6 address').optional(),
  allocations: z.number().int().nonnegative(),
  maxAllocations: z.number().int().positive(),
  relayMbps: z.number().nonnegative(),
  capacityMbps: z.number().positive(),
  draining: z.boolean().default(false),
  version: z.string().max(64).optional(),
  heartbeatAt: z.number().int().positive(),
});

/** @typedef {z.infer<typeof turnNodeRecordSchema> & { load: number }} TurnNode */

export class TurnPoolRegistry {
  /**
   * @param {object} options
   * @param {import('ioredis').Redis | import('ioredis').Cluster} options.redis  STATE cluster client (db/redis.js)
   * @param {number} [options.staleAfterMs=15000]     heartbeat older than this = node gone
   * @param {number} [options.snapshotTtlMs=1000]
   * @param {number} [options.staleOnErrorMs=60000]
   * @param {number} [options.pruneEveryMs=30000]     how often dead index members are removed
   * @param {{ warn: Function }} [options.logger]
   * @param {() => number} [options.now]
   */
  constructor({ redis, staleAfterMs = 15_000, snapshotTtlMs = 1_000, staleOnErrorMs = 60_000, pruneEveryMs = 30_000, logger = console, now = Date.now }) {
    if (!redis) throw new TypeError('TurnPoolRegistry: redis is required');
    this.#redis = redis;
    this.#staleAfterMs = staleAfterMs;
    this.#snapshotTtlMs = snapshotTtlMs;
    this.#staleOnErrorMs = staleOnErrorMs;
    this.#pruneEveryMs = pruneEveryMs;
    this.#logger = logger;
    this.#now = now;
  }

  #redis;
  #staleAfterMs;
  #snapshotTtlMs;
  #staleOnErrorMs;
  #pruneEveryMs;
  #logger;
  #now;
  /** @type {Map<string, { nodes: TurnNode[], at: number }>} */ #snapshots = new Map();
  /** @type {Map<string, Promise<TurnNode[]>>} */ #inflight = new Map();
  /** @type {Map<string, number>} */ #lastPrune = new Map();

  /**
   * Healthy, non-draining nodes of a region, each with a load in [0, ∞) (1 = at capacity).
   * @param {string} region
   * @returns {Promise<TurnNode[]>}
   */
  async getRegionNodes(region) {
    if (!REGION_PATTERN.test(region ?? '')) return [];
    const cached = this.#snapshots.get(region);
    if (cached && this.#now() - cached.at < this.#snapshotTtlMs) return cached.nodes;

    let pending = this.#inflight.get(region);
    if (!pending) {
      pending = this.#load(region).finally(() => this.#inflight.delete(region));
      this.#inflight.set(region, pending);
    }
    try {
      const nodes = await pending;
      this.#snapshots.set(region, { nodes, at: this.#now() });
      return nodes;
    } catch (err) {
      if (cached && this.#now() - cached.at < this.#staleOnErrorMs) {
        this.#logger.warn({ region, err: { message: err.message } }, 'turn registry read failed; serving stale snapshot');
        return cached.nodes;
      }
      const wrapped = new Error(`TURN registry unavailable for ${region}`);
      wrapped.code = 'RTC_REGISTRY_UNAVAILABLE';
      wrapped.status = 503;
      wrapped.cause = err;
      throw wrapped;
    }
  }

  /**
   * Regions (out of the candidates) that currently have at least one healthy TURN node.
   * Registry failures for a region count as "not live" rather than failing the caller.
   * @param {string[]} candidates
   * @returns {Promise<string[]>}
   */
  async liveRegions(candidates) {
    const unique = [...new Set(candidates)].filter((r) => REGION_PATTERN.test(r));
    const results = await Promise.all(
      unique.map((region) => this.getRegionNodes(region).then((nodes) => nodes.length > 0, () => false)),
    );
    return unique.filter((_, i) => results[i]);
  }

  async #load(region) {
    const now = this.#now();
    const indexKey = turnRegistryKeys.index(region);
    const names = await this.#redis.zrangebyscore(indexKey, now - this.#staleAfterMs, '+inf');
    this.#maybePrune(region, indexKey, now);
    if (names.length === 0) return [];

    const [records, drainFlags] = await Promise.all([
      this.#redis.mget(...names.map((n) => turnRegistryKeys.node(region, n))),
      Promise.all(names.map((n) => this.#redis.exists(turnRegistryKeys.drain(n)))),
    ]);

    /** @type {TurnNode[]} */
    const nodes = [];
    records.forEach((raw, i) => {
      if (!raw || drainFlags[i]) return;
      let parsed;
      try {
        parsed = turnNodeRecordSchema.safeParse(JSON.parse(raw));
      } catch {
        parsed = { success: false };
      }
      if (!parsed.success) {
        this.#logger.warn({ region, node: names[i] }, 'ignoring malformed turn heartbeat record');
        return;
      }
      const rec = parsed.data;
      if (rec.draining || rec.region !== region || rec.node !== names[i]) return;
      if (now - rec.heartbeatAt > this.#staleAfterMs) return;
      const load = Math.max(rec.allocations / rec.maxAllocations, rec.relayMbps / rec.capacityMbps);
      nodes.push(Object.freeze({ ...rec, load }));
    });
    return nodes;
  }

  #maybePrune(region, indexKey, now) {
    if (now - (this.#lastPrune.get(region) ?? 0) < this.#pruneEveryMs) return;
    this.#lastPrune.set(region, now);
    this.#redis.zremrangebyscore(indexKey, '-inf', now - 4 * this.#staleAfterMs).catch(() => {});
  }
}