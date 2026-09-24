/**
 * messaging.routes — conversations · channels · messages (F6)
 *
 * Mounted under /messaging (app.js), so every path here is relative to it.
 *
 * `POST /conversations/direct` is a single idempotent open-or-create: the same
 * pair of people always resolves to the same conversation. The person who
 * opens it sees it at once; the other person sees it when the first message
 * arrives. `roomId` in the body tells the permission check that both are in
 * the same live lesson, which counts as shared context.
 *
 * Per-person state has its own verbs: PATCH mutes (with an optional end time),
 * DELETE removes the conversation for the caller only. Nobody can delete a
 * conversation for someone else.
 *
 * History is keyset-paginated. Sending is at-least-once from the client's
 * side; `clientId` is the dedupe key.
 */

import { Router } from 'express';
import { z } from 'zod';
import { ApiError } from '@classroom/contracts';

import * as ConversationService from '../messaging/ConversationService.js';
import * as DirectMessageService from '../messaging/DirectMessageService.js';
import * as PublicChatService from '../messaging/PublicChatService.js';
import * as ChatAttachmentService from '../messaging/ChatAttachmentService.js';
import * as ChatSearchService from '../messaging/ChatSearchService.js';
import * as UnreadService from '../messaging/UnreadService.js';
import * as ChatModerationService from '../messaging/ChatModerationService.js';
import * as Participant from '../messaging/models/Participant.js';
import { env } from '../config/env.js';
import { rateLimit } from '../middleware/rateLimit.js';
import { route, validate, requireAuth, tenantOf, paging, q, notFound, forbidden, badRequest } from './_helpers.js';

const router = Router();
router.use(requireAuth);

const idParam = z.object({ id: z.string().uuid() });
const pageQuery = z.object({
  cursor: z.string().optional(),
  limit: z.coerce.number().int().min(1).max(100).optional(),
  direction: z.enum(['forward', 'backward']).optional(),
  order: z.enum(['asc', 'desc']).optional(),
});
const isoDateTime = z.iso.datetime({ offset: true });

/**
 * Domain refusals carry their own codes (dm_not_allowed, blocked_by_user, …).
 * They leave this API as the plain HTTP answers every client understands.
 */
const asHttpError = (error) => {
  if (!ApiError.is(error)) return error;
  const detail = error.detail ?? error.message;
  switch (error.code) {
    case 'dm_not_allowed':
    case 'blocked_by_user':
    case 'forbidden':
      return forbidden(detail);
    case 'not_found':
      return notFound(detail);
    case 'validation_failed':
      return badRequest(detail);
    default:
      return error;
  }
};

const mapped = (fn) => async (req, res) => {
  try {
    return await fn(req, res);
  } catch (error) {
    throw asHttpError(error);
  }
};

/* ------------------------------------------------------------------ *
 * Conversations
 * ------------------------------------------------------------------ */

router.get(
  '/conversations',
  validate({ query: pageQuery }),
  route(
    mapped(async (req) =>
      ConversationService.list({
        userId: req.user.id,
        cursor: q(req).cursor ?? null,
        limit: q(req).limit ?? 25,
      }),
    ),
  ),
);

/**
 * Open or create. 201 when it was created, 200 when it already existed.
 * Refused with 403 when the target's DM setting or a block forbids it.
 */
router.post(
  '/conversations/direct',
  rateLimit({ key: 'chat:open-dm', points: 60, durationSec: 300, by: ['user'] }),
  validate({ body: z.object({ userId: z.string().uuid(), roomId: z.string().uuid().nullish() }) }),
  route(
    mapped(async (req, res) => {
      if (req.body.userId === req.user.id) throw badRequest('You cannot message yourself');

      const conversation = await ConversationService.openDirect({
        fromUserId: req.user.id,
        toUserId: req.body.userId,
        tenantId: tenantOf(req),
        roomId: req.body.roomId ?? null,
      });

      res.status(conversation.created ? 201 : 200);
      return conversation;
    }),
  ),
);

/** A small group chat is the same object with more participants. */
router.post(
  '/conversations/group',
  validate({
    body: z.object({
      participantIds: z.array(z.string().uuid()).min(2).max(49).optional(),
      userIds: z.array(z.string().uuid()).min(2).max(49).optional(),
      title: z.string().max(120).optional(),
    }),
  }),
  route(
    mapped(async (req, res) => {
      const participantIds = req.body.participantIds ?? req.body.userIds;
      if (!participantIds) throw badRequest('participantIds is required');
      res.status(201);
      return ConversationService.createGroup({
        tenantId: tenantOf(req),
        createdBy: req.user.id,
        participantIds,
        title: req.body.title ?? null,
      });
    }),
  ),
);

router.get(
  '/conversations/:id',
  validate({ params: idParam }),
  route(mapped(async (req) => ConversationService.getById({ conversationId: req.params.id, viewerId: req.user.id }))),
);

/**
 * The caller's own settings for a conversation.
 *   { muted: true }                         muted until turned back on
 *   { muted: true, mutedUntil: <ISO time> } muted until then
 *   { muted: false }                        unmuted
 * `until` is accepted as a synonym (Chat.MuteTargetSchema).
 */
router.patch(
  '/conversations/:id',
  validate({
    params: idParam,
    body: z.object({
      muted: z.boolean().optional(),
      mutedUntil: isoDateTime.nullish(),
      until: isoDateTime.nullish(),
    }),
  }),
  route(
    mapped(async (req) => {
      const until = req.body.mutedUntil ?? req.body.until ?? null;
      const muted = req.body.muted ?? Boolean(until);
      return ConversationService.setMuted({
        conversationId: req.params.id,
        userId: req.user.id,
        muted,
        until,
      });
    }),
  ),
);

/** Delete for me. The other participants keep the conversation and its history. */
router.delete(
  '/conversations/:id',
  validate({ params: idParam }),
  route(mapped(async (req) => ConversationService.deleteForMe({ conversationId: req.params.id, userId: req.user.id }))),
);

/** Leave a group; for a direct chat this is the same as delete for me. */
router.delete(
  '/conversations/:id/participants/me',
  validate({ params: idParam }),
  route(
    mapped(async (req) => {
      await ConversationService.leave({ conversationId: req.params.id, userId: req.user.id });
      return null;
    }),
  ),
);

/* ------------------------------------------------------------------ *
 * Channels (public, space-bound, course-bound)
 * ------------------------------------------------------------------ */

router.get(
  '/channels',
  validate({ query: z.object({ scope: z.enum(['public', 'space', 'course']).optional() }) }),
  route(async (req) =>
    PublicChatService.list({ tenantId: tenantOf(req), userId: req.user.id, scope: q(req).scope }),
  ),
);

/**
 * Full history is readable by any member, including the part that happened
 * before they arrived — a new joiner should see the room they walked into.
 */
router.get(
  '/channels/:id/messages',
  validate({ params: idParam, query: pageQuery }),
  route(async (req) =>
    DirectMessageService.history({
      target: { kind: 'channel', channelId: req.params.id },
      viewerId: req.user.id,
      ...paging(req, { defaultLimit: 50 }),
    }),
  ),
);

router.post(
  '/channels/:id/messages',
  rateLimit({ key: 'chat:send', points: env.CHAT_RATE_PER_MIN, durationSec: 60, by: ['user'] }),
  validate({
    params: idParam,
    body: z.object({
      body: z.string().max(env.CHAT_MAX_MESSAGE_LEN),
      attachmentIds: z.array(z.string().uuid()).max(10).default([]),
      replyToId: z.string().uuid().nullish(),
      clientId: z.string().max(128),
    }),
  }),
  route(
    mapped(async (req, res) => {
      if (!req.body.body.trim() && req.body.attachmentIds.length === 0) {
        throw badRequest('A message needs text or an attachment');
      }
      const message = await DirectMessageService.send({
        target: { kind: 'channel', channelId: req.params.id },
        authorId: req.user.id,
        tenantId: tenantOf(req),
        body: req.body.body,
        attachmentIds: req.body.attachmentIds,
        replyToId: req.body.replyToId ?? null,
        clientMessageId: req.body.clientId,
      });

      res.status(201);
      return { message, clientId: req.body.clientId, deduped: false };
    }),
  ),
);

router.put(
  '/channels/:id/read',
  validate({ params: idParam, body: z.object({ messageId: z.string().uuid() }) }),
  route(async (req) => {
    const target = { kind: 'channel', channelId: req.params.id };
    await DirectMessageService.authoriseRead({ target, userId: req.user.id });
    await Participant.markChannelRead({
      channelId: req.params.id,
      userId: req.user.id,
      readAt: new Date().toISOString(),
      messageId: req.body.messageId,
    });
    return null;
  }),
);

/* ------------------------------------------------------------------ *
 * Messages
 * ------------------------------------------------------------------ */

router.get(
  '/conversations/:id/messages',
  validate({ params: idParam, query: pageQuery.extend({ around: z.string().uuid().optional() }) }),
  route(
    mapped(async (req) =>
      DirectMessageService.history({
        target: { kind: 'conversation', conversationId: req.params.id },
        viewerId: req.user.id,
        around: q(req).around ?? null,
        ...paging(req, { defaultLimit: 50 }),
      }),
    ),
  ),
);

/** Read up to a message; clears this conversation's unread badge for the caller. */
router.put(
  '/conversations/:id/read',
  validate({ params: idParam, body: z.object({ messageId: z.string().uuid() }) }),
  route(
    mapped(async (req) => {
      const target = { kind: 'conversation', conversationId: req.params.id };
      await DirectMessageService.authoriseRead({ target, userId: req.user.id });
      await Participant.markRead({
        conversationId: req.params.id,
        userId: req.user.id,
        readAt: new Date().toISOString(),
        messageId: req.body.messageId,
      });
      await UnreadService.clear({ userId: req.user.id, target }).catch(() => undefined);
      return null;
    }),
  ),
);

router.post(
  '/conversations/:id/messages',
  rateLimit({ key: 'chat:send', points: env.CHAT_RATE_PER_MIN, durationSec: 60, by: ['user'] }),
  validate({
    params: idParam,
    body: z.object({
      body: z.string().max(env.CHAT_MAX_MESSAGE_LEN),
      attachmentIds: z.array(z.string().uuid()).max(10).default([]),
      replyToId: z.string().uuid().nullish(),
      clientId: z.string().max(128),
    }),
  }),
  route(
    mapped(async (req, res) => {
      if (!req.body.body.trim() && req.body.attachmentIds.length === 0) {
        throw badRequest('A message needs text or an attachment');
      }

      const message = await DirectMessageService.send({
        target: { kind: 'conversation', conversationId: req.params.id },
        authorId: req.user.id,
        tenantId: tenantOf(req),
        body: req.body.body,
        attachmentIds: req.body.attachmentIds,
        replyToId: req.body.replyToId ?? null,
        clientMessageId: req.body.clientId,
      });

      res.status(201);
      return { message, clientId: req.body.clientId, deduped: false };
    }),
  ),
);

router.patch(
  '/messages/:id',
  validate({ params: idParam, body: z.object({ body: z.string().min(1).max(env.CHAT_MAX_MESSAGE_LEN) }) }),
  route(mapped(async (req) => DirectMessageService.edit({ messageId: req.params.id, userId: req.user.id, body: req.body.body }))),
);

router.delete(
  '/messages/:id',
  validate({ params: idParam }),
  route(
    mapped(async (req) => {
      await DirectMessageService.remove({
        messageId: req.params.id,
        userId: req.user.id,
        asModerator: ['owner', 'teacher'].includes(req.user.role),
      });
      return null;
    }),
  ),
);

/* ------------------------------------------------------------------ *
 * Unread counters
 * ------------------------------------------------------------------ */

/** One call for the whole badge state. */
router.get(
  '/unread',
  route(async (req) => UnreadService.summary({ userId: req.user.id })),
);

/* ------------------------------------------------------------------ *
 * Attachments
 * ------------------------------------------------------------------ */

/**
 * Chat attachments have no storage path of their own — this delegates to the
 * media domain, so quota, virus scanning, signed delivery and lifecycle rules
 * apply for free.
 */
router.post(
  '/attachments',
  validate({
    body: z.object({
      conversationId: z.string().uuid().nullish(),
      channelId: z.string().uuid().nullish(),
      filename: z.string().min(1).max(255),
      contentType: z.string().min(1).max(255),
      sizeBytes: z.number().int().min(1),
    }),
  }),
  route(async (req, res) => {
    if (!req.body.conversationId && !req.body.channelId) {
      throw badRequest('An attachment needs a conversationId or a channelId');
    }
    res.status(201);
    return ChatAttachmentService.presign({ userId: req.user.id, tenantId: tenantOf(req), ...req.body });
  }),
);

/* ------------------------------------------------------------------ *
 * Search
 * ------------------------------------------------------------------ */

router.get(
  '/search',
  rateLimit({ key: 'chat:search', points: 60, durationSec: 60, by: ['user'] }),
  validate({
    query: z.object({
      q: z.string().min(2).max(200),
      conversationId: z.string().uuid().optional(),
      channelId: z.string().uuid().optional(),
      from: z.string().uuid().optional(),
      cursor: z.string().optional(),
      limit: z.coerce.number().int().min(1).max(50).optional(),
    }),
  }),
  route(async (req) =>
    ChatSearchService.search({
      userId: req.user.id,
      tenantId: tenantOf(req),
      query: q(req).q,
      conversationId: q(req).conversationId,
      channelId: q(req).channelId,
      senderId: q(req).from,
      ...paging(req, { defaultLimit: 25, maxLimit: 50 }),
    }),
  ),
);

/* ------------------------------------------------------------------ *
 * Moderation
 * ------------------------------------------------------------------ */

router.post(
  '/reports',
  validate({
    body: z.object({
      messageId: z.string().uuid(),
      reason: z.enum(['spam', 'abuse', 'harassment', 'nsfw', 'other']),
      note: z.string().max(2000).optional(),
    }),
  }),
  route(async (req, res) => {
    res.status(202);
    return ChatModerationService.report({
      messageId: req.body.messageId,
      reporterId: req.user.id,
      reason: req.body.reason,
      detail: req.body.note ?? null,
    });
  }),
);

router.post(
  '/channels/:id/slow-mode',
  validate({ params: idParam, body: z.object({ seconds: z.number().int().min(0).max(3600) }) }),
  route(async (req) => {
    if (!['owner', 'teacher'].includes(req.user.role)) throw forbidden('Moderators only');
    return PublicChatService.setSlowMode({
      channelId: req.params.id,
      seconds: req.body.seconds,
      actorId: req.user.id,
    });
  }),
);

router.post(
  '/channels/:id/mutes',
  validate({
    params: idParam,
    body: z.object({ userId: z.string().uuid(), minutes: z.number().int().min(1).max(43_200) }),
  }),
  route(async (req) => {
    if (!['owner', 'teacher'].includes(req.user.role)) throw forbidden('Moderators only');
    return ChatModerationService.mute({
      channelId: req.params.id,
      userId: req.body.userId,
      until: new Date(Date.now() + req.body.minutes * 60_000).toISOString(),
      actorId: req.user.id,
    });
  }),
);

export default router;
