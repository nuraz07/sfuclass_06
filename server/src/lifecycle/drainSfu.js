// classroom-app/server/src/lifecycle/drainSfu.js
/**
 * SFU node drain  (F1, F8)  [EXT]
 *
 * Removes one SFU node from service without dropping a lesson. Runs in the sfu
 * role only (sfu.js) and is the long half of taking a node away; the short
 * half is gracefulShutdown.js, which runs when ECS finally sends SIGTERM.
 *
 * Version 7 changes the trigger and the exit. There is no load balancer on the
 * media path any more, so "out of rotation" means "out of the SFU registry",
 * and the node is only allowed to go once the ASG lifecycle hook is completed.
 *
 *   ASG terminate (scale-in, instance refresh, spot interruption)
 *     → lifecycle hook → EventBridge → functions/node-lifecycle
 *     → drain flag  media:drain:{nodeId}  in the state Redis cluster
 *     → this module notices the flag (polls every 5 s)
 *
 *   1. draining   NodeRegistrar heartbeats `draining: true`;
 *                 RoomPlacementService and the drain flag keep new rooms away.
 *                 Existing rooms keep working and still admit late joiners:
 *                 a lesson in progress is never split across nodes by a drain.
 *   2. waiting    until every room on the node is empty, or until
 *                 SFU_DRAIN_TIMEOUT_SEC (capped by the hook's own deadline).
 *                 The lifecycle action is kept alive with heartbeats meanwhile.
 *   3. moving     shortly before the deadline, rooms still on the node are told
 *                 `classroom:node.draining`. Clients rebuild their media with
 *                 `classroom:join { rejoin: true }` and placement puts the room
 *                 on a healthy node. The signalling socket is not touched.
 *   4. drained    the node leaves the registry and completes the lifecycle
 *                 action with CONTINUE. The ASG terminates the instance, ECS
 *                 sends SIGTERM, gracefulShutdown.js closes what is left.
 *
 * A drain without a lifecycle hook (ops/runbooks/sfu-incident.md, a manual
 * `SET media:drain:<nodeId>`) behaves the same but can be cancelled by
 * deleting the flag. A lifecycle drain cannot be cancelled: the ASG has
 * already decided and will terminate at the hook timeout regardless.
 *
 * Everything this module touches on the node is injected (registrar, rooms,
 * notifier, Redis), so it has no opinion on their internals and tests run it
 * with a fake clock.
 */

import { z } from 'zod';
import { env } from '../config/env.js';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const POLL_INTERVAL_MS = 5_000;
/** Clients get this long to move before the deadline. */
const DEFAULT_MOVE_GRACE_SEC = 60;
/** Must stay below the hook's HeartbeatTimeout in modules/sfu-node-pool/lifecycle-hooks.tf. */
const DEFAULT_LIFECYCLE_HEARTBEAT_SEC = 300;
/** AWS gives two minutes for a spot interruption; leave room for SIGTERM. */
const SPOT_DRAIN_CEILING_SEC = 90;
const COMPLETE_ATTEMPTS = 3;

export const DRAIN_STATES = Object.freeze(['serving', 'draining', 'moving', 'drained', 'cancelled']);

/** Registry key from section 4.7. The Redis client applies REDIS_PREFIX. */
export const drainFlagKey = (nodeId) => `media:drain:${nodeId}`;

// ---------------------------------------------------------------------------
// Drain flag — written by functions/node-lifecycle or by an operator
// ---------------------------------------------------------------------------

const DrainFlagSchema = z.object({
  reason: z
    .enum(['scale-in', 'instance-refresh', 'spot-interruption', 'manual'])
    .default('manual'),
  requestedAt: z.iso.datetime().optional(),
  /** Absolute end of the hook (its global timeout); the drain never runs past it. */
  deadline: z.iso.datetime().optional(),
  lifecycle: z
    .object({
      autoScalingGroupName: z.string().min(1).max(255),
      lifecycleHookName: z.string().min(1).max(255),
      lifecycleActionToken: z.string().min(1).max(64),
      instanceId: z.string().regex(/^i-[0-9a-f]+$/),
    })
    .optional(),
});

/** A plain `SET media:drain:<nodeId> 1` from a runbook is a valid manual drain. */
const parseFlag = (raw) => {
  if (raw === null || raw === undefined) return null;
  let value;
  try {
    value = JSON.parse(raw);
  } catch {
    value = {};
  }
  const result = DrainFlagSchema.safeParse(typeof value === 'object' && value !== null ? value : {});
  return result.success ? result.data : { reason: 'manual' };
};

// ---------------------------------------------------------------------------
// Auto Scaling
// ---------------------------------------------------------------------------

/**
 * The SDK is imported lazily: a development node has no ASG and never loads it.
 * Permissions (instance/task role in modules/sfu-node-pool):
 *   autoscaling:RecordLifecycleActionHeartbeat, autoscaling:CompleteLifecycleAction
 */
const createAutoScaling = (region) => {
  let client = null;
  const getClient = async () => {
    if (client) return client;
    const sdk = await import('@aws-sdk/client-auto-scaling');
    client = { sdk, instance: new sdk.AutoScalingClient({ region }) };
    return client;
  };

  const lifecycleParams = (lifecycle) => ({
    AutoScalingGroupName: lifecycle.autoScalingGroupName,
    LifecycleHookName: lifecycle.lifecycleHookName,
    LifecycleActionToken: lifecycle.lifecycleActionToken,
    InstanceId: lifecycle.instanceId,
  });

  return {
    async heartbeat(lifecycle) {
      const { sdk, instance } = await getClient();
      await instance.send(new sdk.RecordLifecycleActionHeartbeatCommand(lifecycleParams(lifecycle)));
    },
    async complete(lifecycle, result = 'CONTINUE') {
      const { sdk, instance } = await getClient();
      await instance.send(
        new sdk.CompleteLifecycleActionCommand({
          ...lifecycleParams(lifecycle),
          LifecycleActionResult: result,
        }),
      );
    },
  };
};

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

/**
 * @typedef {object} DrainRegistrar   sfu-node/NodeRegistrar.js
 * @property {(draining: boolean) => Promise<void>} setDraining  heartbeat carries the flag
 * @property {() => Promise<void>} deregister                    stops the heartbeat, deletes the key
 *
 * @typedef {object} DrainRooms       classroom/RoomManager.js
 * @property {() => { rooms: number, peers: number }} load
 * @property {() => string[]} roomIds
 *
 * @typedef {object} DrainRedis       the state-cluster client from db/redis.js
 * @property {(key: string) => Promise<string | null>} get
 *
 * @param {object} deps
 * @param {string} deps.nodeId
 * @param {DrainRegistrar} deps.registrar
 * @param {DrainRooms} deps.rooms
 * @param {DrainRedis} deps.redis
 * @param {(roomIds: string[], graceSec: number) => Promise<void>} deps.notifyRoomsDraining
 *        tells the realtime service to emit classroom:node.draining to these rooms
 * @param {object} [deps.logger]
 * @param {{ increment?: Function, gauge?: Function }} [deps.metrics]
 * @param {number} [deps.timeoutSec]        default SFU_DRAIN_TIMEOUT_SEC
 * @param {number} [deps.moveGraceSec]
 * @param {number} [deps.lifecycleHeartbeatSec]
 * @param {ReturnType<typeof createAutoScaling>} [deps.autoScaling]  injectable for tests
 * @param {() => number} [deps.now]
 * @param {(ms: number) => Promise<void>} [deps.sleep]
 */
export const createSfuDrain = ({
  nodeId,
  registrar,
  rooms,
  redis,
  notifyRoomsDraining,
  logger = console,
  metrics = {},
  timeoutSec = env.SFU_DRAIN_TIMEOUT_SEC,
  moveGraceSec = DEFAULT_MOVE_GRACE_SEC,
  lifecycleHeartbeatSec = DEFAULT_LIFECYCLE_HEARTBEAT_SEC,
  autoScaling = createAutoScaling(env.AWS_REGION),
  now = () => Date.now(),
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
}) => {
  if (!nodeId) throw new TypeError('createSfuDrain needs a nodeId');
  for (const [name, dep] of Object.entries({ registrar, rooms, redis, notifyRoomsDraining })) {
    if (!dep) throw new TypeError(`createSfuDrain needs ${name}`);
  }

  let state = 'serving';
  let trigger = null;
  let running = null;
  let watchTimer = null;
  let cancelRequested = false;
  let startedAt = null;
  let deadlineAt = null;

  const setState = (next) => {
    if (state === next) return;
    logger.info?.({ nodeId, from: state, to: next }, 'sfu drain state');
    state = next;
    metrics.gauge?.('sfu_drain_state', DRAIN_STATES.indexOf(next), { nodeId });
  };

  const computeDeadline = (flag, startMs) => {
    let limitSec = timeoutSec;
    if (flag.reason === 'spot-interruption') limitSec = Math.min(limitSec, SPOT_DRAIN_CEILING_SEC);
    let deadline = startMs + limitSec * 1_000;
    if (flag.deadline) {
      // Finish a little before the hook's own end so the completion lands.
      deadline = Math.min(deadline, Date.parse(flag.deadline) - 30_000);
    }
    return Math.max(startMs, deadline);
  };

  const completeLifecycle = async (lifecycle) => {
    for (let attempt = 1; attempt <= COMPLETE_ATTEMPTS; attempt += 1) {
      try {
        await autoScaling.complete(lifecycle, 'CONTINUE');
        logger.info?.({ nodeId }, 'lifecycle action completed');
        return;
      } catch (cause) {
        logger.warn?.({ nodeId, attempt, err: cause }, 'completing the lifecycle action failed');
        if (attempt < COMPLETE_ATTEMPTS) await sleep(attempt * 2_000);
      }
    }
    // The hook times out on its own and the ASG proceeds; nothing is lost.
    logger.error?.({ nodeId }, 'lifecycle action not completed; the hook timeout will release it');
  };

  const run = async (flag) => {
    trigger = flag;
    cancelRequested = false;
    startedAt = now();
    deadlineAt = computeDeadline(flag, startedAt);
    const moveAt = Math.max(startedAt, deadlineAt - moveGraceSec * 1_000);
    let lastHeartbeat = startedAt;
    let notified = false;

    setState('draining');
    metrics.increment?.('sfu_drain_started', { nodeId, reason: flag.reason });
    logger.info?.(
      { nodeId, reason: flag.reason, deadline: new Date(deadlineAt).toISOString() },
      'sfu drain started',
    );

    // 1. Out of placement. A failed heartbeat update is not fatal: the drain
    //    flag alone already keeps RoomPlacementService away from this node.
    await registrar.setDraining(true).catch((cause) =>
      logger.warn?.({ nodeId, err: cause }, 'could not mark the node draining in the registry'),
    );

    // 2 + 3. Wait for rooms to empty; move stragglers before the deadline.
    for (;;) {
      if (cancelRequested) {
        await registrar.setDraining(false).catch(() => undefined);
        setState('cancelled');
        metrics.increment?.('sfu_drain_cancelled', { nodeId });
        return;
      }

      const load = rooms.load();
      if (load.rooms === 0 || load.peers === 0) break;

      const current = now();

      if (!notified && current >= moveAt) {
        const roomIds = rooms.roomIds();
        const graceSec = Math.max(0, Math.round((deadlineAt - current) / 1_000));
        setState('moving');
        logger.warn?.({ nodeId, rooms: roomIds.length, graceSec }, 'moving remaining rooms');
        try {
          await notifyRoomsDraining(roomIds, graceSec);
        } catch (cause) {
          logger.error?.({ nodeId, err: cause }, 'could not notify rooms; clients recover via ICE');
        }
        notified = true;
      }

      if (current >= deadlineAt) {
        logger.warn?.({ nodeId, ...load }, 'drain timeout reached with rooms still on the node');
        metrics.increment?.('sfu_drain_forced', { nodeId });
        break;
      }

      if (flag.lifecycle && current - lastHeartbeat >= lifecycleHeartbeatSec * 1_000) {
        try {
          await autoScaling.heartbeat(flag.lifecycle);
          lastHeartbeat = current;
        } catch (cause) {
          logger.warn?.({ nodeId, err: cause }, 'lifecycle heartbeat failed');
        }
      }

      await sleep(POLL_INTERVAL_MS);
    }

    // 4. Leave the registry, then let the ASG proceed.
    await registrar.deregister().catch((cause) =>
      logger.warn?.({ nodeId, err: cause }, 'deregistration failed; the registry TTL (15 s) expires it'),
    );

    if (flag.lifecycle) await completeLifecycle(flag.lifecycle);

    setState('drained');
    metrics.increment?.('sfu_drain_completed', { nodeId, reason: flag.reason });
    logger.info?.({ nodeId, ms: now() - startedAt }, 'sfu drain complete');
  };

  const start = (flag = { reason: 'manual' }) => {
    if (running) return running;
    if (state === 'drained') return Promise.resolve();
    running = run(flag)
      .catch((cause) => {
        logger.error?.({ nodeId, err: cause }, 'sfu drain failed');
      })
      .finally(() => {
        running = null;
      });
    return running;
  };

  /** Cancels a manual drain. A lifecycle drain cannot be cancelled. */
  const cancel = () => {
    if (!running || trigger?.lifecycle) return false;
    cancelRequested = true;
    return true;
  };

  const checkFlag = async () => {
    let raw;
    try {
      raw = await redis.get(drainFlagKey(nodeId));
    } catch (cause) {
      // Redis unreachable: keep serving. The lifecycle hook still ends the node
      // at its timeout, so a missed flag delays termination, it does not lose it.
      logger.warn?.({ nodeId, err: cause }, 'drain flag check failed');
      return;
    }

    const flag = parseFlag(raw);
    if (flag && state === 'serving') {
      void start(flag);
    } else if (!flag && running && !trigger?.lifecycle) {
      cancel();
    }
  };

  /** Starts polling the drain flag. Returns a stop function. */
  const watch = () => {
    if (watchTimer) return () => stopWatching();
    void checkFlag();
    watchTimer = setInterval(() => void checkFlag(), POLL_INTERVAL_MS);
    watchTimer.unref?.();
    return () => stopWatching();
  };

  const stopWatching = () => {
    if (watchTimer) clearInterval(watchTimer);
    watchTimer = null;
  };

  return Object.freeze({
    start,
    cancel,
    watch,
    stopWatching,
    /** controlServer.js refuses room creation while this is true. */
    isDraining: () => state === 'draining' || state === 'moving' || state === 'drained',
    /** For /healthz/sfu: a draining node is healthy, just not accepting rooms. */
    status: () =>
      Object.freeze({
        state,
        reason: trigger?.reason ?? null,
        startedAt: startedAt ? new Date(startedAt).toISOString() : null,
        deadline: deadlineAt ? new Date(deadlineAt).toISOString() : null,
        lifecycle: Boolean(trigger?.lifecycle),
      }),
    /** Resolves when a running drain has finished (for SIGTERM during a drain). */
    settled: () => running ?? Promise.resolve(),
  });
};

export default createSfuDrain;