// turn/agent/src/heartbeat.js
//
// Publishes this TURN node into the TURN registry on the STATE Redis cluster, every 5 s, TTL 15 s:
//
//   media:turn:{<region>}:node:<node>   JSON record (below), PX 15000
//   media:turn:{<region>}:index         ZSET member <node>, score = heartbeatAt (ms)
//
// Read side: server/src/rtc/TurnPoolRegistry.js (turnRegistryKeys, turnNodeRecordSchema). Both sides must agree
// byte for byte; turn/test/allocation.spec.js validates this file's output against the server schema.
// The braces are a Redis Cluster hash tag: record and index share a slot, so they are written in one MULTI.
//
// The node is published only while it can really serve clients:
//   - the self-probe passes (selfProbe.js: STUN + TURN allocation over UDP and TLS),
//   - it is not draining (drain.js).
// When either stops being true the node leaves the registry immediately — the API stops handing out its address
// within one registry snapshot (≈1 s) instead of waiting for the 15 s TTL.
//
// Owner: F8 Real-Time Connectivity.

const TTL_MS = 15_000;

export const turnRegistryKeys = Object.freeze({
  node: (region, node) => `media:turn:{${region}}:node:${node}`,
  index: (region) => `media:turn:{${region}}:index`,
  drain: (node) => `media:drain:${node}`,
});

export class TurnHeartbeat {
  /**
   * @param {object} options
   * @param {import('ioredis').Redis | import('ioredis').Cluster} options.redis
   * @param {{ node: string, region: string, az: string, hostname: string, publicIpv4: string,
   *           publicIpv6: string | null, maxAllocations: number, capacityMbps: number }} options.node  node.json
   * @param {() => { allocations: number, relayMbps: number }} options.getLoad     metricsBridge.latest()
   * @param {() => boolean} options.isHealthy                                     selfProbe.isHealthy()
   * @param {() => boolean} options.isDraining                                    drain.isDraining()
   * @param {string} [options.version]                                           RELEASE_SHA
   * @param {number} [options.intervalMs=5000]
   * @param {{ info: Function, warn: Function }} [options.logger]
   * @param {() => number} [options.now]
   */
  constructor({ redis, node, getLoad, isHealthy, isDraining, version, intervalMs = 5_000, logger = console, now = Date.now }) {
    if (intervalMs * 2 >= TTL_MS) throw new RangeError('TurnHeartbeat: intervalMs must be well below the 15 s TTL');
    this.redis = redis;
    this.node = node;
    this.getLoad = getLoad;
    this.isHealthy = isHealthy;
    this.isDraining = isDraining;
    this.version = version ? String(version).slice(0, 64) : undefined;
    this.intervalMs = intervalMs;
    this.logger = logger;
    this.now = now;
    this.published = false;
    this.lastError = null;
  }

  #timer = null;
  #running = false;
  #chain = Promise.resolve();

  start() {
    this.#running = true;
    const loop = () => {
      this.#serial(() => this.beatOnce())
        .catch((err) => {
          this.lastError = err.message;
          this.logger.warn({ err: { message: err.message } }, 'turn heartbeat failed');
        })
        .finally(() => {
          if (this.#running) {
            this.#timer = setTimeout(loop, this.intervalMs);
            this.#timer.unref?.();
          }
        });
    };
    loop();
  }

  /** Stops heartbeating and removes the node from the registry. */
  async stop() {
    this.#running = false;
    clearTimeout(this.#timer);
    await this.#serial(() => this.leave());
  }

  /** The record exactly as TurnPoolRegistry validates it. */
  record() {
    const { allocations, relayMbps } = this.getLoad();
    const record = {
      node: this.node.node,
      region: this.node.region,
      az: this.node.az,
      hostname: this.node.hostname,
      publicIpv4: this.node.publicIpv4,
      allocations: Math.max(0, Math.round(allocations)),
      maxAllocations: this.node.maxAllocations,
      relayMbps: Math.max(0, Math.round(relayMbps * 1000) / 1000),
      capacityMbps: this.node.capacityMbps,
      draining: false,
      heartbeatAt: this.now(),
    };
    if (this.node.publicIpv6) record.publicIpv6 = this.node.publicIpv6;
    if (this.version) record.version = this.version;
    return record;
  }

  async beatOnce() {
    if (!this.isHealthy() || this.isDraining()) {
      if (this.published) {
        this.logger.info({ healthy: this.isHealthy(), draining: this.isDraining() }, 'leaving turn registry');
      }
      await this.leave();
      return;
    }
    const record = this.record();
    const { region, node } = this.node;
    const results = await this.redis
      .multi()
      .set(turnRegistryKeys.node(region, node), JSON.stringify(record), 'PX', TTL_MS)
      .zadd(turnRegistryKeys.index(region), record.heartbeatAt, node)
      .exec();
    const failed = results?.find(([err]) => err);
    if (failed) throw failed[0];
    if (!this.published) this.logger.info({ node, region }, 'published in turn registry');
    this.published = true;
    this.lastError = null;
  }

  async leave() {
    if (!this.published) return;
    const { region, node } = this.node;
    await this.redis.multi().zrem(turnRegistryKeys.index(region), node).del(turnRegistryKeys.node(region, node)).exec();
    this.published = false;
  }

  #serial(fn) {
    const run = this.#chain.catch(() => {}).then(fn);
    this.#chain = run;
    return run;
  }
}