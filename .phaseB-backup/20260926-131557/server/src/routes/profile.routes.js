/**
 * profile.routes — own profile · privacy · other people · blocking (F6)
 *
 * Mounted under /profiles (app.js), so every path here is relative to it:
 * '/me' is GET /profiles/me. (The previous version repeated the prefix, which
 * made every route answer at /profiles/profiles/… and the client's calls 404.)
 *
 * A profile read is filtered by the viewer, and `canMessage` comes back
 * computed by ConversationService.canMessage — the same rule the send path
 * enforces — so the Message button and the send always agree. `roomId` in the
 * query lets that rule count a shared live lesson as shared context.
 *
 * Both the contract's paths (profileApi: PATCH /me/privacy, POST /me/blocks,
 * DELETE /me/blocks/:userId) and the older ones (PUT /me/privacy,
 * PUT|DELETE /:userId/block) are served, so no client breaks while it moves.
 */

import { Router } from 'express';
import { z } from 'zod';

import * as Profile from '../identity/Profile.js';
import * as ConversationService from '../messaging/ConversationService.js';
import * as ChatModerationService from '../messaging/ChatModerationService.js';
import * as UploadService from '../media/UploadService.js';
import { rateLimit } from '../middleware/rateLimit.js';
import { route, validate, requireAuth, tenantOf, q, notFound, badRequest, forbidden } from './_helpers.js';

const router = Router();
router.use(requireAuth);

const userIdParam = z.object({ userId: z.string().uuid() });

/** Errors the profile domain raises with a code, as the HTTP answers clients understand. */
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
        throw Object.assign(badRequest(error.message), { status: 409 });
      default:
        throw error;
    }
  }
};

const TIME_ZONES = new Set(Intl.supportedValuesOf('timeZone'));

/* ------------------------------------------------------------------ *
 * Own profile
 * ------------------------------------------------------------------ */

router.get(
  '/me',
  route(async (req) => {
    const own = await Profile.getOwn(req.user.id);
    if (!own) throw notFound('No profile for this account');
    return own;
  }),
);

router.patch(
  '/me',
  validate({
    body: z.object({
      displayName: z.string().trim().min(1).max(80).optional(),
      // Lower-case letters, digits and underscores: what @mentions can match.
      handle: z.string().trim().toLowerCase().regex(/^[a-z0-9_]{3,32}$/, 'use 3–32 lowercase letters, digits or _').optional(),
      bio: z.string().max(2000).nullish(),
      headline: z.string().max(140).nullish(),
      avatarAssetId: z.string().uuid().nullish(),
      links: z.array(z.object({ label: z.string().max(40), url: z.string().url() })).max(5).optional(),
      locale: z.string().regex(/^[a-z]{2}(-[A-Z]{2})?$/, 'a language code such as en or de-DE').optional(),
      timeZone: z.string().max(64).refine((zone) => TIME_ZONES.has(zone), 'not a known time zone').optional(),
    }),
  }),
  route(
    asHttp(async (req) => {
      const { avatarAssetId, ...patch } = req.body;
      if (avatarAssetId) await Profile.setAvatar({ userId: req.user.id, assetId: avatarAssetId });
      return Profile.update({ userId: req.user.id, patch });
    }),
  ),
);

/**
 * Account preferences: appearance, date and time format, how lessons start
 * for me, and (teachers) my lesson defaults. PATCH takes any section with any
 * subset of its keys and returns the full set with defaults filled in.
 */
router.get(
  '/me/preferences',
  route(async (req) => Profile.getPreferences(req.user.id)),
);

router.patch(
  '/me/preferences',
  route(asHttp(async (req) => Profile.updatePreferences({ userId: req.user.id, patch: req.body }))),
);

/**
 * Who may message me, and what others see. "Receive private messages: off" is
 * dmPolicy 'nobody'; teachers of the tenant can still reach the person.
 */
const privacyBody = z.object({
  dmPolicy: z.enum(['anyone', 'shared-context', 'shared-only', 'shared', 'nobody']).optional(),
  visibility: z.enum(['tenant', 'shared-only', 'shared', 'private']).optional(),
  showPresence: z.boolean().optional(),
  sendReadReceipts: z.boolean().optional(),
  readReceipts: z.boolean().optional(),
});

const updatePrivacy = route(async (req) => Profile.updatePrivacy({ userId: req.user.id, patch: req.body }));
router.patch('/me/privacy', validate({ body: privacyBody }), updatePrivacy);
router.put('/me/privacy', validate({ body: privacyBody }), updatePrivacy);

router.get(
  '/me/privacy',
  route(async (req) => (await Profile.getOwn(req.user.id))?.privacy ?? null),
);

/** Avatar upload goes through the media presign flow like any other asset. */
router.post(
  '/me/avatar',
  validate({
    body: z.object({
      filename: z.string().min(1).max(255),
      contentType: z.enum(['image/jpeg', 'image/png', 'image/webp']),
      sizeBytes: z.number().int().min(1).max(10 * 1024 * 1024),
    }),
  }),
  route(async (req, res) => {
    res.status(201);
    return UploadService.createUpload({
      ownerId: req.user.id,
      purpose: 'avatar',
      fileName: req.body.filename,
      contentType: req.body.contentType,
      sizeBytes: req.body.sizeBytes,
    });
  }),
);

router.put(
  '/me/avatar',
  validate({ body: z.object({ assetId: z.string().uuid() }) }),
  route(async (req) => Profile.setAvatar({ userId: req.user.id, assetId: req.body.assetId })),
);

/* ------------------------------------------------------------------ *
 * Blocking (account-wide)
 * ------------------------------------------------------------------ */

router.get(
  '/me/blocks',
  validate({ query: z.object({ cursor: z.string().optional(), limit: z.coerce.number().int().min(1).max(100).optional() }) }),
  route(async (req) =>
    Profile.listBlocks({ userId: req.user.id, cursor: q(req).cursor ?? null, limit: q(req).limit ?? 25 }),
  ),
);

const block = async (req, blockedUserId, reason) => {
  if (blockedUserId === req.user.id) throw badRequest('You cannot block yourself');
  // Mutual in effect: neither side can message the other afterwards.
  return Profile.block({ userId: req.user.id, blockedUserId, reason: reason ?? null });
};

router.post(
  '/me/blocks',
  validate({ body: z.object({ userId: z.string().uuid(), reason: z.string().max(500).optional() }).passthrough() }),
  route(async (req, res) => {
    res.status(201);
    return block(req, req.body.userId, req.body.reason);
  }),
);

router.delete(
  '/me/blocks/:userId',
  validate({ params: userIdParam }),
  route(async (req) => {
    await Profile.unblock({ userId: req.user.id, blockedUserId: req.params.userId });
    return null;
  }),
);

router.put(
  '/:userId/block',
  validate({ params: userIdParam, body: z.object({ reason: z.string().max(500).optional() }).default({}) }),
  route(async (req) => block(req, req.params.userId, req.body?.reason)),
);

router.delete(
  '/:userId/block',
  validate({ params: userIdParam }),
  route(async (req) => {
    await Profile.unblock({ userId: req.user.id, blockedUserId: req.params.userId });
    return null;
  }),
);

/* ------------------------------------------------------------------ *
 * Other people
 * ------------------------------------------------------------------ */

/** Mention autocomplete and people search. */
const searchQuery = z.object({
  q: z.string().min(2).max(80),
  scopeId: z.string().uuid().optional(),
  spaceId: z.string().uuid().optional(),
  limit: z.coerce.number().int().min(1).max(25).optional(),
});

const search = route(async (req) =>
  Profile.search({
    q: q(req).q,
    viewerId: req.user.id,
    scopeId: q(req).scopeId ?? q(req).spaceId ?? null,
    limit: q(req).limit ?? 10,
  }),
);

router.get('/search', rateLimit({ key: 'profile:search', points: 60, durationSec: 60, by: ['user'] }), validate({ query: searchQuery }), search);
router.get('/', rateLimit({ key: 'profile:search', points: 60, durationSec: 60, by: ['user'] }), validate({ query: searchQuery }), search);

/**
 * Someone else's profile, as this viewer may see it. `canMessage` and the
 * reason are computed by the same rule the send path enforces.
 */
router.get(
  '/:userId',
  rateLimit({ key: 'profile:read', points: 300, durationSec: 300, by: ['user'] }),
  validate({ params: userIdParam, query: z.object({ roomId: z.string().uuid().optional() }).passthrough() }),
  route(async (req) => {
    const profile = await Profile.getPublic({ userId: req.params.userId, viewerId: req.user.id });
    if (!profile) throw notFound('No such profile');

    const roomId = q(req).roomId ?? null;
    const messaging = await ConversationService.canMessage({
      fromUserId: req.user.id,
      toUserId: req.params.userId,
      roomId,
    });

    // Teachers count as sharing a course with the people they teach, as in
    // the "View as" preview in Settings.
    const shares =
      req.params.userId === req.user.id ||
      ['teacher', 'owner'].includes(req.user.role) ||
      (await ConversationService.sharesContext({ userA: req.user.id, userB: req.params.userId, roomId }));

    return {
      ...Profile.applyVisibility(profile, { sharesContext: shares }),
      canMessage: messaging.allowed,
      cannotMessageReason: messaging.allowed ? null : messaging.reason ?? null,
    };
  }),
);

/* ------------------------------------------------------------------ *
 * Reporting
 * ------------------------------------------------------------------ */

router.post(
  '/:userId/report',
  rateLimit({ key: 'profile:report', points: 20, durationSec: 3600, by: ['user'] }),
  validate({
    params: userIdParam,
    body: z.object({
      reason: z.enum(['spam', 'abuse', 'harassment', 'impersonation', 'nsfw', 'other']),
      note: z.string().max(2000).optional(),
      messageIds: z.array(z.string().uuid()).max(20).default([]),
    }),
  }),
  route(async (req, res) => {
    res.status(202);
    return ChatModerationService.reportUser({
      reporterId: req.user.id,
      reportedId: req.params.userId,
      tenantId: tenantOf(req),
      ...req.body,
    });
  }),
);

export default router;
