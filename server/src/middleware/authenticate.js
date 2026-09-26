import { ApiError } from '@classroom/contracts';
import { verifyAccessToken } from '../identity/AuthService.js';
import * as Users from '../identity/User.js';
import * as SessionActivity from '../security/sessionActivity.js';

/**
 * Who is asking  (F5 · Settings Phase B)
 *
 * Verifies the bearer token and puts the account on req.user. Phase B adds
 * three things around it (security/sessionActivity.js):
 *
 *   - a session signed out from another device is refused at once, with the
 *     same token_revoked answer as any other revoked token
 *   - browser, IP and last activity of the session are kept for the device
 *     list, and the first request of a session is recorded as its sign-in
 *   - a rejected POST /auth/login is recorded on the account it tried
 */

const bearerToken = (req) => {
  const value = req.get('authorization');
  if (!value) return null;
  if (!value.startsWith('Bearer ')) {
    throw new ApiError('unauthenticated', { detail: 'Invalid authorization header.' });
  }
  const token = value.slice(7).trim();
  if (!token) throw new ApiError('unauthenticated', { detail: 'No access token presented.' });
  return token;
};

export const authenticate = () => async (req, res, next) => {
  SessionActivity.observeSignInAttempt(req, res);
  try {
    const token = bearerToken(req);
    if (!token) return next();

    const claims = await verifyAccessToken(token);

    if (await SessionActivity.isRevoked(claims.sessionId)) {
      // Same answer as an expired token: the client tries to refresh, the
      // refresh is refused (the session is revoked) and it signs out.
      return next(new ApiError('unauthenticated', { detail: 'This device was signed out.' }));
    }

    const user = await Users.findById(claims.userId);

    if (!user || user.status !== 'active') {
      return next(new ApiError('unauthenticated', { detail: 'Sign in to continue.' }));
    }

    req.user = {
      ...user,
      id: user.userId,
      sessionId: claims.sessionId,
      jti: claims.jti,
      issuedAt: claims.issuedAt,
      expiresAt: claims.expiresAt,
    };

    void SessionActivity.touch(req);
    return next();
  } catch (error) {
    return next(error);
  }
};

export default authenticate;
