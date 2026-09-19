// turn/agent/src/metricsBridge.js
//
// Turns coturn's Prometheus endpoint (127.0.0.1:9641, "prometheus" in turnserver.conf) and the host NIC counters
// into the two numbers the platform needs from every TURN node, and forwards them to CloudWatch.
//
//   allocations   coturn gauge turn_total_allocations (all label sets summed). Fallback when the metric is
//                 missing: UDP sockets bound in the relay port range (/proc/net/udp, /proc/net/udp6) — one
//                 relay socket per allocation (no-tcp-relay). The TURN host's ephemeral range is kept below the
//                 relay range by the launch template (net.ipv4.ip_local_port_range), so nothing else binds there.
//   relayMbps     transmit rate of the host NIC (/proc/net/dev; host networking) — relayed media dominates it and
//                 it is what the instance's bandwidth baseline limits.
//
// Scraped every 5 s (heartbeat.js and drain.js read latest()). Every 60 s one CloudWatch Embedded Metric Format
// record is written to stdout; the awslogs driver ships it and CloudWatch extracts the metrics — no SDK, no
// PutMetricData permission. Namespace Classroom/Turn, dimensions [Region] and [Region, Node]:
//   ActiveAllocations · RelayEgressMbps · LoadRatio · ProbeSuccess · ProbeRttMs · Draining · CoturnMetricsUp
// infra/modules/turn-node-pool/autoscaling.tf scales on LoadRatio; alarms live in infra/media-edge/observability.tf.
//
// Owner: F8 Real-Time Connectivity.

import { readFile } from 'node:fs/promises';

const IGNORED_INTERFACES = /^(lo|docker\d*|veth.*|ecs-.*|br-.*|cni.*)$/;

export class MetricsBridge {
  /**
   * @param {object} options
   * @param {{ node: string, region: string, maxAllocations: number, capacityMbps: number,
   *           ports: { relayMin: number, relayMax: number, prometheus: number } }} options.node
   * @param {() => { probeOk: boolean, probeRttMs: number | null, draining: boolean }} options.getStatus
   * @param {number} [options.scrapeIntervalMs=5000]
   * @param {number} [options.emitIntervalMs=60000]
   * @param {(line: string) => void} [options.emit]      defaults to stdout
   * @param {(path: string) => Promise<string>} [options.readProcFile]
   * @param {typeof fetch} [options.fetchImpl]
   * @param {{ warn: Function }} [options.logger]
   * @param {() => number} [options.now]
   */
  constructor({
    node, getStatus, scrapeIntervalMs = 5_000, emitIntervalMs = 60_000,
    emit = (line) => process.stdout.write(`${line}\n`),
    readProcFile = (p) => readFile(p, 'utf8'), fetchImpl = fetch, logger = console, now = Date.now,
  }) {
    this.node = node;
    this.getStatus = getStatus;
    this.scrapeIntervalMs = scrapeIntervalMs;
    this.emitIntervalMs = emitIntervalMs;
    this.emit = emit;
    this.readProcFile = readProcFile;
    this.fetchImpl = fetchImpl;
    this.logger = logger;
    this.now = now;
    this.state = { allocations: 0, allocationsSource: 'none', relayMbps: 0, coturnUp: false, scrapedAt: 0 };
  }

  #scrapeTimer = null;
  #emitTimer = null;
  #net = null;
  #warnedFallback = false;

  start() {
    const scrape = () => this.scrapeOnce().catch((err) => this.logger.warn({ err: { message: err.message } }, 'metrics scrape failed'));
    scrape();
    this.#scrapeTimer = setInterval(scrape, this.scrapeIntervalMs);
    this.#emitTimer = setInterval(() => this.emitOnce(), this.emitIntervalMs);
    this.#scrapeTimer.unref?.();
    this.#emitTimer.unref?.();
  }

  stop() {
    clearInterval(this.#scrapeTimer);
    clearInterval(this.#emitTimer);
  }

  latest() {
    return this.state;
  }

  async scrapeOnce() {
    const [prom, relayMbps] = await Promise.all([this.#scrapePrometheus(), this.#egressMbps()]);
    let allocations = prom.allocations;
    let allocationsSource = 'prometheus';
    if (allocations === null) {
      allocations = await this.#relaySockets();
      allocationsSource = 'proc';
      if (!this.#warnedFallback) {
        this.logger.warn({}, 'turn_total_allocations unavailable; counting relay sockets instead');
        this.#warnedFallback = true;
      }
    }
    this.state = { allocations, allocationsSource, relayMbps, coturnUp: prom.up, scrapedAt: this.now() };
    return this.state;
  }

  emitOnce() {
    const status = this.getStatus();
    const { allocations, relayMbps, coturnUp } = this.state;
    const loadRatio = Math.max(allocations / this.node.maxAllocations, relayMbps / this.node.capacityMbps);
    const metrics = {
      ActiveAllocations: allocations,
      RelayEgressMbps: round(relayMbps),
      LoadRatio: round(loadRatio),
      ProbeSuccess: status.probeOk ? 1 : 0,
      Draining: status.draining ? 1 : 0,
      CoturnMetricsUp: coturnUp ? 1 : 0,
    };
    if (Number.isFinite(status.probeRttMs)) metrics.ProbeRttMs = status.probeRttMs;
    const units = { RelayEgressMbps: 'Megabits/Second', ProbeRttMs: 'Milliseconds', LoadRatio: 'None' };
    this.emit(JSON.stringify({
      _aws: {
        Timestamp: this.now(),
        CloudWatchMetrics: [{
          Namespace: 'Classroom/Turn',
          Dimensions: [['Region'], ['Region', 'Node']],
          Metrics: Object.keys(metrics).map((Name) => ({ Name, Unit: units[Name] ?? 'Count' })),
        }],
      },
      Region: this.node.region,
      Node: this.node.node,
      ...metrics,
    }));
  }

  async #scrapePrometheus() {
    try {
      const res = await this.fetchImpl(`http://127.0.0.1:${this.node.ports.prometheus}/metrics`, { signal: AbortSignal.timeout(2_000) });
      if (!res.ok) return { up: false, allocations: null };
      const samples = parsePrometheus(await res.text());
      const alloc = samples.get('turn_total_allocations');
      return { up: true, allocations: alloc ? alloc.reduce((sum, s) => sum + s.value, 0) : null };
    } catch {
      return { up: false, allocations: null };
    }
  }

  async #relaySockets() {
    const { relayMin, relayMax } = this.node.ports;
    let count = 0;
    for (const file of ['/proc/net/udp', '/proc/net/udp6']) {
      try {
        for (const line of (await this.readProcFile(file)).split('\n').slice(1)) {
          const local = line.trim().split(/\s+/)[1];
          if (!local) continue;
          const port = Number.parseInt(local.split(':').pop(), 16);
          if (port >= relayMin && port <= relayMax) count += 1;
        }
      } catch {
        /* file absent (no IPv6) */
      }
    }
    return count;
  }

  async #egressMbps() {
    let tx;
    try {
      tx = parseTxBytes(await this.readProcFile('/proc/net/dev'));
    } catch {
      return 0;
    }
    const now = this.now();
    const prev = this.#net;
    this.#net = { tx, at: now };
    if (!prev || now <= prev.at || tx < prev.tx) return this.state.relayMbps;
    return ((tx - prev.tx) * 8) / ((now - prev.at) / 1_000) / 1_000_000;
  }
}

/** Minimal Prometheus text-format parser: name → [{ labels, value }]. */
export function parsePrometheus(text) {
  const out = new Map();
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const match = /^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{([^}]*)\})?\s+([^\s]+)/.exec(line);
    if (!match) continue;
    const value = Number(match[4]);
    if (!Number.isFinite(value)) continue;
    const labels = {};
    for (const pair of (match[3] ?? '').matchAll(/([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\]|\\.)*)"/g)) labels[pair[1]] = pair[2];
    if (!out.has(match[1])) out.set(match[1], []);
    out.get(match[1]).push({ labels, value });
  }
  return out;
}

/** Sum of transmitted bytes over physical interfaces in /proc/net/dev. */
export function parseTxBytes(procNetDev) {
  let total = 0;
  for (const line of procNetDev.split('\n').slice(2)) {
    const [name, rest] = line.split(':');
    if (!rest || IGNORED_INTERFACES.test(name.trim())) continue;
    total += Number(rest.trim().split(/\s+/)[8] ?? 0);
  }
  return total;
}

function round(n) {
  return Math.round(n * 1000) / 1000;
}