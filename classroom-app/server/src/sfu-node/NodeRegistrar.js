// server/src/sfu-node/NodeRegistrar.js
//
// Publishes this SFU node into the SFU node registry on the STATE Redis cluster (noeviction), every 5 s:
//
//   media:sfu:{<region>}:node:<nodeId>   JSON record (sfuNodeRecordSchema), PX 15000
//   media:sfu:{<region>}:index           ZSET member <nodeId>, score = heartbeatAt (ms)
//   media:drain:<nodeId>                 drain flag, written by the node-lifecycle Lambda / runbooks and
//                                        honoured by lifecycle/drainSfu.js and RoomPlacementService
//
// Hash tag {<region>}: all keys of a region share one cluster slot, so the record and the index are written
// atomically in one MULTI, and placement can MGET a whole region. Media regions reach the state cluster
// over Transit Gateway peering (control traffic only).
//
// Draining: setDraining(true) publishes draining=true immediately, so placement stops sending new rooms
// here within one registry snapshot (≈1 s); existing rooms keep running. stop() removes the node.
//
// Owner: F1 Live Classrooms. Read side: classroom/RoomPlacementService.js.

import { isIPv4, isIPv6 } from 'node:net';
import { z } from 'zod';

const REGION = /^[a-z]{2}(-[a-z]+)+-\d{1,2}$/;
const TTL_MS = 15_000;

export const sfuRegistryKeys = Object.freeze({
  node: (region, nodeId) => `media:sfu:{${region}}:node:${nodeId}`,
  index: (region) => `media:sfu:{${region}}:index`,
  drain: (nodeId) => `media:drain:${nodeId}`,
});

const portPair = z.object({ udp: z.number().int().min(1).max(65_535), tcp: z.number().int().min(1).max(65_535) });

/** Registry record contract (write: this file, read: RoomPlacementService). */
export const sfuNodeRecordSchema = z.object({
  nodeId: z.string().regex(/^sfu-[a-z0-9-]{3,80}$/),
  region: z.string().regex(REGION),
  az: z.string().min(1).max(32),
  publicIpv4: z.string().refine((v) => isIPv4(v)),
  publicIpv6: z.string().refine((v) => isIPv6(v)).optional(),
  rtcPorts: z.array(portPair).min(1),
  controlAddress: z.string().regex(/^\d{1,3}(\.\d{1,3}){3}:\d{2,5}$/),
  release: z.string().max(64),
  draining: z.boolean(),
  load: z.object({
    rooms: z.number().int().nonnegative(),
    producers: z.number().int().nonnegative(),
    consumers: z.number().int().nonnegative(),
    cpuMax: z.number().nonnegative(),
    egressMbps: z.number().nonnegative(),
  }).passthrough(),
  loadScore: z.number().nonnegative(),
  heartbeatAt: z.number().int().positive(),
});

export class NodeRegistrar {
  /**
   * @param {object} options
   * @param {import('ioredis').Redis | import('ioredis').Cluster} options.redis   STATE cluster
   * @param {{ nodeId: string, region: string, az: string, publicIpv4: string, publicIpv6?: string,
   *           rtcPorts: Array<{ udp: number, tcp: number }>, controlAddress: string, release: string }} options.node
   * @param {{ snapshot(): Promise<object> }} options.loadReporter
   * @param {number} [options.intervalMs=5000]
   * @param {{ info: Function, warn: Function }} [options.logger]
   * @param {() => number} [options.now]
   */
  constructor({ redis, node, loadReporter, intervalMs = 5_000, logger = console, now = Date.now }) {
    if (!redis || !node || !loadReporter) throw new TypeError('NodeRegistrar: redis, node and loadReporter are required');
    if (intervalMs * 2 >= TTL_MS) throw new RangeError('NodeRegistrar: intervalMs must be well below the 15 s TTL');
    this.#redis = redis;
    this.#node = Object.freeze({ ...node, publicIpv6: node.publicIpv6 || undefined });
    this.#loadReporter = loadReporter;
    this.#intervalMs = intervalMs;
    this.#logger = logger;
    this.#now = now;
  }

  #redis;
  #node;
  #loadReporter;
  #intervalMs;
  #logger;
  #now;
  #draining = false;
  #timer = null;
  #stopped = true;
  #inflight = Promise.resolve();
  #failures = 0;

  get draining() {
    return this.#draining;
  }

  /** First heartbeat must succeed (the node is useless if placement cannot see it); then every intervalMs. */
  async start() {
    this.#stopped = false;
    await this.#beat();
    this.#schedule();
    this.#logger.info({ nodeId: this.#node.nodeId, region: this.#node.region }, 'registered in sfu node registry');
  }

  async setDraining(draining) {
    if (this.#draining === Boolean(draining)) return;
    this.#draining = Boolean(draining);
    this.#logger.info({ nodeId: this.#node.nodeId, draining: this.#draining }, 'sfu drain state changed');
    if (!this.#stopped) await this.#runExclusive(() => this.#beat());
  }

  /** Leaves the registry immediately (shutdown). */
  async stop() {
    this.#stopped = true;
    clearTimeout(this.#timer);
    await this.#inflight.catch(() => {});
    const { region, nodeId } = this.#node;
    await this.#redis
      .multi()
      .zrem(sfuRegistryKeys.index(region), nodeId)
      .del(sfuRegistryKeys.node(region, nodeId))
      .exec();
    this.#logger.info({ nodeId }, 'left sfu node registry');
  }

  #schedule() {
    if (this.#stopped) return;
    this.#timer = setTimeout(() => {
      this.#runExclusive(() => this.#beat())
        .then(() => {
          if (this.#failures > 0) this.#logger.info({ after: this.#failures }, 'sfu heartbeat recovered');
          this.#failures = 0;
        })
        .catch((err) => {
          this.#failures += 1;
          this.#logger.warn({ err: { message: err.message }, failures: this.#failures }, 'sfu heartbeat failed');
        })
        .finally(() => this.#schedule());
    }, this.#intervalMs);
    this.#timer.unref?.();
  }

  #runExclusive(fn) {
    const run = this.#inflight.catch(() => {}).then(fn);
    this.#inflight = run;
    return run;
  }

  async #beat() {
    const load = await this.#loadReporter.snapshot();
    const now = this.#now();
    const record = sfuNodeRecordSchema.parse({
      ...this.#node,
      draining: this.#draining,
      load,
      loadScore: load.loadScore,
      heartbeatAt: now,
    });
    const { region, nodeId } = this.#node;
    const results = await this.#redis
      .multi()
      .set(sfuRegistryKeys.node(region, nodeId), JSON.stringify(record), 'PX', TTL_MS)
      .zadd(sfuRegistryKeys.index(region), now, nodeId)
      .exec();
    const failed = results?.find(([err]) => err);
    if (failed) throw failed[0];
  }
}