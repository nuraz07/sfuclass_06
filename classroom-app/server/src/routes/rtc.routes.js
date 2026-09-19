// server/src/routes/rtc.routes.js
//
// HTTP surface of the connectivity domain (F8) on the api service. Mounted by app.js under /rtc:
//
//   POST /rtc/ice-servers   ICE configuration (TURN addresses + temporary credentials) for
//                           - purpose 'room':  refresh before expiry (core-client IceConfigProvider) and the
//                                              forced-relay retry (IceRecovery); the user must be admitted
//                                              to the room, and the room must be placed on a media node;
//                           - purpose 'probe': short-lived credentials for the pre-join network test
//                                              (ConnectivityProbe / NetworkCheckDialog), no room needed.
//                           The first ICE configuration of a session arrives in the room.join acknowledgement
//                           over the realtime service; this route never replaces that path.
//   GET  /rtc/regions       media regions the caller may use, each with its regional STUN endpoint, so the
//                           probe can measure RTT and send a region hint.
//
// Responses carry credentials, so they are never cached by anything (Cache-Control: no-store) and are never
// logged: request logging must not include response bodies of this router.
// Authentication, tenant resolution and error mapping are shared middleware (middleware/, errorHandler.js);
// this router only adds validation, the admission check and a dedicated rate limit.
//
// Dependencies (wired in server.js, same instances as in realtime.js where applicable):
//   iceServerService  rtc/IceServerService.js
//   icePolicy         rtc/IcePolicy.js
//   turnRegistry      rtc/TurnPoolRegistry.js
//   roomRegistry      classroom/RoomRegistry.js      get(roomId) → { region, … } | null
//   admission         { isAdmitted({ tenantId, roomId, userId }) → Promise<boolean> }  (waiting room state,
//                     written by classroom/ModerationControls.js in the realtime service)
//   iceConfig         config/ice.config.js
//   requireAuth       middleware setting req.auth = { userId, tenantId, deviceSessionId } from the access token
//   rateLimit         (name) => middleware, budgets in config/rateLimit.config.js ('rtc.iceServers', 'rtc.regions')
//
// Owner: F8 Real-Time Connectivity.

import { Router } from 'express';
import { z } from 'zod';

const ROOM_ID = z.string().min(1).max(128).regex(/^[A-Za-z0-9._:-]+$/);

const iceServersBody = z.discriminatedUnion('purpose', [
  z.object({
    purpose: z.literal('room'),
    roomId: ROOM_ID,
    regionHint: z.unknown().optional(),
    forceRelay: z.boolean().default(false),
  }).strict(),
  z.object({
    purpose: z.literal('probe'),
    regionHint: z.unknown().optional(),
  }).strict(),
]);

/**
 * @param {object} deps
 * @returns {import('express').Router}
 */
export function createRtcRouter({
  iceServerService, icePolicy, turnRegistry, roomRegistry, admission, iceConfig,
  requireAuth, rateLimit, logger = console,
}) {
  for (const [name, dep] of Object.entries({ iceServerService, icePolicy, turnRegistry, roomRegistry, admission, iceConfig, requireAuth, rateLimit })) {
    if (!dep) throw new TypeError(`createRtcRouter: ${name} is required`);
  }

  const router = Router();
  router.use(requireAuth);
  router.use(noStore);

  router.post('/ice-servers', rateLimit('rtc.iceServers'), handle(async (req, res) => {
    const auth = authOf(req);
    const parsed = iceServersBody.safeParse(req.body ?? {});
    if (!parsed.success) {
      throw httpError(400, 'RTC_BAD_REQUEST', parsed.error.issues.map((i) => `${i.path.join('.') || 'body'}: ${i.message}`).join('; '));
    }
    const body = parsed.data;

    let roomRegion;
    if (body.purpose === 'room') {
      const admitted = await admission.isAdmitted({ tenantId: auth.tenantId, roomId: body.roomId, userId: auth.userId });
      // Same answer for "not admitted" and "no such room": no room enumeration through this endpoint.
      if (!admitted) throw httpError(403, 'RTC_NOT_ADMITTED', 'not admitted to this room');
      const placement = await roomRegistry.get(body.roomId);
      if (!placement) throw httpError(409, 'RTC_ROOM_NOT_ACTIVE', 'room has no active media session');
      roomRegion = placement.region;
    }

    const config = await iceServerService.getIceConfig({
      purpose: body.purpose,
      tenantId: auth.tenantId,
      userId: auth.userId,
      deviceSessionId: auth.deviceSessionId,
      roomId: body.purpose === 'room' ? body.roomId : undefined,
      roomRegion,
      regionHint: body.regionHint,
      forceRelay: body.purpose === 'room' ? body.forceRelay : false,
      requestId: req.id ?? req.headers['x-request-id'],
    });
    res.status(200).json(config);
  }));

  router.get('/regions', rateLimit('rtc.regions'), handle(async (req, res) => {
    const auth = authOf(req);
    const policy = await icePolicy.resolve(auth.tenantId);
    const permitted = iceConfig.regions.filter((r) => policy.allowedRegions === null || policy.allowedRegions.includes(r));
    const live = new Set(await turnRegistry.liveRegions(permitted));
    const stunUsable = policy.iceTransportPolicy === 'all' && policy.transports.includes('udp');

    res.status(200).json({
      regions: permitted.map((region) => ({
        region,
        available: live.has(region),
        // Probe endpoint: gathering time of a server-reflexive candidate against it approximates RTT.
        stun: stunUsable ? `stun:${iceConfig.regionalHost(region)}:${iceConfig.ports.stun}` : null,
      })),
      defaultRegion: permitted.includes(iceConfig.defaultRegion) ? iceConfig.defaultRegion : permitted[0] ?? null,
      iceTransportPolicy: policy.iceTransportPolicy,
    });
  }));

  logger.info?.({ routes: ['POST /rtc/ice-servers', 'GET /rtc/regions'] }, 'rtc routes mounted');
  return router;
}

function authOf(req) {
  const auth = req.auth;
  if (!auth?.userId || !auth?.tenantId || !auth?.deviceSessionId) {
    // requireAuth ran but did not provide a device-bound session: treat as unauthenticated.
    throw httpError(401, 'UNAUTHENTICATED', 'device-bound session required');
  }
  return auth;
}

function noStore(_req, res, next) {
  res.set('Cache-Control', 'no-store, private');
  res.set('Pragma', 'no-cache');
  next();
}

/** Forwards async errors to errorHandler.js on Express 4 and 5 alike. */
function handle(fn) {
  return (req, res, next) => {
    Promise.resolve(fn(req, res, next)).catch(next);
  };
}

function httpError(status, code, message) {
  const err = new Error(message);
  err.status = status;
  err.code = code;
  err.expose = true;
  return err;
}