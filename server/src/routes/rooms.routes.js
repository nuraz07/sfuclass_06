/**
 * server/src/routes/rooms.routes.js
 *
 * Room to SFU node resolution for clients  (F1)
 *
 *   GET /rooms/:roomId/node[?avoid=nodeA,nodeB]
 *     →  { nodeId, wsUrl, expiresAt, region, draining }
 *
 * The contract packages/core-client/src/rtc/nodeResolver.ts validates
 * (SfuNodeSchema). The client asks this before it joins a room; the answer
 * comes from RoomRegistry, which assigns the least-loaded node on first ask
 * (SET NX, so two people opening a new lesson at once land on the same node).
 *
 * Why this exists next to route-resolve.routes.js: version 7 moves placement
 * into the room.join acknowledgement and turns the old public route into an
 * ops-only one under /internal. The client and the signalling handlers in this
 * codebase still follow the v6 flow — resolve the node, then join on it — so
 * this route keeps that flow working until both sides move to the v7 join
 * acknowledgement together. It reveals no addresses beyond what the client
 * connects to anyway, and only to an authenticated user.
 *
 * Node.js 22, ESM.
 */

import { Router } from 'express';

import { env, isProduction } from '../config/env.js';
import { resolveNode } from '../classroom/RoomRegistry.js';
import { logger } from '../observability/logger.js';

const log = logger.child({ component: 'rooms' });

/** Same alphabet PresenceService and the registry accept. */
const ROOM_ID = /^[A-Za-z0-9._:-]{1,128}$/;
const NODE_ID = /^[A-Za-z0-9._:-]{1,64}$/;

/**
 * How long a client may cache the answer. Short on purpose: nodeResolver caps
 * it at five minutes anyway, and a drain must reach clients within that.
 */
const ASSIGNMENT_TTL_MS = 5 * 60_000;

const error = (res, status, code, message, traceId) =>
  res.status(status).json({ error: { code, message, traceId: traceId ?? '' } });

/**
 * The socket origin the client should use for this node.
 *
 * Empty string means "the realtime service you are already configured for"
 * (VITE_WS_URL, or the page origin when that is empty). That is always right
 * for the node running inside this process — development runs api, signalling
 * and SFU in one process, and the browser reaches it through the Vite proxy or
 * a Codespaces forward, never at the node's own announced address.
 */
const wsUrlFor = (node) => {
  if (!isProduction && node.nodeId === env.SFU_NODE_ID) return '';
  return typeof node.wsUrl === 'string' ? node.wsUrl : '';
};

export const roomRoutes = Router();

roomRoutes.get('/:roomId/node', async (req, res, next) => {
  try {
    if (!req.user) {
      return error(res, 401, 'unauthenticated', 'Sign in to join a room.', req.traceId);
    }

    const { roomId } = req.params;
    if (!ROOM_ID.test(roomId)) {
      return error(res, 400, 'validation_failed', 'Invalid room id.', req.traceId);
    }

    const avoid = String(req.query.avoid ?? '')
      .split(',')
      .map((id) => id.trim())
      .filter((id) => NODE_ID.test(id))
      .slice(0, 10);

    let node;
    try {
      node = await resolveNode({ roomId, avoid });
    } catch (cause) {
      if (cause?.code === 'sfu_unavailable') {
        // nodeResolver retries a 503: a node may be registering right now.
        res.set('Retry-After', '2');
        return error(res, 503, 'sfu_unavailable', 'No media server is available right now.', req.traceId);
      }
      throw cause;
    }

    const body = {
      nodeId: node.nodeId,
      wsUrl: wsUrlFor(node),
      expiresAt: new Date(Date.now() + ASSIGNMENT_TTL_MS).toISOString(),
      region: node.region ?? env.MEDIA_REGION ?? env.AWS_REGION ?? null,
      draining: Boolean(node.draining),
    };

    log.debug({ roomId, nodeId: body.nodeId, assigned: Boolean(node.assigned) }, 'room node resolved');
    res.set('Cache-Control', 'no-store');
    return res.json(body);
  } catch (cause) {
    return next(cause);
  }
});

export default roomRoutes;
