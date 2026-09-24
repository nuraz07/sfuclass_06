// classroom-app/server/src/messaging/SessionBlocks.js
/**
 * Blocking for one lesson  (F1, F6)
 *
 * "Block for this session": someone in a live room stops a particular person
 * from writing to them privately — for as long as that lesson runs, not for
 * the whole account. The account-wide block (Settings → Blocked people) is
 * identity/Profile.block and a separate thing.
 *
 * Effect, while it lasts: neither of the two can open a private chat with the
 * other, and messages between them in an existing private chat are refused.
 * The same rule as an account block, deliberately — a one-sided block would
 * let the blocker keep writing to someone who cannot answer.
 *
 * Storage (state Redis, never evicted):
 *   <prefix>:sblock:<blockerId>:<blockedId>   → roomId      TTL 12 h
 *   <prefix>:sblock-room:<roomId>             → set of "<blockerId>:<blockedId>"
 *
 * The room set is how RoomManager.closeRoom ends every block of a lesson when
 * the lesson ends. The TTL is only the backstop for a process that died before
 * it could clean up.
 */

import { ApiError } from '@classroom/contracts';
import { env } from '../config/env.js';
import { stateRedis as redis } from '../db/redis.js';

const TTL_SEC = 12 * 60 * 60;

const pairKey = (blockerId, blockedId) => `${env.REDIS_PREFIX}:sblock:${blockerId}:${blockedId}`;
const roomKey = (roomId) => `${env.REDIS_PREFIX}:sblock-room:${roomId}`;

export const block = async ({ roomId, blockerId, blockedId }) => {
  if (!roomId || !blockerId || !blockedId || blockerId === blockedId) {
    throw new ApiError('validation_failed', { detail: 'You cannot block yourself.' });
  }
  // Separate commands rather than MULTI: the keys may live in different
  // cluster slots, and nothing here needs to be atomic.
  await redis.set(pairKey(blockerId, blockedId), roomId, 'EX', TTL_SEC);
  await redis.sadd(roomKey(roomId), `${blockerId}:${blockedId}`);
  await redis.expire(roomKey(roomId), TTL_SEC);
  return { roomId, blockedUserId: blockedId };
};

export const unblock = async ({ roomId, blockerId, blockedId }) => {
  await redis.del(pairKey(blockerId, blockedId));
  await redis.srem(roomKey(roomId), `${blockerId}:${blockedId}`);
  return { roomId, blockedUserId: blockedId };
};

/** Whom `blockerId` has blocked in this lesson. */
export const listFor = async ({ roomId, blockerId }) => {
  const members = await redis.smembers(roomKey(roomId));
  const prefix = `${blockerId}:`;
  return members.filter((member) => member.startsWith(prefix)).map((member) => member.slice(prefix.length));
};

/** True while a lesson block exists between the two, in either direction. */
export const isBlockedEitherWay = async (userA, userB) => {
  if (!userA || !userB) return false;
  const [one, two] = await Promise.all([redis.get(pairKey(userA, userB)), redis.get(pairKey(userB, userA))]);
  return Boolean(one || two);
};

/** The lesson ended: every block made in it ends too. */
export const clearRoom = async (roomId) => {
  const members = await redis.smembers(roomKey(roomId));
  for (const member of members) {
    const [blockerId, blockedId] = member.split(':');
    // Only if the pair still belongs to this lesson; a newer lesson may have
    // set the same pair again.
    if ((await redis.get(pairKey(blockerId, blockedId))) === roomId) {
      await redis.del(pairKey(blockerId, blockedId));
    }
  }
  await redis.del(roomKey(roomId));
  return members.length;
};

export default { block, unblock, listFor, isBlockedEitherWay, clearRoom };
