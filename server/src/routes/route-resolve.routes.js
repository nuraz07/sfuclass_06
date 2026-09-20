/**
 * server/src/routes/route-resolve.routes.js
 *
 * Node placement lookup — internal and operational use only.  (F1, F8)
 *
 * v6 -> v7 correction: v6 exposed GET /rooms/:id/node publicly and shipped a
 * client-side nodeResolver.ts. Letting a client pick or even learn a node is
 * wrong in two ways: it turns placement into something an attacker can probe
 * and map (every SFU Elastic IP, enumerable by room id), and it creates a
 * second, contradictory path to a node next to the join acknowledgement.
 *
 * In v7 clients receive their placement exactly once, inside the room.join
 * acknowledgement, together with the ICE configuration. These routes remain
 * for operators and automation: incident response, the drain scripts, the
 * canary and route debugging. They are mounted under /internal, which
 * hostGuard and the ALB rules do not expose to the internet, and they
 * additionally require an operator identity.
 *
 * Every read is audited: knowing which node holds which tenant's room is
 * operational information about customers.
 *
 * Node.js 22, ESM.
 */

import { Router } from 'express';
import { timingSafeEqual } from 'node:crypto';

import { env } from '../config/env.js';
import { stateRedis } from '../db/redis.js';
import { roomRegistry } from '../classroom/RoomRegistry.js';
import { auditLog } from '../security/auditLog.js';
import { rateLimit } from '../middleware/rateLimit.js';
import { logger } from '../observability/logger.js';

const log = logger.child({ component: 'route-resolve' });

export const routeResolveRouter = Router();

/* -------------------------------------------------------------------------- */
/* Access control                                                              */
/* -------------------------------------------------------------------------- */

/**
 * Two accepted identities:
 *   - an authenticated user whose role includes 'ops' (a human on call), or
 *   - a service token, for the lifecycle Lambda, the drain scripts and the
 *     Synthetics canary, which have no user session.
 *
 * Anything else gets a 404, not a 403: an unauthenticated caller should not be
 * able to learn that this surface exists.
 */
function requireOperator(req, res, next) {
  const token = req.get('x-internal-token');

  if (token && env.INTERNAL_OPS_TOKEN && safeEqual(token, env.INTERNAL_OPS_TOKEN)) {
    req.operator = { kind: 'service', id: req.get('x-internal-caller') ?? 'unknown-service' };
    return next();
  }

  if (req.user?.roles?.includes('ops')) {
    req.operator = { kind: 'user', id: req.user.id };
    return next();
  }

  log.warn(
    { path: req.path, ip: req.ip, hasToken: Boolean(token) },
    'unauthorised internal placement lookup',
  );
  return res.status(404).json({
    error: { code: 'not_found', message: 'Not found', traceId: req.traceId },
  });
}

function safeEqual(a, b) {
  const left = Buffer.from(a);
  const right = Buffer.from(b);
  if (left.length !== right.length) return false;
  return timingSafeEqual(left, right);
}

routeResolveRouter.use(requireOperator);
routeResolveRouter.use(
  rateLimit({ key: 'internal-route-resolve', windowMs: 60_000, max: 120, by: 'operator' }),
);

/* -------------------------------------------------------------------------- */
/* Routes                                                                      */
/* -------------------------------------------------------------------------- */

/**
 * GET /internal/rooms/:roomId/node
 *
 * Where a room currently lives. Used by ops/runbooks/sfu-incident.md to find
 * the node to drain, and by the drain scripts to confirm a room moved.
 */
routeResolveRouter.get('/rooms/:roomId/node', async (req, res) => {
  const { roomId } = req.params;

  const placement = await roomRegistry.get(roomId);
  if (!placement) {
    return res.status(404).json({
      error: { code: 'room_not_placed', message: 'No live placement for this room', traceId: req.traceId },
    });
  }

  const [nodeAlive, draining] = await Promise.all([
    stateRedis.exists(`media:sfu:${placement.region}:${placement.nodeId}`),
    stateRedis.exists(`media:drain:${placement.nodeId}`),
  ]);

  await auditLog.record({
    action: 'ops.placement.read',
    actor: req.operator,
    target: { roomId, nodeId: placement.nodeId, region: placement.region },
    traceId: req.traceId,
  });

  return res.json({
    roomId,
    region: placement.region,
    nodeId: placement.nodeId,
    // Private control address. It is only reachable from the realtime security
    // group, so this is a debugging aid, not a way in.
    controlAddress: placement.controlAddress,
    publicAddress: placement.publicAddress ?? null,
    heartbeatAlive: nodeAlive === 1,
    draining: draining === 1,
    placedAt: placement.placedAt ?? null,
  });
});

/**
 * GET /internal/regions/:region/nodes
 *
 * Live SFU and TURN registries for one region — what RoomPlacementService and
 * TurnPoolSelector see right now. The single most useful view during an ICE
 * or relay incident.
 */
routeResolveRouter.get('/regions/:region/nodes', async (req, res) => {
  const { region } = req.params;
  const kind = req.query.kind === 'turn' ? 'turn' : 'sfu';

  const nodes = await scanRegistry(`media:${kind}:${region}:*`);

  await auditLog.record({
    action: 'ops.registry.read',
    actor: req.operator,
    target: { region, kind },
    traceId: req.traceId,
  });

  return res.json({
    region,
    kind,
    count: nodes.length,
    nodes: nodes.sort((a, b) => (a.nodeId ?? '').localeCompare(b.nodeId ?? '')),
  });
});

/**
 * GET /internal/rooms/:roomId/route
 *
 * The full path a participant would take today: region, node, announced
 * address and ports, and the TURN nodes the selector would hand out. This is
 * the answer to "why is this class relayed?" without touching a client.
 */
routeResolveRouter.get('/rooms/:roomId/route', async (req, res) => {
  const { roomId } = req.params;

  const placement = await roomRegistry.get(roomId);
  if (!placement) {
    return res.status(404).json({
      error: { code: 'room_not_placed', message: 'No live placement for this room', traceId: req.traceId },
    });
  }

  const [sfuNode] = await scanRegistry(`media:sfu:${placement.region}:${placement.nodeId}`);
  const turnNodes = await scanRegistry(`media:turn:${placement.region}:*`);

  await auditLog.record({
    action: 'ops.route.read',
    actor: req.operator,
    target: { roomId, region: placement.region },
    traceId: req.traceId,
  });

  return res.json({
    roomId,
    region: placement.region,
    sfu: sfuNode
      ? {
          nodeId: sfuNode.nodeId,
          publicIpv4: sfuNode.publicIpv4,
          publicIpv6: sfuNode.publicIpv6 ?? null,
          ports: sfuNode.ports,
          loadScore: sfuNode.loadScore,
          draining: sfuNode.draining ?? false,
        }
      : null,
    turnCandidates: turnNodes
      .filter((n) => !n.draining)
      .map((n) => ({ node: n.node ?? n.nodeId, allocations: n.allocations, relayedMbps: n.relayedMbps })),
    note: 'Clients receive placement in the room.join acknowledgement; this route is ops-only.',
  });
});

/**
 * The removed public route. Kept as an explicit 410 for one release cycle so
 * an old mobile build gets a clear answer instead of a silent 404, and so the
 * removal is visible in the access logs.
 */
export const legacyPublicNodeRoute = Router();
legacyPublicNodeRoute.get('/rooms/:roomId/node', (req, res) => {
  res.status(410).json({
    error: {
      code: 'gone',
      message: 'Node placement is returned in the room.join acknowledgement.',
      traceId: req.traceId,
    },
  });
});

/* -------------------------------------------------------------------------- */
/* Helpers                                                                     */
/* -------------------------------------------------------------------------- */

/**
 * SCAN, never KEYS: the state cluster serves BullMQ and the seat reservation
 * Lua at the same time, and KEYS blocks it.
 */
async function scanRegistry(pattern) {
  const found = [];
  let cursor = '0';

  do {
    const [next, keys] = await stateRedis.scan(cursor, 'MATCH', pattern, 'COUNT', 200);
    cursor = next;
    if (keys.length === 0) continue;

    const values = await stateRedis.mget(keys);
    for (const [i, raw] of values.entries()) {
      if (!raw) continue;
      try {
        found.push({ key: keys[i], ...JSON.parse(raw) });
      } catch {
        log.warn({ key: keys[i] }, 'registry entry is not valid JSON');
      }
    }
  } while (cursor !== '0');

  return found;
}

export default routeResolveRouter;