// turn/agent/src/drain.js
//
// Takes this TURN node out of service without cutting a single live relay allocation.
//
//   1. leave the registry at once — the API stops handing out this node's address (no new allocations);
//   2. keep serving existing allocations and wait until they reach zero, or until the drain timeout
//      (TURN_DRAIN_TIMEOUT_MS, default 4 h = longest lesson plus margin) — clients on a node that is finally
//      stopped recover through ICE restart with fresh credentials (core-client IceRecovery);
//   3. if the drain was started by an Auto Scaling terminate lifecycle hook, complete the hook (CONTINUE) so the
//      instance terminates; while waiting, record hook heartbeats so the hook does not time out.
//
// Triggers:
//   drain flag   media:drain:<node> in the state Redis, set by infra/functions/node-lifecycle on scale-in or
//                instance refresh. Value (JSON, optional fields):
//                  { "reason": "scale-in", "lifecycle": { "hookName": "…", "autoScalingGroupName": "…" } }
//   POST /drain  healthServer.js, loopback only — used by .github/workflows/deploy-turn.yml over SSM
//                (blue/green switch; the old colour's tasks are stopped by scaling the service to 0 afterwards).
//
// A drain cannot be cancelled by design: a node that started draining is replaced, never re-admitted.
//
// Owner: F8 Real-Time Connectivity.

import { turnRegistryKeys } from './heartbeat.js';

export class DrainController {
  /**
   * @param {object} options
   * @param {import('ioredis').Redis | import('ioredis').Cluster} options.redis
   * @param {{ node: string, region: string, instanceId: string }} options.node
   * @param {{ leave(): Promise<void> }} options.heartbeat
   * @param {() => number} options.getAllocations
   * @param {() => Promise<{ send(cmd: object): Promise<unknown> }>} [options.autoScalingClient]  lazy AWS SDK client
   * @param {number} [options.timeoutMs=14400000]
   * @param {number} [options.pollMs=5000]
   * @param {number} [options.hookHeartbeatMs=1800000]
   * @param {{ info: Function, warn: Function, error: Function }} [options.logger]
   */
  constructor({
    redis, node, heartbeat, getAllocations, autoScalingClient,
    timeoutMs = 4 * 3_600_000, pollMs = 5_000, hookHeartbeatMs = 30 * 60_000, logger = console,
  }) {
    this.redis = redis;
    this.node = node;
    this.heartbeat = heartbeat;
    this.getAllocations = getAllocations;
    this.autoScalingClient = autoScalingClient ?? defaultAutoScalingClient(node.region);
    this.timeoutMs = timeoutMs;
    this.pollMs = pollMs;
    this.hookHeartbeatMs = hookHeartbeatMs;
    this.logger = logger;
    this.state = { draining: false, reason: null, since: null, completedAt: null, outcome: null, lifecycle: null };
  }

  #flagTimer = null;
  #drainPromise = null;

  isDraining() {
    return this.state.draining;
  }

  status() {
    return { ...this.state, allocations: this.getAllocations() };
  }

  /** Polls the drain flag written by the node-lifecycle Lambda. */
  watchFlag() {
    const check = async () => {
      try {
        const raw = await this.redis.get(turnRegistryKeys.drain(this.node.node));
        if (raw !== null && !this.state.draining) {
          let flag = {};
          try {
            flag = JSON.parse(raw);
          } catch {
            flag = { reason: String(raw).slice(0, 64) };
          }
          this.begin({ reason: flag.reason ?? 'drain-flag', lifecycle: flag.lifecycle ?? null });
        }
      } catch (err) {
        this.logger.warn({ err: { message: err.message } }, 'drain flag check failed');
      }
    };
    check();
    this.#flagTimer = setInterval(check, this.pollMs);
    this.#flagTimer.unref?.();
  }

  stop() {
    clearInterval(this.#flagTimer);
  }

  /**
   * Starts draining (idempotent). Resolves when the drain has finished.
   * @param {{ reason: string, lifecycle?: { hookName: string, autoScalingGroupName: string } | null }} request
   */
  begin({ reason, lifecycle = null }) {
    if (this.#drainPromise) {
      // A later hook notification (instance refresh after a manual drain) still gets completed.
      if (lifecycle && !this.state.lifecycle) this.state.lifecycle = lifecycle;
      return this.#drainPromise;
    }
    this.state = { draining: true, reason, since: new Date().toISOString(), completedAt: null, outcome: null, lifecycle };
    this.logger.info({ reason, lifecycle }, 'turn node draining');
    this.#drainPromise = this.#run();
    return this.#drainPromise;
  }

  async #run() {
    await this.heartbeat.leave().catch((err) => this.logger.warn({ err: { message: err.message } }, 'could not leave registry'));
    const deadline = Date.now() + this.timeoutMs;
    let lastHookHeartbeat = Date.now();

    for (;;) {
      const allocations = this.getAllocations();
      if (allocations === 0) {
        this.state.outcome = 'drained';
        break;
      }
      if (Date.now() >= deadline) {
        this.state.outcome = 'timeout';
        this.logger.warn({ allocations }, 'drain timeout reached; remaining clients will restart ICE on another node');
        break;
      }
      if (this.state.lifecycle && Date.now() - lastHookHeartbeat >= this.hookHeartbeatMs) {
        await this.#hook('RecordLifecycleActionHeartbeatCommand').catch((err) =>
          this.logger.warn({ err: { message: err.message } }, 'lifecycle heartbeat failed'));
        lastHookHeartbeat = Date.now();
      }
      await new Promise((resolve) => setTimeout(resolve, this.pollMs));
    }

    this.state.completedAt = new Date().toISOString();
    this.logger.info({ outcome: this.state.outcome, reason: this.state.reason }, 'turn node drained');
    if (this.state.lifecycle) {
      try {
        await this.#hook('CompleteLifecycleActionCommand', { LifecycleActionResult: 'CONTINUE' });
        this.logger.info({ hook: this.state.lifecycle.hookName }, 'lifecycle hook completed');
      } catch (err) {
        // The hook's own timeout (default result CONTINUE) still terminates the instance.
        this.logger.error({ err: { message: err.message } }, 'could not complete lifecycle hook');
      }
    }
    return this.state;
  }

  async #hook(commandName, extra = {}) {
    const client = await this.autoScalingClient();
    const sdk = await import('@aws-sdk/client-auto-scaling');
    await client.send(new sdk[commandName]({
      LifecycleHookName: this.state.lifecycle.hookName,
      AutoScalingGroupName: this.state.lifecycle.autoScalingGroupName,
      InstanceId: this.node.instanceId,
      ...extra,
    }));
  }
}

function defaultAutoScalingClient(region) {
  let client;
  return async () => {
    if (!client) {
      const { AutoScalingClient } = await import('@aws-sdk/client-auto-scaling');
      client = new AutoScalingClient({ region });
    }
    return client;
  };
}