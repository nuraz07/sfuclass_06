/**
 * scheduledRooms.routes — create, plan and enter your own rooms  (Rooms)
 *
 * Mounted under /scheduled-rooms (app.js). The room itself is still joined
 * through the classroom socket at /rooms/<code>; this is everything around
 * it. Rules: rooms/roomRules.js; storage and state: rooms/ScheduledRooms.js.
 *
 *   GET    /config                     limits and defaults for the form
 *   POST   /preview                    dates a form would create, and clashes
 *   POST   /                           create (one room, or one per date of a series)
 *   GET    /mine?when=upcoming|past    rooms I host, co-host or am invited to
 *   GET    /:code                      the room as I may see it, with my entry state
 *   GET    /:code/gate                 may I enter now? (the classroom page asks first)
 *   PATCH  /:code                      edit this date            host
 *   POST   /:code/cancel               { scope, reason }         host
 *   POST   /:code/extend               { minutes }               host, co-host
 *   POST   /:code/end                  end now for everyone      host, co-host
 *   POST   /:code/knock                ask to be let in
 *   DELETE /:code/knock
 *   GET    /:code/knocks               who is asking             host, co-host
 *   POST   /:code/admit                { userIds? } empty = all  host, co-host
 *   POST   /:code/deny                 { userId }                host, co-host
 *   POST   /:code/waitlist             wait for the next free seat
 *   DELETE /:code/waitlist
 *   GET    /:code/qr                   the link as a QR code
 *   GET    /:code/calendar.ics         the room for any calendar
 */

import { Router } from 'express';
import { z } from 'zod';

import * as Rooms from '../rooms/ScheduledRooms.js';
import * as Rules from '../rooms/roomRules.js';
import { rateLimit } from '../middleware/rateLimit.js';
import { route, validate, requireAuth, tenantOf, notFound, badRequest, forbidden, conflict } from './_helpers.js';

const router = Router();
router.use(requireAuth);

/** Errors the services raise with a code, as the HTTP answers clients understand. */
const asHttp = (fn) => async (req, res) => {
  try {
    return await fn(req, res);
  } catch (error) {
    if (error?.name === 'ScheduleError') {
      if (error.code === 'HOST_CONFLICT') throw conflict(error.message, error.details);
      throw badRequest(error.message);
    }
    switch (error?.code) {
      case 'validation_failed':
        throw badRequest(error.message);
      case 'forbidden':
        throw forbidden(error.message);
      case 'not_found':
        throw notFound(error.message);
      case 'conflict':
        throw conflict(error.message, error.details);
      default:
        throw error;
    }
  }
};

const handle = (fn) => route(asHttp(fn));

/** zod issues as one readable sentence. */
const parse = (schema, body) => {
  const parsed = schema.safeParse(body ?? {});
  if (!parsed.success) {
    const issue = parsed.error.issues[0];
    const where = issue?.path?.length ? `${issue.path.join('.')}: ` : '';
    throw badRequest(`${where}${issue?.message ?? 'invalid input'}`);
  }
  return parsed.data;
};

const codeParam = z.object({ code: z.string().regex(Rules.ROOM_CODE, 'not a room code') });

/** The room, or 404 — also when it exists but is not shared with this person. */
const loadRoom = async (req) => {
  const room = await Rooms.findByCode(req.params.code);
  if (!room) throw notFound('No such room');
  const relation = await Rooms.relationFor(room, { userId: req.user.id, tenantId: tenantOf(req) });
  if (!relation) throw notFound('No such room, or it is not shared with you.');
  return { room, relation };
};

const requireModerator = async (req) => {
  const loaded = await loadRoom(req);
  if (!Rules.isModerator(loaded.relation)) throw forbidden('Only the host and co-hosts can do that.');
  return loaded;
};

const requireHost = async (req) => {
  const loaded = await loadRoom(req);
  if (loaded.relation !== 'host') throw forbidden('Only the host can change this room.');
  return loaded;
};

const detail = (req, room) => Rooms.detailFor({ room, userId: req.user.id, tenantId: tenantOf(req) });

/* ------------------------------------------------------------------ *
 * Planning
 * ------------------------------------------------------------------ */

router.get(
  '/config',
  route(async () => ({
    earlyEntry: Rules.EARLY_ENTRY,
    duration: Rules.DURATION,
    capacity: Rules.CAPACITY,
    lateJoinOptions: Rules.LATE_JOIN_OPTIONS,
    extendOptions: Rules.EXTEND_MINUTES,
    hostEarlyMinutes: Rules.HOST_EARLY_MIN,
    limits: { invitees: Rules.MAX_INVITEES, cohosts: Rules.MAX_COHOSTS },
  })),
);

const previewBody = z
  .object({
    startsAtLocal: Rules.CreateRoomSchema.shape.startsAtLocal,
    durationMinutes: Rules.CreateRoomSchema.shape.durationMinutes,
    timeZone: z.string().min(1).max(64),
    recurrence: Rules.CreateRoomSchema.shape.recurrence,
    excludeCode: z.string().regex(Rules.ROOM_CODE).optional(),
  })
  .strict();

router.post(
  '/preview',
  rateLimit({ key: 'rooms:preview', points: 120, durationSec: 60, by: ['user'] }),
  handle(async (req) => {
    const input = parse(previewBody, req.body);
    const exclude = input.excludeCode ? await Rooms.findByCode(input.excludeCode) : null;
    return Rooms.preview({
      tenantId: tenantOf(req),
      hostId: req.user.id,
      startsAtLocal: input.startsAtLocal,
      durationMinutes: input.durationMinutes,
      timeZone: input.timeZone,
      recurrence: input.recurrence ?? null,
      excludeSessionIds: exclude && exclude.hostId === req.user.id ? [exclude.id] : [],
    });
  }),
);

router.post(
  '/',
  rateLimit({ key: 'rooms:create', points: 30, durationSec: 3600, by: ['user'] }),
  handle(async (req, res) => {
    const input = parse(Rules.CreateRoomSchema, req.body);
    const created = await Rooms.create({ input, tenantId: tenantOf(req), hostId: req.user.id });
    res.status(201).set('Location', `/scheduled-rooms/${created[0].code}`);
    return {
      room: await detail(req, created[0]),
      occurrences: created.map((room) => ({ code: room.code, startsAt: room.startsAt, endsAt: room.endsAt })),
    };
  }),
);

router.get(
  '/mine',
  validate({ query: z.object({ when: z.enum(['upcoming', 'past']).optional() }).passthrough() }),
  route(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    return Rooms.listMine({ userId: req.user.id, when: req.query.when ?? 'upcoming' });
  }),
);

/* ------------------------------------------------------------------ *
 * One room
 * ------------------------------------------------------------------ */

router.get(
  '/:code',
  validate({ params: codeParam }),
  handle(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    const { room } = await loadRoom(req);
    return detail(req, room);
  }),
);

/** Asked by the classroom page before it opens a socket. Not scheduled: enter as before. */
router.get(
  '/:code/gate',
  handle(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    if (!Rules.isRoomCode(req.params.code)) return { scheduled: false, canEnter: true };
    const room = await Rooms.findByCode(req.params.code);
    if (!room) return { scheduled: false, canEnter: true };
    const { decision } = await Rooms.decide({ room, userId: req.user.id, tenantId: tenantOf(req) });
    return { scheduled: true, canEnter: decision.allowed, reason: decision.code, message: decision.message };
  }),
);

router.patch(
  '/:code',
  validate({ params: codeParam }),
  handle(async (req) => {
    const { room } = await requireHost(req);
    const patch = parse(Rules.UpdateRoomSchema, req.body);
    const updated = await Rooms.update({ room, patch, actorId: req.user.id });
    return detail(req, updated);
  }),
);

router.post(
  '/:code/cancel',
  validate({
    params: codeParam,
    body: z.object({ scope: z.enum(['this', 'following']).default('this'), reason: z.string().trim().max(300).nullish() }).default({}),
  }),
  handle(async (req) => {
    const { room } = await requireHost(req);
    return Rooms.cancel({ room, scope: req.body.scope, reason: req.body.reason ?? null, actorId: req.user.id });
  }),
);

router.post(
  '/:code/extend',
  validate({ params: codeParam, body: z.object({ minutes: z.number().int() }) }),
  handle(async (req) => {
    const { room } = await requireModerator(req);
    return Rooms.extend({ room, minutes: req.body.minutes });
  }),
);

router.post(
  '/:code/end',
  validate({ params: codeParam }),
  handle(async (req) => {
    const { room } = await requireModerator(req);
    return Rooms.end({ room });
  }),
);

/* ------------------------------------------------------------------ *
 * Lobby
 * ------------------------------------------------------------------ */

router.post(
  '/:code/knock',
  rateLimit({ key: 'rooms:knock', points: 20, durationSec: 300, by: ['user'] }),
  validate({ params: codeParam }),
  handle(async (req) => {
    const { room, relation } = await loadRoom(req);
    if (!room.approval || Rules.isModerator(relation)) return detail(req, room);
    const phase = Rules.phaseOf(room);
    if (phase !== 'doors-open' && phase !== 'live') throw badRequest('The doors are not open yet.');
    await Rooms.knock({ room, user: { userId: req.user.id, displayName: req.user.displayName } });
    return detail(req, room);
  }),
);

router.delete(
  '/:code/knock',
  validate({ params: codeParam }),
  handle(async (req) => {
    const { room } = await loadRoom(req);
    await Rooms.withdrawKnock(room, req.user.id);
    return detail(req, room);
  }),
);

router.get(
  '/:code/knocks',
  validate({ params: codeParam }),
  handle(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    const { room } = await requireModerator(req);
    return { items: await Rooms.listKnocks(room) };
  }),
);

router.post(
  '/:code/admit',
  validate({ params: codeParam, body: z.object({ userIds: z.array(z.string().uuid()).max(300).default([]) }).default({}) }),
  handle(async (req) => {
    const { room } = await requireModerator(req);
    return Rooms.admit({ room, userIds: req.body.userIds });
  }),
);

router.post(
  '/:code/deny',
  validate({ params: codeParam, body: z.object({ userId: z.string().uuid() }) }),
  handle(async (req) => {
    const { room } = await requireModerator(req);
    return Rooms.deny({ room, userId: req.body.userId });
  }),
);

router.post(
  '/:code/waitlist',
  validate({ params: codeParam }),
  handle(async (req) => {
    const { room } = await loadRoom(req);
    await Rooms.joinWaitlist({ room, userId: req.user.id });
    return detail(req, room);
  }),
);

router.delete(
  '/:code/waitlist',
  validate({ params: codeParam }),
  handle(async (req) => {
    const { room } = await loadRoom(req);
    await Rooms.leaveWaitlist({ room, userId: req.user.id });
    return detail(req, room);
  }),
);

/* ------------------------------------------------------------------ *
 * Sharing
 * ------------------------------------------------------------------ */

/** The link as a QR code. Uses qrcode (installed with Settings Phase C); 404 without it. */
router.get(
  '/:code/qr',
  validate({ params: codeParam }),
  handle(async (req, res) => {
    const { room } = await loadRoom(req);
    let QRCode;
    try {
      const imported = await import('qrcode');
      QRCode = imported.default ?? imported;
    } catch {
      throw notFound('QR codes are not available on this server.');
    }
    res.set('Cache-Control', 'private, max-age=3600');
    return { dataUrl: await QRCode.toDataURL(Rooms.roomUrl(room.code), { margin: 1, width: 264, errorCorrectionLevel: 'M' }) };
  }),
);

/* ------------------------------------------------------------------ *
 * Calendar
 * ------------------------------------------------------------------ */

router.get(
  '/:code/calendar.ics',
  validate({ params: codeParam }),
  // Not route(): the answer is a file, not JSON. Errors still go to the error handler.
  (req, res, next) =>
    asHttp(async () => {
      const { room } = await loadRoom(req);
      res.set('Content-Type', 'text/calendar; charset=utf-8');
      res.set('Content-Disposition', `attachment; filename="${room.code}.ics"`);
      res.set('Cache-Control', 'no-store');
      res.send(Rules.icsFor({ room, url: Rooms.roomUrl(room.code) }));
    })(req, res).catch(next),
);

export default router;
