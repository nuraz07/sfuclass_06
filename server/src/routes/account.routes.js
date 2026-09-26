/**
 * account.routes — notifications · signed-in devices · history  (Settings, Phase B)
 *
 * Mounted under /account (app.js). Everything here is about the person asking;
 * no route takes someone else's id.
 *
 *   GET    /notifications                 settings, push and email status
 *   PATCH  /notifications                 any part of the settings
 *   POST   /notifications/test            { channel: inApp | push | email }
 *   PUT    /push-subscriptions            this browser receives push
 *   POST   /push-subscriptions/remove     this browser stops
 *   GET    /muted-chats                   every chat muted right now
 *   POST   /muted-chats/:kind/:id/unmute  ends one mute
 *   POST   /muted-chats/:kind/:id/mute    mutes again (the undo of unmute)
 *   GET    /sessions                      signed-in devices, this one marked
 *   DELETE /sessions/:sessionId           sign one device out
 *   POST   /sessions/sign-out-others      sign out everywhere else
 *   GET    /login-history                 sign-ins and failed attempts
 *   GET    /activity                      recent settings and security changes
 *
 * Password, two-step sign-in, passkeys and "your data" are in
 * accountSecurity.routes.js, under /account/security.
 *
 * A test notification is sent from here directly rather than through the
 * queue, so the answer says what actually happened ("sent to 2 browsers",
 * "the mail server refused it") and a test works while the worker is down.
 */

import { Router } from 'express';
import { z } from 'zod';

import { pool } from '../db/pool.js';
import * as NotificationService from '../community/NotificationService.js';
import * as Rules from '../settings/notifications.js';
import * as Subscriptions from '../notifications/webPushSubscriptions.js';
import * as Delivery from '../notifications/delivery.js';
import { deliveryConfig } from '../notifications/config.js';
import * as DeviceSessions from '../identity/deviceSessions.js';
import * as Participant from '../messaging/models/Participant.js';
import { auditFromRequest } from '../security/auditLog.js';
import { SIGN_IN_FAILED, SIGN_IN_SUCCEEDED } from '../security/sessionActivity.js';
import { describeUserAgent } from '../security/userAgent.js';
import { recordChange } from '../settings/changeLog.js';
import { pushToUser } from '../realtime/userEvents.js';
import { rateLimit } from '../middleware/rateLimit.js';
import { route, validate, requireAuth, q, notFound, badRequest, forbidden } from './_helpers.js';

const router = Router();
router.use(requireAuth);

/** Errors the services raise with a code, as the HTTP answers clients understand. */
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
      default:
        throw error;
    }
  }
};

const iso = (value) => (value ? new Date(value).toISOString() : null);

/* ------------------------------------------------------------------ *
 * Notifications
 * ------------------------------------------------------------------ */

const notificationsView = async (userId) => {
  const context = await NotificationService.getDeliveryContext(userId);
  if (!context) throw notFound('No account');
  return {
    settings: context.settings,
    timeZone: context.timeZone,
    quietNow: Rules.isWithinQuietHours(context.settings.quietHours, new Date(), context.timeZone),
    push: {
      configured: Delivery.webPushConfigured(),
      publicKey: Delivery.webPushPublicKey(),
      devices: await Subscriptions.countForUser(userId),
    },
    email: { address: context.email, suppressed: context.emailSuppressed },
  };
};

router.get('/notifications', route(async (req) => notificationsView(req.user.id)));

router.patch(
  '/notifications',
  route(
    asHttp(async (req) => {
      await NotificationService.updateSettings({ userId: req.user.id, patch: req.body ?? {} });
      await recordChange(req, 'notifications', req.body);
      return notificationsView(req.user.id);
    }),
  ),
);

const TEST_TEXT = {
  title: 'Test notification',
  body: 'If you can read this, notifications reach you here.',
  url: '/settings/notifications',
};

router.post(
  '/notifications/test',
  rateLimit({ key: 'account:notify-test', points: 10, durationSec: 60, by: ['user'] }),
  validate({ body: z.object({ channel: z.enum(['inApp', 'push', 'email']) }) }),
  route(async (req) => {
    const userId = req.user.id;
    const { channel } = req.body;

    if (channel === 'inApp') {
      await NotificationService.createInApp({ userId, kind: 'system.test', ...TEST_TEXT });
      return { channel, delivered: 1, detail: 'Sent. It appears on screen in every open tab of the app.' };
    }

    if (channel === 'push') {
      if (!Delivery.webPushConfigured()) {
        return { channel, delivered: 0, detail: 'Push is not set up on the server: the web push keys are missing.' };
      }
      const result = await Delivery.sendPush({ userId, kind: 'system.test', ...TEST_TEXT });
      if (result.targets === 0) {
        return {
          channel,
          delivered: 0,
          detail: 'No browser receives push on this account yet. Turn on push for this browser first.',
        };
      }
      return {
        channel,
        delivered: result.delivered,
        detail:
          result.failed === 0
            ? `Sent to ${result.delivered} ${result.delivered === 1 ? 'browser' : 'browsers'}.`
            : `Sent to ${result.delivered} of ${result.targets}. Browsers that no longer accept push were removed.`,
      };
    }

    const context = await NotificationService.getDeliveryContext(userId);
    if (!context?.email) return { channel, delivered: 0, detail: 'This account has no email address.' };
    if (context.emailSuppressed) {
      return { channel, delivered: 0, detail: 'Email to this address is paused because an earlier one bounced.' };
    }
    try {
      const rendered = Delivery.renderEmail({ ...TEST_TEXT, recipientName: context.displayName });
      const sent = await Delivery.sendEmail({ to: context.email, ...rendered, kind: 'system.test' });
      const where =
        sent.transport === 'smtp' && deliveryConfig().smtpPort === 1025
          ? ' In development it lands in Mailpit (port 8025).'
          : '';
      return { channel, delivered: 1, detail: `Sent to ${context.email}.${where}` };
    } catch (cause) {
      return {
        channel,
        delivered: 0,
        detail: `The mail server did not accept it (${cause?.code ?? cause?.message ?? 'unknown error'}).`,
      };
    }
  }),
);

/* ------------------------------------------------------------------ *
 * Push registrations (this browser)
 * ------------------------------------------------------------------ */

const subscriptionBody = z
  .object({
    endpoint: z
      .string()
      .url()
      .max(2048)
      .refine((value) => value.startsWith('https://'), 'push endpoints are https'),
    keys: z.object({ p256dh: z.string().min(16).max(256), auth: z.string().min(8).max(64) }).passthrough(),
  })
  .passthrough();

router.put(
  '/push-subscriptions',
  rateLimit({ key: 'account:push-register', points: 20, durationSec: 3600, by: ['user'] }),
  validate({ body: subscriptionBody }),
  route(async (req) => {
    if (!Delivery.webPushConfigured()) throw badRequest('Push is not set up on the server.');
    await Subscriptions.upsert({
      userId: req.user.id,
      sessionId: req.user.sessionId ?? null,
      endpoint: req.body.endpoint,
      p256dh: req.body.keys.p256dh,
      auth: req.body.keys.auth,
      userAgent: req.get('user-agent'),
    });
    return { registered: true, devices: await Subscriptions.countForUser(req.user.id) };
  }),
);

router.post(
  '/push-subscriptions/remove',
  validate({ body: z.object({ endpoint: z.string().max(2048) }) }),
  route(async (req) => {
    await Subscriptions.removeByEndpoint({ userId: req.user.id, endpoint: req.body.endpoint });
    return { registered: false, devices: await Subscriptions.countForUser(req.user.id) };
  }),
);

/* ------------------------------------------------------------------ *
 * Muted chats
 * ------------------------------------------------------------------ */

router.get('/muted-chats', route(async (req) => NotificationService.mutedChats(req.user.id)));

const muteParams = z.object({ kind: z.enum(['conversation', 'channel']), id: z.string().uuid() });

const setChatMute = async ({ userId, kind, id, muted, until = null }) => {
  if (kind === 'conversation') {
    if (!(await Participant.isParticipant({ conversationId: id, userId }))) throw notFound('Chat not found');
    await Participant.setMuted({ conversationId: id, userId, muted, until: muted ? until : null });
    return;
  }
  const { rowCount } = await pool.query(
    `UPDATE channel_participants SET muted = $3, muted_until = $4
      WHERE channel_id = $1 AND user_id = $2`,
    [id, userId, muted, muted ? until : null],
  );
  if (rowCount === 0) throw notFound('Chat not found');
};

router.post(
  '/muted-chats/:kind/:id/unmute',
  validate({ params: muteParams }),
  route(async (req) => {
    await setChatMute({ userId: req.user.id, kind: req.params.kind, id: req.params.id, muted: false });
    await pushToUser(req.user.id, 'settings:changed', { section: 'muted', fields: [] });
    return { muted: false };
  }),
);

router.post(
  '/muted-chats/:kind/:id/mute',
  validate({
    params: muteParams,
    body: z.object({ until: z.string().nullish() }).passthrough().default({}),
  }),
  route(async (req) => {
    const requested = req.body?.until ? new Date(req.body.until) : null;
    const until = requested && !Number.isNaN(requested.getTime()) && requested > new Date() ? requested.toISOString() : null;
    await setChatMute({ userId: req.user.id, kind: req.params.kind, id: req.params.id, muted: true, until });
    await pushToUser(req.user.id, 'settings:changed', { section: 'muted', fields: [] });
    return { muted: true, mutedUntil: until };
  }),
);

/* ------------------------------------------------------------------ *
 * Signed-in devices
 * ------------------------------------------------------------------ */

router.get(
  '/sessions',
  route(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    const sessions = await DeviceSessions.list(req.user.id);
    return {
      items: sessions.map((session) => ({ ...session, current: session.sessionId === req.user.sessionId })),
    };
  }),
);

router.delete(
  '/sessions/:sessionId',
  rateLimit({ key: 'account:sessions', points: 30, durationSec: 300, by: ['user'] }),
  validate({ params: z.object({ sessionId: z.string().min(8).max(128) }) }),
  route(async (req) => {
    if (req.params.sessionId === req.user.sessionId) {
      throw badRequest('This is the device you are using. Use Sign out instead.');
    }
    const result = await DeviceSessions.revoke({ userId: req.user.id, sessionId: req.params.sessionId });
    if (!result) throw notFound('No such device');
    await auditFromRequest(req, {
      action: 'auth.session.revoked',
      targetType: 'user',
      targetId: req.user.id,
      metadata: { device: result.label, count: 1 },
    });
    await pushToUser(req.user.id, 'settings:changed', { section: 'sessions', fields: [] });
    return null;
  }),
);

router.post(
  '/sessions/sign-out-others',
  rateLimit({ key: 'account:sessions', points: 30, durationSec: 300, by: ['user'] }),
  route(async (req) => {
    const { revoked } = await DeviceSessions.revokeOthers({
      userId: req.user.id,
      currentSessionId: req.user.sessionId,
    });
    if (revoked > 0) {
      await auditFromRequest(req, {
        action: 'auth.session.revoked',
        targetType: 'user',
        targetId: req.user.id,
        metadata: { device: null, count: revoked },
      });
      await pushToUser(req.user.id, 'settings:changed', { section: 'sessions', fields: [] });
    }
    return { revoked };
  }),
);

/* ------------------------------------------------------------------ *
 * History (audit_log)
 * ------------------------------------------------------------------ */

const pageQuery = z
  .object({
    cursor: z.string().regex(/^\d+$/).optional(),
    limit: z.coerce.number().int().min(1).max(50).optional(),
  })
  .passthrough();

const readHistory = async ({ userId, actions, cursor, limit }) => {
  const { rows } = await pool.query(
    `SELECT id, action, metadata, host(ip) AS ip, user_agent, created_at
       FROM audit_log
      WHERE actor_id = $1 AND action = ANY($2::text[])
        AND ($3::bigint IS NULL OR id < $3::bigint)
      ORDER BY id DESC
      LIMIT $4`,
    [userId, actions, cursor ?? null, limit + 1],
  );
  const page = rows.slice(0, limit);
  return {
    items: page.map((row) => ({
      id: String(row.id),
      action: row.action,
      at: iso(row.created_at),
      device: describeUserAgent(row.user_agent ?? ''),
      ip: row.ip ?? null,
      section: row.metadata?.section ?? null,
      fields: Array.isArray(row.metadata?.fields) ? row.metadata.fields : [],
      detail: row.metadata?.device ?? row.metadata?.reason ?? row.metadata?.method ?? null,
      count: typeof row.metadata?.count === 'number' ? row.metadata.count : null,
    })),
    nextCursor: rows.length > limit && page.length ? String(page.at(-1).id) : null,
  };
};

router.get(
  '/login-history',
  validate({ query: pageQuery }),
  route(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    return readHistory({
      userId: req.user.id,
      actions: [SIGN_IN_SUCCEEDED, SIGN_IN_FAILED, 'auth.second_factor.failed'],
      cursor: q(req).cursor,
      limit: Number(q(req).limit ?? 20),
    });
  }),
);

router.get(
  '/activity',
  validate({ query: pageQuery }),
  route(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    return readHistory({
      userId: req.user.id,
      actions: [
        'settings.changed',
        'auth.session.revoked',
        // Phase C: password, two-step sign-in, passkeys, your data
        'security.password.changed',
        'security.totp.enabled',
        'security.totp.disabled',
        'security.recovery_codes.regenerated',
        'security.passkey.added',
        'security.passkey.removed',
        'account.exported',
        'account.deletion.requested',
        'account.deletion.cancelled',
      ],
      cursor: q(req).cursor,
      limit: Number(q(req).limit ?? 20),
    });
  }),
);

export default router;
