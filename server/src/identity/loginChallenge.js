// classroom-app/server/src/identity/loginChallenge.js
/**
 * The second step of a sign-in  (Settings, Phase C)
 *
 * After a correct password, someone with two-step sign-in gets a challenge
 * instead of a session. Nothing is signed in yet: no session exists, no token
 * is issued, no socket can open. Only a code or a passkey turns the challenge
 * into a session (AuthService.completeSecondFactor).
 *
 * A challenge lives five minutes and allows five wrong codes; after that the
 * password has to be entered again.
 */

import { randomBytes, createHash } from 'node:crypto';
import { env } from '../config/env.js';
import { stateRedis as redis } from '../db/redis.js';

const TTL_SEC = 5 * 60;
export const MAX_ATTEMPTS = 5;

const key = (challengeId) =>
  `${env.REDIS_PREFIX}:login-challenge:${createHash('sha256').update(String(challengeId)).digest('base64url')}`;

export const create = async ({ userId, device = {} }) => {
  const challengeId = randomBytes(24).toString('base64url');
  await redis.set(key(challengeId), JSON.stringify({ userId, device, attempts: 0 }), 'EX', TTL_SEC);
  return { challengeId, expiresInSec: TTL_SEC };
};

export const read = async (challengeId) => {
  if (!challengeId) return null;
  const raw = await redis.get(key(challengeId));
  return raw ? JSON.parse(raw) : null;
};

/** A wrong code. Returns the attempts left; at zero the challenge is gone. */
export const recordFailure = async (challengeId) => {
  const record = await read(challengeId);
  if (!record) return 0;
  record.attempts += 1;
  const left = MAX_ATTEMPTS - record.attempts;
  if (left <= 0) {
    await redis.del(key(challengeId));
    return 0;
  }
  const ttl = await redis.ttl(key(challengeId));
  await redis.set(key(challengeId), JSON.stringify(record), 'EX', Math.max(ttl, 1));
  return left;
};

/** Used up: a challenge makes exactly one session. */
export const consume = async (challengeId) => {
  const raw = await redis.getdel(key(challengeId));
  return raw ? JSON.parse(raw) : null;
};

export default { create, read, recordFailure, consume, MAX_ATTEMPTS };
