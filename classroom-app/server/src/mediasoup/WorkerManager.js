// classroom-app/server/src/mediasoup/WorkerManager.js
/**
 * mediasoup worker pool  (F1, F8)  [EXT]
 *
 * Runs in the sfu role only. Owns every mediasoup worker on this node, the one
 * WebRtcServer each worker carries, and the routers created on them.
 *
 * Version 7: one WebRtcServer per worker (Appendix A #2). A worker owns exactly
 * one UDP and one TCP port — MEDIASOUP_RTC_PORT_BASE + workerIndex — and every
 * WebRTC transport on that worker is multiplexed over them, demultiplexed by
 * ICE username fragment. Port usage no longer grows with participants, so the
 * old limit of roughly a hundred transports per node is gone and the security
 * group opens exactly one small, fixed range.
 *
 * A worker that dies is replaced rather than mourned: the process restarts in
 * place, takes the same index and therefore the same ports, and registers a new
 * WebRtcServer. Its routers are gone with it, so `workerDied` carries the room
 * ids that were on it. RoomManager closes them and the realtime service
 * re-places the rooms; clients rebuild media with a rejoin. That is a visible
 * pause in one room, not an outage on the node.
 */

import os from 'node:os';
import { EventEmitter } from 'node:events';
import * as mediasoup from 'mediasoup';

import { env } from '../config/env.js';
import { mediasoupConfig } from '../config/mediasoup.config.js';
import { createWebRtcServer } from './WebRtcServerFactory.js';

/** A worker index is a port offset, so the pool size is bounded by the range. */
const MAX_WORKERS = 64;
/** Enough to survive a bad build; beyond that the node is broken, not unlucky. */
const MAX_REPLACEMENTS_PER_WINDOW = 5;
const REPLACEMENT_WINDOW_MS = 5 * 60_000;

const workerCount = () => {
  const configured = env.MEDIASOUP_WORKERS;
  const automatic = os.availableParallelism?.() ?? os.cpus().length;
  return Math.min(MAX_WORKERS, configured > 0 ? configured : automatic);
};

/**
 * @typedef {object} WorkerSlot
 * @property {number} index
 * @property {import('mediasoup').types.Worker} worker
 * @property {import('mediasoup').types.WebRtcServer} webRtcServer
 * @property {Map<string, import('mediasoup').types.Router>} routers  roomId → router
 * @property {boolean} alive
 */

export class WorkerManager extends EventEmitter {
  /**
   * @param {object} [options]
   * @param {{ resolve: () => Promise<{ privateIp: string, publicIpv4: string }> }} [options.publicAddress]
   * @param {object} [options.logger]
   */
  constructor({ logger = console } = {}) {
    super();
    this.logger = logger;
    /** @type {Map<number, WorkerSlot>} */
    this.slots = new Map();
    this.starting = null;
    this.closing = false;
    this.replacements = [];
  }

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  /** Idempotent: sfu.js calls it once at boot, tests call it per case. */
  async start() {
    if (this.starting) return this.starting;
    this.starting = (async () => {
      const count = workerCount();
      this.logger.info?.({ workers: count }, 'starting mediasoup workers');
      for (let index = 0; index < count; index += 1) {
        await this.#spawn(index);
      }
      this.emit('ready', { workers: this.slots.size });
      return this;
    })();
    return this.starting;
  }

  async close() {
    this.closing = true;
    for (const slot of this.slots.values()) {
      for (const router of slot.routers.values()) router.close();
      slot.routers.clear();
      slot.worker.close();
    }
    this.slots.clear();
    this.emit('closed');
  }

  async #spawn(index) {
    const worker = await mediasoup.createWorker({
      logLevel: mediasoupConfig.worker.logLevel,
      logTags: mediasoupConfig.worker.logTags,
      // The ports a worker may use for pipe transports; WebRTC ports belong to
      // its WebRtcServer and are not drawn from this range.
      rtcMinPort: env.MEDIASOUP_PIPE_PORT_MIN,
      rtcMaxPort: env.MEDIASOUP_PIPE_PORT_MAX,
      ...(mediasoupConfig.worker.extra ?? {}),
    });

    const webRtcServer = await createWebRtcServer(worker, index);

    /** @type {WorkerSlot} */
    const slot = { index, worker, webRtcServer, routers: new Map(), alive: true };
    this.slots.set(index, slot);

    worker.on('died', (error) => {
      slot.alive = false;
      const roomIds = [...slot.routers.keys()];
      slot.routers.clear();
      this.logger.error?.({ index, pid: worker.pid, err: error, rooms: roomIds.length }, 'mediasoup worker died');
      this.emit('workerDied', { index, roomIds });
      if (!this.closing) void this.#replace(index);
    });

    this.logger.info?.({ index, pid: worker.pid, port: env.MEDIASOUP_RTC_PORT_BASE + index }, 'worker ready');
    return slot;
  }

  async #replace(index) {
    const now = Date.now();
    this.replacements = this.replacements.filter((at) => now - at < REPLACEMENT_WINDOW_MS);
    this.replacements.push(now);

    if (this.replacements.length > MAX_REPLACEMENTS_PER_WINDOW) {
      // Flapping workers mean the node is unhealthy; health.js fails readiness,
      // the registry entry expires and placement stops sending rooms here.
      this.slots.delete(index);
      this.emit('unhealthy', { reason: 'worker-flapping', index });
      return;
    }

    this.slots.delete(index);
    try {
      // The dead process released its ports, so the replacement takes the same
      // index and the same UDP/TCP port pair.
      await this.#spawn(index);
      this.emit('workerReplaced', { index });
    } catch (cause) {
      this.logger.error?.({ index, err: cause }, 'could not replace the worker');
      this.emit('unhealthy', { reason: 'worker-replacement-failed', index });
    }
  }

  // -------------------------------------------------------------------------
  // Routers
  // -------------------------------------------------------------------------

  /** Least loaded by router count; ties go to the lowest index. */
  #pickSlot() {
    let chosen = null;
    for (const slot of this.slots.values()) {
      if (!slot.alive) continue;
      if (!chosen || slot.routers.size < chosen.routers.size) chosen = slot;
    }
    if (!chosen) throw new Error('No mediasoup worker is available on this node');
    return chosen;
  }

  /**
   * One router per room per worker. Breakout rooms ask for their own router on
   * the same worker as the parent, so piping between them stays in-process.
   *
   * @param {string} roomId
   * @param {{ pinToWorkerIndex?: number }} [options]
   */
  async createRouter(roomId, { pinToWorkerIndex } = {}) {
    const existing = this.routerFor(roomId);
    if (existing) return existing;

    const slot =
      pinToWorkerIndex !== undefined && this.slots.get(pinToWorkerIndex)?.alive
        ? this.slots.get(pinToWorkerIndex)
        : this.#pickSlot();

    const router = await slot.worker.createRouter({
      mediaCodecs: mediasoupConfig.router.mediaCodecs,
      appData: { roomId, workerIndex: slot.index },
    });

    slot.routers.set(roomId, router);
    router.observer.once('close', () => slot.routers.delete(roomId));

    return { router, webRtcServer: slot.webRtcServer, workerIndex: slot.index };
  }

  /** @returns {{ router: import('mediasoup').types.Router, webRtcServer: any, workerIndex: number } | null} */
  routerFor(roomId) {
    for (const slot of this.slots.values()) {
      const router = slot.routers.get(roomId);
      if (router) return { router, webRtcServer: slot.webRtcServer, workerIndex: slot.index };
    }
    return null;
  }

  closeRouter(roomId) {
    const found = this.routerFor(roomId);
    if (!found) return false;
    found.router.close();
    return true;
  }

  // -------------------------------------------------------------------------
  // Introspection — health.js and loadReporter.js read this
  // -------------------------------------------------------------------------

  get expectedWorkers() {
    return workerCount();
  }

  get aliveWorkers() {
    return [...this.slots.values()].filter((slot) => slot.alive).length;
  }

  get routerCount() {
    let total = 0;
    for (const slot of this.slots.values()) total += slot.routers.size;
    return total;
  }

  /** The exact UDP/TCP ports this node announces; health.js proves they are bound. */
  get rtcPorts() {
    return [...this.slots.values()].map((slot) => env.MEDIASOUP_RTC_PORT_BASE + slot.index);
  }

  /** True when every alive worker's WebRtcServer still holds its ports. */
  portsBound() {
    for (const slot of this.slots.values()) {
      if (!slot.alive) return false;
      if (!slot.webRtcServer || slot.webRtcServer.closed) return false;
    }
    return this.slots.size > 0;
  }

  async resourceUsage() {
    const usage = await Promise.all(
      [...this.slots.values()].map(async (slot) => ({
        index: slot.index,
        routers: slot.routers.size,
        usage: await slot.worker.getResourceUsage(),
      })),
    );
    return usage;
  }

  snapshot() {
    return {
      expected: this.expectedWorkers,
      alive: this.aliveWorkers,
      routers: this.routerCount,
      ports: this.rtcPorts,
      portsBound: this.portsBound(),
      replacementsInWindow: this.replacements.length,
    };
  }
}

export const createWorkerManager = (options) => new WorkerManager(options);

export default WorkerManager;