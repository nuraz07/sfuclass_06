/**
 * hub.routes — the community  (Community, part 1)
 *
 * Mounted under /hub (app.js). The older /community routes stay where they
 * are, untouched. Everything here is for the signed-in person, inside their
 * organisation; rules in hub/hubRules.js, storage in hub/HubService.js.
 *
 *   GET    /home                               my spaces, recent activity, my threads
 *   GET    /questions?filter=&sort=             questions across my spaces
 *   GET    /spaces?scope=mine|discover&q=&kind= spaces
 *   POST   /spaces                              create
 *   GET    /spaces/:id                          one space, with what I may do
 *   PATCH  /spaces/:id                          change              moderators
 *   POST   /spaces/:id/archive                  archive             owner
 *   POST   /spaces/:id/join  { answer? }        join, or ask to join
 *   POST   /spaces/:id/leave
 *   GET    /spaces/:id/requests                 open requests       moderators
 *   POST   /spaces/:id/requests/:userId         { approve }         moderators
 *   POST   /spaces/:id/invite  { userIds }      add people          moderators
 *   GET    /spaces/:id/members                  names and roles only
 *   PATCH  /spaces/:id/members/:userId          { role?, timeoutMinutes? }
 *   DELETE /spaces/:id/members/:userId          remove              moderators
 *   GET    /spaces/:id/threads?filter=
 *   POST   /spaces/:id/threads                  start a discussion or ask a question
 *   GET    /threads/:id
 *   POST   /threads/:id/replies
 *   POST   /threads/:id/answer  { postId|null } mark the answer     asker, moderators
 *   POST   /threads/:id/metoo                   "I have the same question" (toggle)
 *   PATCH  /threads/:id  { pinned?, locked? }                       moderators
 *   DELETE /threads/:id                                              author, moderators
 *   DELETE /posts/:id                                                author, moderators
 *   POST   /spaces/:id/reports                  report a thread, reply or person
 *   GET    /spaces/:id/reports                                      moderators
 *   POST   /spaces/:id/reports/:reportId  { action: remove|dismiss } moderators
 *
 * Part 2 (hub/HubExtras.js):
 *   GET    /spaces/:id/cards?q=              knowledge cards
 *   POST   /spaces/:id/cards                 { title, body, postId? }       moderators
 *   PATCH  /cards/:id  DELETE /cards/:id                                    moderators
 *   GET    /spaces/:id/materials             links, pinned first
 *   POST   /spaces/:id/materials             { title, url, note?, pinned? } moderators
 *   PATCH  /materials/:id { pinned }  DELETE /materials/:id                 moderators
 *   GET    /spaces/:id/chat?after=           newest messages, or those after a moment
 *   POST   /spaces/:id/chat                  { body }
 *   DELETE /chat/:id                                                         author, moderators
 *   GET    /spaces/:id/rooms                 the space's upcoming and running rooms
 *   POST   /spaces/:id/rooms/drop-in         open a drop-in room now (or the one already open)
 */

import { Router } from 'express';
import { z } from 'zod';

import * as Hub from '../hub/HubService.js';
import * as Extras from '../hub/HubExtras.js';
import * as Rules from '../hub/hubRules.js';
import { rateLimit } from '../middleware/rateLimit.js';
import { route, validate, requireAuth, notFound, badRequest, forbidden, conflict } from './_helpers.js';

const router = Router();
router.use(requireAuth);

const asHttp = (fn) => async (req, res) => {
  try {
    return await fn(req, res);
  } catch (error) {
    switch (error?.code) {
      case 'validation_failed':
        throw badRequest(error.message);
      case 'forbidden':
        throw forbidden(error.message);
      case 'not_found':
        throw notFound(error.message);
      case 'conflict':
        throw conflict(error.message);
      default:
        throw error;
    }
  }
};

/** Resolves the viewer once per request; every handler gets it. */
const handle = (fn) =>
  route(
    asHttp(async (req, res) => {
      const viewer = await Hub.viewerOf(req.user.id);
      return fn(req, res, viewer);
    }),
  );

const parse = (schema, body) => {
  const parsed = schema.safeParse(body ?? {});
  if (!parsed.success) {
    const issue = parsed.error.issues[0];
    throw badRequest(`${issue?.path?.length ? `${issue.path.join('.')}: ` : ''}${issue?.message ?? 'invalid input'}`);
  }
  return parsed.data;
};

const id = z.string().uuid();
const spaceParam = z.object({ id });
const writeLimit = rateLimit({ key: 'hub:write', points: 60, durationSec: 600, by: ['user'] });

/* ---------------------------------------------------------------- overview */

router.get('/home', handle((req, res, viewer) => Hub.home({ viewer })));

router.get(
  '/questions',
  validate({ query: z.object({ filter: z.enum(['unanswered', 'answered', 'all']).optional(), sort: z.enum(['metoo', 'new']).optional() }).passthrough() }),
  handle((req, res, viewer) => Hub.questions({ viewer, filter: req.query.filter ?? 'unanswered', sort: req.query.sort ?? 'metoo' })),
);

/* ---------------------------------------------------------------- spaces */

router.get(
  '/spaces',
  validate({
    query: z
      .object({ scope: z.enum(['mine', 'discover']).optional(), q: z.string().trim().max(60).optional(), kind: z.enum(Rules.KINDS).optional() })
      .passthrough(),
  }),
  handle((req, res, viewer) =>
    Hub.listSpaces({ viewer, scope: req.query.scope ?? 'mine', q: req.query.q || null, kind: req.query.kind ?? null }),
  ),
);

router.post(
  '/spaces',
  rateLimit({ key: 'hub:create-space', points: 10, durationSec: 3600, by: ['user'] }),
  handle(async (req, res, viewer) => {
    res.status(201);
    return Hub.createSpace({ viewer, input: parse(Rules.CreateSpaceSchema, req.body) });
  }),
);

router.get('/spaces/:id', validate({ params: spaceParam }), handle((req, res, viewer) => Hub.getSpace({ viewer, spaceId: req.params.id })));

router.patch(
  '/spaces/:id',
  validate({ params: spaceParam }),
  handle((req, res, viewer) => Hub.updateSpace({ viewer, spaceId: req.params.id, patch: parse(Rules.UpdateSpaceSchema, req.body) })),
);

router.post('/spaces/:id/archive', validate({ params: spaceParam }), handle((req, res, viewer) => Hub.archiveSpace({ viewer, spaceId: req.params.id })));

router.post(
  '/spaces/:id/join',
  writeLimit,
  validate({ params: spaceParam, body: z.object({ answer: z.string().trim().max(500).nullish() }).default({}) }),
  handle((req, res, viewer) => Hub.join({ viewer, spaceId: req.params.id, answer: req.body.answer ?? null })),
);

router.post('/spaces/:id/leave', validate({ params: spaceParam }), handle((req, res, viewer) => Hub.leave({ viewer, spaceId: req.params.id })));

router.get('/spaces/:id/requests', validate({ params: spaceParam }), handle((req, res, viewer) => Hub.listRequests({ viewer, spaceId: req.params.id })));

router.post(
  '/spaces/:id/requests/:userId',
  validate({ params: z.object({ id, userId: id }), body: z.object({ approve: z.boolean() }) }),
  handle((req, res, viewer) => Hub.decideRequest({ viewer, spaceId: req.params.id, userId: req.params.userId, approve: req.body.approve })),
);

router.post(
  '/spaces/:id/invite',
  writeLimit,
  validate({ params: spaceParam, body: z.object({ userIds: z.array(id).min(1).max(100) }) }),
  handle((req, res, viewer) => Hub.invite({ viewer, spaceId: req.params.id, userIds: req.body.userIds })),
);

router.get('/spaces/:id/members', validate({ params: spaceParam }), handle((req, res, viewer) => Hub.listMembers({ viewer, spaceId: req.params.id })));

router.patch(
  '/spaces/:id/members/:userId',
  validate({
    params: z.object({ id, userId: id }),
    body: z.object({ role: z.enum(['owner', 'moderator', 'member']).optional(), timeoutMinutes: z.number().int().min(0).max(10080).optional() }),
  }),
  handle((req, res, viewer) =>
    Hub.updateMember({ viewer, spaceId: req.params.id, userId: req.params.userId, role: req.body.role, timeoutMinutes: req.body.timeoutMinutes }),
  ),
);

router.delete(
  '/spaces/:id/members/:userId',
  validate({ params: z.object({ id, userId: id }) }),
  handle((req, res, viewer) => Hub.removeMember({ viewer, spaceId: req.params.id, userId: req.params.userId })),
);

/* ---------------------------------------------------------------- threads */

router.get(
  '/spaces/:id/threads',
  validate({ params: spaceParam, query: z.object({ filter: z.enum(['all', 'questions', 'unanswered']).optional() }).passthrough() }),
  handle((req, res, viewer) => Hub.listThreads({ viewer, spaceId: req.params.id, filter: req.query.filter ?? 'all' })),
);

router.post(
  '/spaces/:id/threads',
  writeLimit,
  validate({ params: spaceParam }),
  handle(async (req, res, viewer) => {
    res.status(201);
    return Hub.createThread({ viewer, spaceId: req.params.id, input: parse(Rules.CreateThreadSchema, req.body) });
  }),
);

router.get('/threads/:id', validate({ params: spaceParam }), handle((req, res, viewer) => Hub.getThread({ viewer, threadId: req.params.id })));

router.post(
  '/threads/:id/replies',
  writeLimit,
  validate({ params: spaceParam }),
  handle(async (req, res, viewer) => {
    res.status(201);
    return Hub.reply({ viewer, threadId: req.params.id, input: parse(Rules.ReplySchema, req.body) });
  }),
);

router.post(
  '/threads/:id/answer',
  validate({ params: spaceParam, body: z.object({ postId: id.nullable() }) }),
  handle((req, res, viewer) => Hub.markAnswer({ viewer, threadId: req.params.id, postId: req.body.postId })),
);

router.post('/threads/:id/metoo', validate({ params: spaceParam }), handle((req, res, viewer) => Hub.toggleMetoo({ viewer, threadId: req.params.id })));

router.patch(
  '/threads/:id',
  validate({ params: spaceParam, body: z.object({ pinned: z.boolean().optional(), locked: z.boolean().optional() }) }),
  handle((req, res, viewer) => Hub.moderateThread({ viewer, threadId: req.params.id, pinned: req.body.pinned, locked: req.body.locked })),
);

router.delete('/threads/:id', validate({ params: spaceParam }), handle((req, res, viewer) => Hub.removeThread({ viewer, threadId: req.params.id })));

router.delete('/posts/:id', validate({ params: spaceParam }), handle((req, res, viewer) => Hub.removePost({ viewer, postId: req.params.id })));

/* ---------------------------------------------------------------- reports */

router.post(
  '/spaces/:id/reports',
  rateLimit({ key: 'hub:report', points: 20, durationSec: 3600, by: ['user'] }),
  validate({ params: spaceParam }),
  handle((req, res, viewer) => Hub.report({ viewer, spaceId: req.params.id, input: parse(Rules.ReportSchema, req.body) })),
);

router.get('/spaces/:id/reports', validate({ params: spaceParam }), handle((req, res, viewer) => Hub.listReports({ viewer, spaceId: req.params.id })));

router.post(
  '/spaces/:id/reports/:reportId',
  validate({ params: z.object({ id, reportId: id }), body: z.object({ action: z.enum(['remove', 'dismiss']) }) }),
  handle((req, res, viewer) => Hub.resolveReport({ viewer, spaceId: req.params.id, reportId: req.params.reportId, action: req.body.action })),
);

/* ---------------------------------------------------------------- part 2 */

router.get(
  '/spaces/:id/cards',
  validate({ params: spaceParam, query: z.object({ q: z.string().trim().max(80).optional() }).passthrough() }),
  handle((req, res, viewer) => Extras.listCards({ viewer, spaceId: req.params.id, q: req.query.q || null })),
);

router.post(
  '/spaces/:id/cards',
  writeLimit,
  validate({ params: spaceParam }),
  handle(async (req, res, viewer) => {
    res.status(201);
    return Extras.createCard({ viewer, spaceId: req.params.id, input: parse(Rules.CardSchema, req.body) });
  }),
);

router.patch(
  '/cards/:id',
  validate({ params: spaceParam }),
  handle((req, res, viewer) => Extras.updateCard({ viewer, cardId: req.params.id, patch: parse(Rules.UpdateCardSchema, req.body) })),
);

router.delete('/cards/:id', validate({ params: spaceParam }), handle((req, res, viewer) => Extras.removeCard({ viewer, cardId: req.params.id })));

router.get('/spaces/:id/materials', validate({ params: spaceParam }), handle((req, res, viewer) => Extras.listMaterials({ viewer, spaceId: req.params.id })));

router.post(
  '/spaces/:id/materials',
  writeLimit,
  validate({ params: spaceParam }),
  handle(async (req, res, viewer) => {
    res.status(201);
    return Extras.addMaterial({ viewer, spaceId: req.params.id, input: parse(Rules.MaterialSchema, req.body) });
  }),
);

router.patch(
  '/materials/:id',
  validate({ params: spaceParam, body: z.object({ pinned: z.boolean() }) }),
  handle((req, res, viewer) => Extras.pinMaterial({ viewer, materialId: req.params.id, pinned: req.body.pinned })),
);

router.delete('/materials/:id', validate({ params: spaceParam }), handle((req, res, viewer) => Extras.removeMaterial({ viewer, materialId: req.params.id })));

router.get(
  '/spaces/:id/chat',
  validate({ params: spaceParam, query: z.object({ after: z.string().datetime({ offset: true }).optional() }).passthrough() }),
  handle((req, res, viewer) => Extras.listMessages({ viewer, spaceId: req.params.id, after: req.query.after ?? null })),
);

router.post(
  '/spaces/:id/chat',
  rateLimit({ key: 'hub:chat', points: 30, durationSec: 60, by: ['user'] }),
  validate({ params: spaceParam }),
  handle(async (req, res, viewer) => {
    res.status(201);
    return Extras.sendMessage({ viewer, spaceId: req.params.id, input: parse(Rules.ChatMessageSchema, req.body) });
  }),
);

router.delete('/chat/:id', validate({ params: spaceParam }), handle((req, res, viewer) => Extras.removeMessage({ viewer, messageId: req.params.id })));

router.get('/spaces/:id/rooms', validate({ params: spaceParam }), handle((req, res, viewer) => Extras.listRooms({ viewer, spaceId: req.params.id })));

router.post(
  '/spaces/:id/rooms/drop-in',
  rateLimit({ key: 'hub:drop-in', points: 6, durationSec: 3600, by: ['user'] }),
  validate({ params: spaceParam }),
  handle(async (req, res, viewer) => {
    const result = await Extras.startDropIn({ viewer, spaceId: req.params.id });
    res.status(result.started ? 201 : 200);
    return result;
  }),
);

export default router;
