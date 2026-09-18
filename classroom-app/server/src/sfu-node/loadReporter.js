// server/src/sfu-node/loadReporter.js
//
// Measures how busy this SFU node is. The snapshot is published by NodeRegistrar every 5 s and drives
//   - room placement (classroom/RoomPlacementService.js: new rooms go to the lowest loadScore),
//   - health (mediasoup/health.js: node reports unhealthy above SFU_MAX_LOAD_SCORE),
//   - autoscaling (infra/modules/sfu-node-pool/autoscaling.tf: custom metric sfu.load_score).
//
// Sources, all cheap enough for a 5 s cadence:
//   rooms                RoomManager.roomCount()
//   routers/transports/producers/consumers   mediasoup observer events, counted incrementally (no polling)
//   CPU                  worker.getResourceUsage() deltas per worker: each worker is one process on one core,
//                        so the busiest worker — not the average — is what limits new rooms
//   egress Mbit/s        /proc/net/dev TX bytes of the host interfaces (host networking: the task sees the
//                        instance NIC); includes relayed-to-TURN and pipe traffic, which is what the NIC carries
//
// loadScore = max(cpuMax / cpuTarget, consumers / consumerCapacity, egressMbps / egressCapacityMbps)
// 1.0 means "at planned capacity". Placement uses 0.75 for new rooms; autoscaling targets 0.6.
//
// Owner: F1 Live Classrooms.

import { readFile } from 'node:fs/promises';

const IGNORED_INTERFACES = /^(lo|docker\d*|veth.*|ecs-.*|br-.*|cni.*)$/;

export class LoadReporter {
  /**
   * @param {object} options
   * @param {{ workers(): Array<{ index: number, worker: import('mediasoup').types.Worker }>,
   *           on(event: 'workerStarted', fn: (entry: { index: number, worker: any }) => void): void }} options.workerManager
   * @param {{ roomCount(): number }} options.roomManager
   * @param {{ gauge: Function }} [options.metrics]
   * @param {object} [options.limits]
   * @param {number} [options.limits.cpuTarget=0.85]               worker CPU fraction treated as full
   * @param {number} [options.limits.consumersPerWorker=500]
   * @param {number} [options.limits.egressCapacityMbps=5000]      sustained NIC baseline of the instance type
   * @param {() => number} [options.now]
   * @param {(path: string) => Promise<string>} [options.readProcFile]
   */
  constructor({ workerManager, roomManager, metrics, limits = {}, now = Date.now, readProcFile = (p) => readFile(p, 'utf8') }) {
    if (!workerManager || !roomManager) throw new TypeError('LoadReporter: workerManager and roomManager are required');
    this.#workerManager = workerManager;
    this.#roomManager = roomManager;
    this.#metrics = metrics ?? { gauge: () => {} };
    this.#limits = { cpuTarget: 0.85, consumersPerWorker: 500, egressCapacityMbps: 5_000, ...limits };
    this.#now = now;
    this.#readProcFile = readProcFile;

    for (const entry of workerManager.workers()) this.#observeWorker(entry.worker);
    workerManager.on?.('workerStarted', ({ worker }) => this.#observeWorker(worker));
  }

  #workerManager;
  #roomManager;
  #metrics;
  #limits;
  #now;
  #readProcFile;
  #counts = { routers: 0, transports: 0, producers: 0, consumers: 0 };
  /** @type {WeakSet<object>} */ #observed = new WeakSet();
  /** @type {Map<number, { cpuMs: number, at: number }>} pid → last sample */ #cpu = new Map();
  /** @type {{ txBytes: number, at: number } | null} */ #net = null;

  /**
   * @returns {Promise<{ rooms: number, workers: number, routers: number, transports: number, producers: number,
   *   consumers: number, cpuMax: number, cpuAvg: number, egressMbps: number, loadScore: number, sampledAt: number }>}
   */
  async snapshot() {
    const workers = this.#workerManager.workers();
    const [cpu, egressMbps] = await Promise.all([this.#sampleCpu(workers), this.#sampleEgress()]);

    const consumerCapacity = Math.max(1, workers.length) * this.#limits.consumersPerWorker;
    const loadScore = round(Math.max(
      cpu.max / this.#limits.cpuTarget,
      this.#counts.consumers / consumerCapacity,
      egressMbps / this.#limits.egressCapacityMbps,
    ));

    const snapshot = {
      rooms: this.#roomManager.roomCount(),
      workers: workers.length,
      ...this.#counts,
      cpuMax: round(cpu.max),
      cpuAvg: round(cpu.avg),
      egressMbps: round(egressMbps),
      loadScore,
      sampledAt: this.#now(),
    };
    this.#metrics.gauge('sfu.load_score', loadScore);
    this.#metrics.gauge('sfu.consumers', snapshot.consumers);
    this.#metrics.gauge('sfu.egress_mbps', snapshot.egressMbps);
    this.#metrics.gauge('sfu.cpu_max', snapshot.cpuMax);
    return Object.freeze(snapshot);
  }

  #observeWorker(worker) {
    if (!worker || this.#observed.has(worker)) return;
    this.#observed.add(worker);
    const track = (emitter, key, onNew) => {
      this.#counts[key] += 1;
      emitter.observer.once('close', () => { this.#counts[key] -= 1; });
      onNew?.(emitter);
    };
    worker.observer.on('newrouter', (router) => track(router, 'routers', (r) => {
      r.observer.on('newtransport', (transport) => track(transport, 'transports', (t) => {
        t.observer.on('newproducer', (producer) => track(producer, 'producers'));
        t.observer.on('newconsumer', (consumer) => track(consumer, 'consumers'));
      }));
    }));
    worker.observer.once('close', () => this.#cpu.delete(worker.pid));
  }

  async #sampleCpu(workers) {
    const now = this.#now();
    const fractions = await Promise.all(workers.map(async ({ worker }) => {
      try {
        const usage = await worker.getResourceUsage();
        const cpuMs = usage.ru_utime + usage.ru_stime;
        const prev = this.#cpu.get(worker.pid);
        this.#cpu.set(worker.pid, { cpuMs, at: now });
        if (!prev || now <= prev.at) return 0;
        return Math.min(1, Math.max(0, (cpuMs - prev.cpuMs) / (now - prev.at)));
      } catch {
        return 0; // worker closing
      }
    }));
    if (fractions.length === 0) return { max: 0, avg: 0 };
    return { max: Math.max(...fractions), avg: fractions.reduce((a, b) => a + b, 0) / fractions.length };
  }

  async #sampleEgress() {
    let txBytes;
    try {
      txBytes = parseTxBytes(await this.#readProcFile('/proc/net/dev'));
    } catch {
      return 0; // not Linux (local development on macOS)
    }
    const now = this.#now();
    const prev = this.#net;
    this.#net = { txBytes, at: now };
    if (!prev || now <= prev.at || txBytes < prev.txBytes) return 0;
    return ((txBytes - prev.txBytes) * 8) / ((now - prev.at) / 1000) / 1_000_000;
  }
}

/** Sum of transmitted bytes over physical interfaces in /proc/net/dev. */
export function parseTxBytes(procNetDev) {
  let total = 0;
  for (const line of procNetDev.split('\n').slice(2)) {
    const [name, rest] = line.split(':');
    if (!rest) continue;
    const iface = name.trim();
    if (IGNORED_INTERFACES.test(iface)) continue;
    const fields = rest.trim().split(/\s+/).map(Number);
    total += fields[8] ?? 0; // receive: 8 fields, then transmit bytes
  }
  return total;
}

function round(n) {
  return Math.round(n * 1000) / 1000;
}