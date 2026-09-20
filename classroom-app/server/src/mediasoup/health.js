// classroom-app/server/src/mediasoup/health.js
/**
 * SFU node health  (F1, F7, F8)  [EXT]
 *
 * Answers GET /healthz/sfu on the private control port (7443, mTLS). There is
 * no load balancer on the media path any more (Appendix A #11), so the readers
 * are ECS, the node-lifecycle Lambda and NodeRegistrar — the heartbeat only
 * goes into the registry while this check passes, which is what keeps
 * RoomPlacementService away from a node that cannot actually carry a lesson.
 *
 * Four things decide healthy:
 *
 *   workers    every expected mediasoup worker is alive
 *   ports      every worker's WebRtcServer still holds its UDP and TCP port —
 *              a bound port is the only proof that ICE can even be answered
 *   address    the public address resolved from IMDSv2; without it the node
 *              would announce candidates nobody can reach
 *   load       the load score is below SFU_MAX_LOAD_SCORE
 *
 * Draining is not unhealthy. A draining node still serves its rooms to the end;
 * it just stops taking new ones. Reporting it as unhealthy would make ECS
 * restart the task and kill the lessons the drain exists to protect.
 *
 * Load above the cap is not unhealthy either: it is "full". Placement reads
 * `accepting`, and a full node keeps serving what it has.
 */

const DEGRADED = 503;
const OK = 200;

/**
 * @param {object} deps
 * @param {import('./WorkerManager.js').WorkerManager} deps.workerManager
 * @param {{ current: () => { privateIp: string, publicIpv4: string | null, publicIpv6?: string | null } | null }} deps.publicAddress
 *        config/publicAddress.js, resolved once at boot
 * @param {{ score: () => number, snapshot: () => object }} deps.loadReporter  sfu-node/loadReporter.js
 * @param {{ status: () => { state: string } }} [deps.drain]                   lifecycle/drainSfu.js
 * @param {number} deps.maxLoadScore                                           env.SFU_MAX_LOAD_SCORE
 * @param {string} deps.nodeId
 * @param {string} deps.region
 * @param {string} deps.releaseSha
 */
export const createSfuHealth = ({
  workerManager,
  publicAddress,
  loadReporter,
  drain = null,
  maxLoadScore,
  nodeId,
  region,
  releaseSha,
}) => {
  const checks = () => {
    const workers = workerManager.snapshot();
    const address = publicAddress.current();
    const score = loadReporter.score();
    const drainState = drain?.status().state ?? 'serving';

    return {
      workers: {
        ok: workers.alive === workers.expected && workers.alive > 0,
        alive: workers.alive,
        expected: workers.expected,
        replacementsInWindow: workers.replacementsInWindow,
      },
      ports: {
        ok: workers.portsBound,
        rtc: workers.ports,
      },
      publicAddress: {
        ok: Boolean(address?.publicIpv4),
        ipv4: Boolean(address?.publicIpv4),
        ipv6: Boolean(address?.publicIpv6),
      },
      load: {
        ok: score < maxLoadScore,
        score,
        max: maxLoadScore,
      },
      drain: { state: drainState },
    };
  };

  /**
   * The full picture. NodeRegistrar publishes `accepting` and `loadScore` into
   * media:sfu:{region}:{nodeId}; TurnPoolSelector and placement never see more
   * than that.
   */
  const snapshot = () => {
    const result = checks();
    // Everything except load has to hold for the node to be healthy at all.
    const healthy =
      result.workers.ok && result.ports.ok && result.publicAddress.ok;
    const draining = result.drain.state !== 'serving';

    return {
      status: healthy ? 'ok' : 'degraded',
      healthy,
      /** What placement asks: may this node be given a new room? */
      accepting: healthy && !draining && result.load.ok,
      draining,
      nodeId,
      region,
      release: releaseSha,
      rooms: workerManager.routerCount,
      loadScore: result.load.score,
      checks: result,
      at: new Date().toISOString(),
    };
  };

  /**
   * Express-style handler for sfu-node/controlServer.js:
   *   app.get('/healthz/sfu', health.handler)
   */
  const handler = (_request, response) => {
    const body = snapshot();
    response.status(body.healthy ? OK : DEGRADED).json(body);
  };

  /** Liveness only: the process runs and the event loop answers. */
  const live = (_request, response) => response.status(OK).json({ status: 'ok', nodeId });

  return Object.freeze({ snapshot, handler, live, checks });
};

export default createSfuHealth;