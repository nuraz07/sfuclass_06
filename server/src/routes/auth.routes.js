/**
 * auth.routes — login · second step · passkeys · refresh · logout · devices (F5, Settings Phase C)
 *
 * Phase C: POST /login answers { secondFactorRequired, challengeId, methods }
 * instead of tokens when the account has two-step sign-in. The session is
 * created only by the second step:
 *
 *   POST /login/second-factor                   { challengeId, code }
 *   POST /login/second-factor/passkey/options   { challengeId }
 *   POST /login/second-factor/passkey           { challengeId, optionsId, response }
 *   POST /passkey/options                       sign in with a passkey alone
 *   POST /passkey                               { optionsId, response }
 *
 * All of them answer exactly like /login (cookie, body, wantsRefreshToken).
 *
 * The split that matters here: the API is bearer-token based, but the refresh
 * token lives in an httpOnly, SameSite=Strict cookie. That is why CSRF
 * protection applies to exactly one group of routes — the cookie-authenticated
 * ones — and nowhere else. A bearer endpoint cannot be CSRF'd; a cookie
 * endpoint can.
 *
 * Those routes are listed in securityConfig.csrf.protectedPaths and guarded by
 * the single `csrfProtection()` mounted in app.js. This file deliberately does
 * not mount it again: csrfProtection is a *factory*, and passing the factory
 * itself into a middleware chain makes Express call it with (req, res, next),
 * whereupon it ignores all three, returns the real middleware, and never calls
 * next — so the request hangs until the client times out.
 *
 *  - Access tokens are short-lived RS256, so the SFU can verify them with the
 *    public key without ever holding the signing key.
 *  - Refresh tokens rotate on every use and are bound to a device session.
 *    Reuse of an already-rotated token is treated as theft: the whole session
 *    family is revoked.
 *  - Logout revokes server-side (SessionStore), because "the client deleted the
 *    token" is not a security property.
 *
 * Rate limits here are stricter than the global ones — credential stuffing is
 * the whole point of this file's existence.
 */

import { Router } from 'express';
import { z } from 'zod';

import * as AuthService from '../identity/AuthService.js';
import * as DeviceRegistry from '../identity/DeviceRegistry.js';
import { env } from '../config/env.js';
import { rateLimit } from '../middleware/rateLimit.js';
import { auditFromRequest } from '../security/auditLog.js';
import { route, validate, requireAuth, noStore, unauthorised } from './_helpers.js';

const router = Router();

const REFRESH_COOKIE = 'cp_refresh';

const DURATION_UNITS = { s: 1_000, m: 60_000, h: 3_600_000, d: 86_400_000 };

/**
 * '30d' -> 2592000000.
 *
 * env.REFRESH_TTL is a duration *string* — config/env.js validates it against
 * /^\d+[smhd]$/ and hands it over unparsed. Multiplying it by 1000 yields NaN,
 * and a cookie with Max-Age=NaN is one the browser discards, which shows up
 * later as "signing in works but a reload signs me out".
 */
const toMilliseconds = (value) => {
  const amount = Number.parseInt(value, 10);
  return amount * DURATION_UNITS[value.at(-1)];
};

const refreshCookieOptions = () => ({
  httpOnly: true,
  secure: env.NODE_ENV === 'production',
  // 'lax' rather than 'strict': a strict cookie is withheld on any request that
  // began as a navigation, so arriving at the app from a link or a calendar
  // invite would look exactly like being signed out. Lax still refuses to send
  // it on a cross-site POST, which is the case CSRF actually cares about.
  sameSite: 'lax',
  // The whole app, not just /auth. Scoping it to /auth means the browser never
  // attaches it to anything else — which is fine in principle, but it also
  // means a stale or missing cookie is invisible everywhere else in the app.
  path: '/',
  maxAge: toMilliseconds(env.REFRESH_TTL),
  signed: true,
});

const deviceSchema = z.object({
  deviceId: z.string().max(128).optional(),
  platform: z.enum(['web', 'ios', 'android']).default('web'),
  model: z.string().max(128).optional(),
  appVersion: z.string().max(32).optional(),
});

/**
 * AuthService.refresh needs the session id as well as the token — Sessions.rotate
 * looks the family up by id and compares the presented token against it. The
 * cookie therefore carries both, joined by a dot: a uuid contains none and a
 * base64url token contains none, so the split is unambiguous.
 */
function issue(res, tokens) {
  const cookieValue = `${tokens.sessionId}.${tokens.refreshToken}`;
  res.cookie(REFRESH_COOKIE, cookieValue, refreshCookieOptions());
  noStore(res);
  return {
    accessToken: tokens.accessToken,
    expiresIn: tokens.expiresIn,
    tokenType: 'Bearer',
    user: tokens.user,
    // The refresh token is never in the body on web. Mobile asks for it
    // explicitly below.
  };
}

/* ------------------------------------------------------------------ *
 * CSRF bootstrap
 * ------------------------------------------------------------------ */

/**
 * Hands out the double-submit token.
 *
 * The SPA is served from CloudFront and the API from a different origin, so a
 * page load never touches this server and the CSRF cookie is never issued as a
 * side effect of one. Without a route that does it deliberately, a client's
 * very first call to /auth/refresh arrives with no cookie and is rejected — on
 * every cold start, for every visitor.
 *
 * GET is in csrfConfig.ignoredMethods, so this passes the check it bootstraps.
 * The middleware has already put the value — existing or freshly minted — on
 * req.csrfToken and the Set-Cookie on the response; this only returns it, so
 * the client never has to know the cookie's name.
 */
router.get(
  '/csrf',
  route(async (req, res) => {
    noStore(res);
    return { csrfToken: req.csrfToken ?? null };
  }),
);

/* ------------------------------------------------------------------ *
 * Credentials
 * ------------------------------------------------------------------ */

router.post(
  '/login',
  rateLimit({ key: 'auth:login', points: 10, durationSec: 300, by: ['ip', 'body.email'] }),
  validate({
    body: z.object({
      email: z.string().email(),
      password: z.string().min(1).max(512),
      device: deviceSchema.optional(),
      // Mobile cannot use a cookie; it gets the refresh token in the body.
      wantsRefreshToken: z.boolean().default(false),
    }),
  }),
  route(async (req, res) => {
    const tokens = await AuthService.login({
      email: req.body.email,
      password: req.body.password,
      device: req.body.device ?? { platform: 'web' },
      ip: req.ip,
      userAgent: req.get('user-agent') ?? null,
    });

    // Two-step sign-in: no cookie, no token — only the challenge.
    if (tokens.secondFactorRequired) {
      noStore(res);
      return {
        secondFactorRequired: true,
        challengeId: tokens.challengeId,
        methods: tokens.methods,
        expiresInSec: tokens.expiresInSec,
      };
    }

    return respondWithSession(req, res, tokens);
  }),
);

/** Tokens as /login has always answered them. */
function respondWithSession(req, res, tokens) {
  const body = issue(res, tokens);
  if (req.body?.wantsRefreshToken) {
    body.refreshToken = tokens.refreshToken;
    // The client needs this to refresh; Sessions.rotate looks the family up
    // by id, not by token.
    body.sessionId = tokens.sessionId;
  }
  return body;
}

/** A refused second step, recorded on the account it was for, so its owner sees it. */
const auditSecondStepFailure = async (req, challengeId, method) => {
  try {
    const { read } = await import('../identity/loginChallenge.js');
    const challenge = await read(challengeId);
    if (!challenge?.userId) return;
    const asAccount = Object.create(req);
    asAccount.user = { id: challenge.userId, userId: challenge.userId };
    await auditFromRequest(asAccount, {
      action: 'auth.second_factor.failed',
      targetType: 'user',
      targetId: challenge.userId,
      metadata: { method },
    });
  } catch {
    // History is best effort; the refusal itself already happened.
  }
};

const secondStepBody = z.object({
  challengeId: z.string().min(16).max(128),
  device: deviceSchema.optional(),
  wantsRefreshToken: z.boolean().default(false),
});

router.post(
  '/login/second-factor',
  rateLimit({ key: 'auth:second-factor', points: 20, durationSec: 300, by: ['ip'] }),
  validate({ body: secondStepBody.extend({ code: z.string().min(6).max(20) }) }),
  route(async (req, res) => {
    let tokens;
    try {
      tokens = await AuthService.completeSecondFactor({
        challengeId: req.body.challengeId,
        code: req.body.code,
        device: req.body.device,
      });
    } catch (error) {
      if (error?.code === 'unauthenticated') await auditSecondStepFailure(req, req.body.challengeId, 'code');
      throw error;
    }
    return respondWithSession(req, res, tokens);
  }),
);

router.post(
  '/login/second-factor/passkey/options',
  rateLimit({ key: 'auth:passkey-options', points: 30, durationSec: 300, by: ['ip'] }),
  validate({ body: z.object({ challengeId: z.string().min(16).max(128) }) }),
  route(async (req, res) => {
    noStore(res);
    return AuthService.secondFactorPasskeyOptions({
      challengeId: req.body.challengeId,
      requestOrigin: req.get('origin') ?? null,
    });
  }),
);

const passkeyResponse = z.object({ id: z.string().min(1).max(1024) }).passthrough();

router.post(
  '/login/second-factor/passkey',
  rateLimit({ key: 'auth:second-factor', points: 20, durationSec: 300, by: ['ip'] }),
  validate({ body: secondStepBody.extend({ optionsId: z.string().uuid(), response: passkeyResponse }) }),
  route(async (req, res) => {
    let tokens;
    try {
      tokens = await AuthService.completeSecondFactorWithPasskey({
        challengeId: req.body.challengeId,
        optionsId: req.body.optionsId,
        response: req.body.response,
        device: req.body.device,
      });
    } catch (error) {
      if (error?.code === 'unauthenticated') await auditSecondStepFailure(req, req.body.challengeId, 'passkey');
      throw error;
    }
    return respondWithSession(req, res, tokens);
  }),
);

/** Sign in with a passkey alone: the browser offers the passkeys it holds for this site. */
router.post(
  '/passkey/options',
  rateLimit({ key: 'auth:passkey-options', points: 30, durationSec: 300, by: ['ip'] }),
  route(async (req, res) => {
    noStore(res);
    return AuthService.passkeySignInOptions({ requestOrigin: req.get('origin') ?? null });
  }),
);

router.post(
  '/passkey',
  rateLimit({ key: 'auth:login', points: 10, durationSec: 300, by: ['ip'] }),
  validate({
    body: z.object({
      optionsId: z.string().uuid(),
      response: passkeyResponse,
      device: deviceSchema.optional(),
      wantsRefreshToken: z.boolean().default(false),
    }),
  }),
  route(async (req, res) => {
    const tokens = await AuthService.signInWithPasskey({
      optionsId: req.body.optionsId,
      response: req.body.response,
      device: req.body.device ?? { platform: 'web' },
    });
    return respondWithSession(req, res, tokens);
  }),
);

/**
 * Cookie route. CSRF is enforced by the global csrfProtection() in app.js,
 * which covers every path in securityConfig.csrf.protectedPaths. Mobile sends
 * the refresh token in the body and skips the cookie path entirely.
 */
router.post(
  '/refresh',
  rateLimit({ key: 'auth:refresh', points: 60, durationSec: 300, by: ['ip'] }),
  validate({ body: z.object({ refreshToken: z.string().min(1).optional() }).default({}) }),
  route(async (req, res) => {
    const presented = req.body.refreshToken ?? req.signedCookies?.[REFRESH_COOKIE];
    if (!presented) throw unauthorised('No refresh token presented');

    // Mobile sends a bare token in the body and its session id beside it; web
    // sends the combined cookie.
    const dot = presented.indexOf('.');
    const sessionId = req.body.sessionId ?? (dot > 0 ? presented.slice(0, dot) : null);
    const refreshToken = dot > 0 ? presented.slice(dot + 1) : presented;

    if (!sessionId) throw unauthorised('No session presented');

    // The export is `refresh`. Rotation is what it does, not what it is called.
    let tokens;
    try {
      tokens = await AuthService.refresh({
        sessionId,
        refreshToken,
        device: req.body.device ?? { platform: 'web' },
      });
    } catch (error) {
      if (error?.code === 'token_revoked' || error?.code === 'unauthenticated') {
        res.clearCookie(REFRESH_COOKIE, { ...refreshCookieOptions(), maxAge: undefined });
      }
      throw error;
    }

    const body = issue(res, tokens);
    if (req.body.refreshToken) body.refreshToken = tokens.refreshToken;
    return body;
  }),
);

router.post(
  '/logout',
  route(async (req, res) => {
    const presented = req.body?.refreshToken ?? req.signedCookies?.[REFRESH_COOKIE];
    const dot = presented?.indexOf('.') ?? -1;
    const sessionId = dot > 0 ? presented.slice(0, dot) : null;

    // `logout`, not `revokeSession` — and it takes the session, not the token.
    if (sessionId) {
      await AuthService.logout({
        sessionId,
        jti: req.user?.jti ?? null,
        accessTokenExpiresAt: req.user?.expiresAt ?? null,
      }).catch(() => {});
    }
    res.clearCookie(REFRESH_COOKIE, { ...refreshCookieOptions(), maxAge: undefined });
    noStore(res);
    return { loggedOut: true };
  }),
);

/** Every device, everywhere — the "I lost my phone" button. */
router.post(
  '/logout-all',
  requireAuth,
  route(async (req, res) => {
    const revoked = await AuthService.logoutEverywhere({ userId: req.user.id });
    res.clearCookie(REFRESH_COOKIE, { ...refreshCookieOptions(), maxAge: undefined });
    noStore(res);
    return { revoked };
  }),
);

/* ------------------------------------------------------------------ *
 * Device sessions and push tokens
 * ------------------------------------------------------------------ */

router.get(
  '/devices',
  requireAuth,
  route(async (req, res) => {
    noStore(res);
    return { devices: await DeviceRegistry.listForUser(req.user.id) };
  }),
);

router.delete(
  '/devices/:deviceId',
  requireAuth,
  validate({ params: z.object({ deviceId: z.string().max(128) }) }),
  route(async (req) => {
    await AuthService.revokeDeviceSession(req.user.id, req.params.deviceId);
    return null;
  }),
);

router.put(
  '/devices/push-token',
  requireAuth,
  validate({
    body: z.object({
      deviceId: z.string().max(128),
      platform: z.enum(['ios', 'android', 'web']),
      token: z.string().min(1).max(512),
    }),
  }),
  route(async (req) => {
    const registration = await DeviceRegistry.upsertPushToken({
      userId: req.user.id,
      ...req.body,
    });
    return { registered: true, endpointArn: registration.endpointArn ?? null };
  }),
);

/** Who am I — cheap enough to call on app boot, and it proves the token is live. */
router.get(
  '/me',
  requireAuth,
  route(async (req, res) => {
    noStore(res);
    return AuthService.describeSession({ userId: req.user.id, sessionId: req.user.sessionId });
  }),
);

export default router;
