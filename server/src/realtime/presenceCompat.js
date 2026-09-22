// server/src/realtime/presenceCompat.js
/**
 * Presence, v6 function API  (F2, F6)  [BRIDGE]
 *
 * realtime/PresenceService.js (v7) is a tenant-scoped class without space
 * rosters. Five callers still use the v6 module functions, calling them without
 * a tenant and expecting `state` fields and arrays:
 *
 *   community/SpaceService.js          spaceCounts · getMany
 *   community/NotificationService.js   get
 *   routes/community.routes.js         listForSpace
 *   queues/workers/notificationWorker  get
 *   queues/workers/chatFanoutWorker    get
 *
 * This module is that v6 API, moved onto the cache Redis client and re-exported
 * from realtime/PresenceService.js, so `import * as Presence from
 * '../realtime/PresenceService.js'` resolves every name the callers use.
 *
 * Differences from v6, all required by the v7 Redis model:
 *   - runs on cacheRedis (volatile-lru), so every key carries a TTL, space
 *     rosters included; in v6 they had none and grew forever
 *   - all keys share the hash tag {presence}, so multi-key reads (MGET,
 *     pipelines) stay in one slot on cluster-mode Redis
 *   - pipeline instead of MULTI; nothing here needs atomicity
 *   - a malformed entry reads as offline instead of throwing
 *
 * Retire it once the callers pass a tenantId and the class gains space rosters;
 * then this file and the re-export line in PresenceService.js go together.
 *
 * Writers: heartbeat() and clear() are the calls a presence gateway makes.
 */

import { env } from '../config/env.js';
import { cacheRedis as redis } from '../db/redis.js';

export const STATES = Object.freeze(['online', 'away', 'in-class', 'offline']);

const TAG = '{presence}';
const userKey = (userId) => `${env.REDIS_PREFIX}:${TAG}:user:${userId}`;
const spaceKey = (spaceId) => `${env.REDIS_PREFIX}:${TAG}:space:${spaceId}`;
const channel = `${env.REDIS_PREFIX}:presence:events`;

/** A missed heartbeat should not flicker someone offline; two should. */
const TTL_SEC = Number(env.PRESENCE_TTL_SEC ?? process.env.PRESENCE_TTL_SEC) || 60;
/** A roster outlives its members' entries so a quiet minute does not drop it. */
const SPACE_TTL_SEC = TTL_SEC * 2;

const cutoff = () => Date.now() - TTL_SEC * 1_000;

const offline = (userId) => ({ userId, state: 'offline', roomId: null, updatedAt: null });

const parse = (userId, raw) => {
  if (!raw) return offline(userId);
  try {
    const entry = JSON.parse(raw);
    return {
      userId,
      state: entry.state,
      roomId: entry.roomId ?? null,
      updatedAt: new Date(entry.at).toISOString(),
    };
  } catch {
    return offline(userId);
  }
};

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

/**
 * Records a heartbeat from a connected client. `roomId` is set while the person
 * is in a lesson; `spaceIds` are the spaces whose online counts include them.
 */
export const heartbeat = async ({ userId, state = 'online', roomId = null, spaceIds = [] }) => {
  if (!STATES.includes(state) || state === 'offline') {
    throw new TypeError(`presence: invalid heartbeat state '${state}'`);
  }

  const now = Date.now();
  const pipeline = redis
    .pipeline()
    .set(userKey(userId), JSON.stringify({ state, roomId, at: now }), 'EX', TTL_SEC);

  for (const spaceId of spaceIds) {
    pipeline.zadd(spaceKey(spaceId), now, userId).expire(spaceKey(spaceId), SPACE_TTL_SEC);
  }

  await pipeline.exec();

  // Other realtime tasks push the change to their own sockets.
  await redis.publish(channel, JSON.stringify({ userId, state, roomId })).catch(() => undefined);

  return { state, roomId };
};

/** Explicit sign-out or deliberate disconnect; the TTL would get there a minute later. */
export const clear = async ({ userId, spaceIds = [] }) => {
  const pipeline = redis.pipeline().del(userKey(userId));
  for (const spaceId of spaceIds) pipeline.zrem(spaceKey(spaceId), userId);
  await pipeline.exec();

  await redis
    .publish(channel, JSON.stringify({ userId, state: 'offline', roomId: null }))
    .catch(() => undefined);
};

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

/** Batch lookup, one MGET. A missing key is 'offline', never null. */
export const getMany = async (userIds) => {
  if (!Array.isArray(userIds) || userIds.length === 0) return [];
  const raw = await redis.mget(userIds.map(userKey));
  return userIds.map((userId, index) => parse(userId, raw[index]));
};

export const get = async (userId) => (await getMany([userId]))[0];

export const isOnline = async (userId) => {
  const entry = await get(userId);
  return entry.state === 'online' || entry.state === 'in-class';
};

/** Rosters are trimmed on read, so an unvisited space costs nothing to keep tidy. */
export const spaceOnlineCount = async (spaceId) => {
  await redis.zremrangebyscore(spaceKey(spaceId), 0, cutoff());
  return redis.zcard(spaceKey(spaceId));
};

/** A sample of user ids for the avatar row. */
export const spaceOnlineSample = async (spaceId, limit = 20) => {
  await redis.zremrangebyscore(spaceKey(spaceId), 0, cutoff());
  return redis.zrevrange(spaceKey(spaceId), 0, limit - 1);
};

/** Online counts for many spaces in one round trip: { [spaceId]: count }. */
export const spaceCounts = async (spaceIds) => {
  if (!Array.isArray(spaceIds) || spaceIds.length === 0) return {};
  const min = cutoff();

  const pipeline = redis.pipeline();
  for (const spaceId of spaceIds) {
    pipeline.zremrangebyscore(spaceKey(spaceId), 0, min);
    pipeline.zcard(spaceKey(spaceId));
  }

  const results = await pipeline.exec();
  const counts = {};
  spaceIds.forEach((spaceId, index) => {
    // Two commands per space; the count is the second of each pair.
    counts[spaceId] = results?.[index * 2 + 1]?.[1] ?? 0;
  });
  return counts;
};

/**
 * Everyone currently online in a space, most recent first, with their presence
 * entry: [{ userId, state, roomId, updatedAt }].
 */
export const listForSpace = async (spaceId, { limit = 200 } = {}) => {
  await redis.zremrangebyscore(spaceKey(spaceId), 0, cutoff());
  const userIds = await redis.zrevrange(spaceKey(spaceId), 0, limit - 1);
  const entries = await getMany(userIds);
  return entries.filter((entry) => entry.state !== 'offline');
};