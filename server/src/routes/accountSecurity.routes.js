/**
 * accountSecurity.routes — password · two-step sign-in · passkeys · your data
 * (Settings, Phase C)
 *
 * Mounted under /account/security (app.js). Everything is about the person
 * asking; no route takes someone else's id.
 *
 *   GET    /                               what is set up, and a pending deletion
 *   POST   /password                       { currentPassword, newPassword, signOutOthers }
 *   POST   /totp/setup                     { password | code } → a new secret and its QR code
 *   POST   /totp/enable                    { code } → recovery codes, shown once
 *   POST   /totp/disable                   { password | code }
 *   POST   /recovery-codes                 { password | code } → a new set
 *   POST   /passkeys/options               { password | code } → registration options
 *   POST   /passkeys                       { optionsId, response, name }
 *   PATCH  /passkeys/:id                   { name }
 *   POST   /passkeys/:id/remove            { password | code }
 *   GET    /export                         everything, as one JSON document
 *   POST   /deletion                       { password | code } → deletion in 14 days
 *   POST   /deletion/cancel                stops it
 *
 * "{ password | code }" is security/confirmIdentity.js: a signed-in browser
 * alone is not enough to switch protection off or delete an account.
 *
 * Every change is recorded (Recent changes), announced to the person's other
 * tabs (settings:changed) and, where it matters for someone whose account is
 * being taken over, confirmed by email.
 */

import { Router } from 'express';
import { z } from 'zod';

import { pool } from '../db/pool.js';
import * as Users from '../identity/User.js';
import * as SecondFactor from '../identity/secondFactor.js';
import * as Passkeys from '../identity/passkeys.js';
import * as DeviceSessions from '../identity/deviceSessions.js';
import * as AccountDeletion from '../identity/accountDeletion.js';
import { buildExport } from '../identity/dataExport.js';
import { confirmIdentity } from '../security/confirmIdentity.js';
import { exportFileName } from '../security/exportSanitize.js';
import { auditFromRequest } from '../security/auditLog.js';
import { pushToUser } from '../realtime/userEvents.js';
import { rateLimit } from '../middleware/rateLimit.js';
import { logger } from '../observability/logger.js';
import { route, validate, requireAuth, notFound, badRequest, forbidden } from './_helpers.js';

const log = logger.child({ component: 'account-security' });

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
      case 'conflict':
        throw Object.assign(badRequest(error.message), { status: 409 });
      default:
        throw error;
    }
  }
};

const handle = (fn) => route(asHttp(fn));

/** Recorded in the history, announced to other tabs; neither may fail the change. */
const recordSecurity = async (req, action, metadata = {}) => {
  try {
    await auditFromRequest(req, { action, targetType: 'user', targetId: req.user.id, metadata });
  } catch (cause) {
    log.warn({ err: cause, action }, 'security change not audited');
  }
  await pushToUser(req.user.id, 'settings:changed', { section: 'security', fields: [action] });
};

/** An email to the account's own address: the alarm if it was not them. */
const alertByEmail = async (userId, kind, title) => {
  try {
    const { enqueueNotification } = await import('../queues/queues.js');
    await enqueueNotification('notification.email', { userId, type: kind, kind, title, href: '/settings/security' });
  } catch (cause) {
    log.warn({ err: cause, kind }, 'security email not queued');
  }
};

const confirmBody = z
  .object({ password: z.string().min(1).max(512).optional(), code: z.string().min(6).max(20).optional() })
  .passthrough();

const confirm = (req) =>
  confirmIdentity({ userId: req.user.id, password: req.body?.password, code: req.body?.code });

const confirmLimit = rateLimit({ key: 'account:confirm', points: 15, durationSec: 900, by: ['user'] });

/* ------------------------------------------------------------------ *
 * Overview
 * ------------------------------------------------------------------ */

const overview = async (userId) => {
  const [{ rows }, twoStep, passkeys, passkeysAvailable, deletion] = await Promise.all([
    pool.query(`SELECT password_hash IS NOT NULL AS has_password, password_changed_at FROM users WHERE id = $1`, [userId]),
    SecondFactor.status(userId),
    Passkeys.list(userId),
    Passkeys.available(),
    AccountDeletion.status(userId),
  ]);
  return {
    password: {
      set: Boolean(rows[0]?.has_password),
      changedAt: rows[0]?.password_changed_at ? new Date(rows[0].password_changed_at).toISOString() : null,
    },
    twoStep,
    passkeys: { available: passkeysAvailable, items: passkeys },
    deletion,
  };
};

router.get(
  '/',
  route(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    return overview(req.user.id);
  }),
);

/* ------------------------------------------------------------------ *
 * Password
 * ------------------------------------------------------------------ */

router.post(
  '/password',
  confirmLimit,
  validate({
    body: z.object({
      currentPassword: z.string().min(1).max(512),
      newPassword: z.string().min(1).max(512),
      signOutOthers: z.boolean().default(true),
    }),
  }),
  handle(async (req) => {
    const userId = req.user.id;
    await confirmIdentity({ userId, password: req.body.currentPassword });

    if (req.body.newPassword === req.body.currentPassword) {
      throw badRequest('The new password has to be different from the current one.');
    }
    const user = await Users.findById(userId);
    const policy = Users.validatePassword(req.body.newPassword, { email: user.email, displayName: user.displayName });
    if (!policy.valid) throw badRequest(policy.errors[0]);

    // Directly rather than Users.updatePassword, which also signs this very
    // device out: here the person just proved who they are.
    await pool.query(
      `UPDATE users SET password_hash = $2, password_changed_at = now(),
              failed_attempts = 0, locked_until = NULL, updated_at = now()
        WHERE id = $1`,
      [userId, await Users.hashPassword(req.body.newPassword)],
    );

    let signedOut = 0;
    if (req.body.signOutOthers) {
      ({ revoked: signedOut } = await DeviceSessions.revokeOthers({ userId, currentSessionId: req.user.sessionId }));
    }

    await recordSecurity(req, 'security.password.changed', { count: signedOut });
    await alertByEmail(userId, 'security.password.changed', 'Your password was changed');
    return { changed: true, signedOut };
  }),
);

/* ------------------------------------------------------------------ *
 * Authenticator app and recovery codes
 * ------------------------------------------------------------------ */

router.post(
  '/totp/setup',
  confirmLimit,
  validate({ body: confirmBody }),
  handle(async (req) => {
    // Confirmed too: someone at an unlocked laptop could otherwise put their
    // own phone on the account and lock its owner out.
    await confirm(req);
    const user = await Users.findById(req.user.id);
    return SecondFactor.startTotpSetup({ userId: req.user.id, accountName: user.email });
  }),
);

router.post(
  '/totp/enable',
  confirmLimit,
  validate({ body: z.object({ code: z.string().min(6).max(12) }) }),
  handle(async (req) => {
    const result = await SecondFactor.confirmTotpSetup({ userId: req.user.id, code: req.body.code });
    await recordSecurity(req, 'security.totp.enabled');
    await alertByEmail(req.user.id, 'security.totp.enabled', 'Two-step sign-in is on');
    return result;
  }),
);

router.post(
  '/totp/disable',
  confirmLimit,
  validate({ body: confirmBody }),
  handle(async (req) => {
    await confirm(req);
    await SecondFactor.disableTotp({ userId: req.user.id });
    await recordSecurity(req, 'security.totp.disabled');
    await alertByEmail(req.user.id, 'security.totp.disabled', 'Your authenticator app was removed');
    return overview(req.user.id);
  }),
);

router.post(
  '/recovery-codes',
  confirmLimit,
  validate({ body: confirmBody }),
  handle(async (req) => {
    await confirm(req);
    const { required } = await SecondFactor.status(req.user.id);
    if (!required) throw badRequest('Recovery codes come with two-step sign-in. Turn that on first.');
    const result = await SecondFactor.regenerateRecoveryCodes({ userId: req.user.id });
    await recordSecurity(req, 'security.recovery_codes.regenerated');
    return result;
  }),
);

/* ------------------------------------------------------------------ *
 * Passkeys
 * ------------------------------------------------------------------ */

router.post(
  '/passkeys/options',
  confirmLimit,
  validate({ body: confirmBody }),
  handle(async (req) => {
    await confirm(req);
    const user = await Users.findById(req.user.id);
    return Passkeys.registrationOptions({ user, requestOrigin: req.get('origin') ?? null });
  }),
);

router.post(
  '/passkeys',
  validate({
    body: z.object({
      optionsId: z.string().uuid(),
      response: z.object({ id: z.string().min(1).max(1024) }).passthrough(),
      name: z.string().trim().max(60).optional(),
    }),
  }),
  handle(async (req) => {
    const passkey = await Passkeys.finishRegistration({
      userId: req.user.id,
      optionsId: req.body.optionsId,
      response: req.body.response,
      name: req.body.name,
    });
    // The first passkey turns two-step sign-in on: recovery codes come with it.
    const recoveryCodes = await SecondFactor.ensureRecoveryCodes({ userId: req.user.id });
    await recordSecurity(req, 'security.passkey.added', { device: passkey.name });
    await alertByEmail(req.user.id, 'security.passkey.added', 'A passkey was added to your account');
    return { passkey, recoveryCodes };
  }),
);

const idParam = z.object({ id: z.string().uuid() });

router.patch(
  '/passkeys/:id',
  validate({ params: idParam, body: z.object({ name: z.string().trim().min(1).max(60) }) }),
  handle(async (req) => {
    if (!(await Passkeys.rename({ userId: req.user.id, id: req.params.id, name: req.body.name }))) {
      throw notFound('No such passkey');
    }
    await pushToUser(req.user.id, 'settings:changed', { section: 'security', fields: [] });
    return { renamed: true };
  }),
);

router.post(
  '/passkeys/:id/remove',
  confirmLimit,
  validate({ params: idParam, body: confirmBody }),
  handle(async (req) => {
    await confirm(req);
    const name = await Passkeys.remove({ userId: req.user.id, id: req.params.id });
    if (!name) throw notFound('No such passkey');
    const { required } = await SecondFactor.status(req.user.id);
    if (!required) await pool.query(`DELETE FROM user_recovery_codes WHERE user_id = $1`, [req.user.id]);
    await recordSecurity(req, 'security.passkey.removed', { device: name });
    await alertByEmail(req.user.id, 'security.passkey.removed', 'A passkey was removed from your account');
    return overview(req.user.id);
  }),
);

/* ------------------------------------------------------------------ *
 * Your data
 * ------------------------------------------------------------------ */

router.get(
  '/export',
  rateLimit({ key: 'account:export', points: 5, durationSec: 3600, by: ['user'] }),
  handle(async (req, res) => {
    const document = await buildExport({ userId: req.user.id });
    await recordSecurity(req, 'account.exported');
    res.set('Cache-Control', 'no-store');
    res.set('Content-Disposition', `attachment; filename="${exportFileName()}"`);
    return document;
  }),
);

router.post(
  '/deletion',
  confirmLimit,
  validate({ body: confirmBody }),
  handle(async (req) => {
    await confirm(req);
    const scheduled = await AccountDeletion.request({ userId: req.user.id });
    const { revoked } = await DeviceSessions.revokeOthers({ userId: req.user.id, currentSessionId: req.user.sessionId });
    await recordSecurity(req, 'account.deletion.requested', { count: revoked });
    await alertByEmail(
      req.user.id,
      'security.account.deletion_requested',
      `Your account will be deleted on ${scheduled.scheduledFor.slice(0, 10)}`,
    );
    return { deletion: scheduled, signedOut: revoked };
  }),
);

router.post(
  '/deletion/cancel',
  handle(async (req) => {
    const cancelled = await AccountDeletion.cancel({ userId: req.user.id });
    if (cancelled) {
      await recordSecurity(req, 'account.deletion.cancelled');
      await alertByEmail(req.user.id, 'security.account.deletion_cancelled', 'Your account will not be deleted');
    }
    return { deletion: null, cancelled };
  }),
);

export default router;
