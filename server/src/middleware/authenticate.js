import { ApiError } from '@classroom/contracts';
import { verifyAccessToken } from '../identity/AuthService.js';
import * as Users from '../identity/User.js';

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

export const authenticate = () => async (req, _res, next) => {
  try {
    const token = bearerToken(req);
    if (!token) return next();

    const claims = await verifyAccessToken(token);
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
    return next();
  } catch (error) {
    return next(error);
  }
};

export default authenticate;