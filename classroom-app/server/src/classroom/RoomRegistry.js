// classroom-app/server/src/classroom/RoomRegistry.js
/**
 * Room registry  (F1, F8)  [EXT]
 *
 * `room:{roomId} → region · nodeId · control address` in the state Redis
 * cluster (section 4.7). Written by RoomPlacementService, read by signaling/
 * and by the ops-only route-resolve route.
 *
 * It answers one question: which SFU node owns this room right now. That makes
 * it the thing that keeps a lesson on one node — a second, third and fiftieth
 * participant are sent to the node the first one landed on, no matter which
 * realtime task their socket happens to hit.
 *
 * Placement is a claim, not a write: `claim()` is a SET NX, so two people
 * joining an empty room in the same millisecond cannot split it across two
 * nodes. The loser gets the winner's placement back and uses it.
 *
 * The entry carries the node's private control address, which is how
 * sfuControlClient reaches it over mTLS on port 7443. That address is internal:
 * it never leaves the VPC, and it never reaches a client.
 *
 * Entries are refreshed while the room is alive and released when it closes. A
 * TTL well past the longest lesson is the backstop for a realtime task that
 * dies mid-session, so a crash cannot pin a room to a dead node forever.
 */

import { z } from 'zod';

/** Longer than any lesson; refreshed on every touch. */
const DEFAULT_TTL_SEC = 6 * 3_600;

export const roomKey = (roomId) => `room:${roomId}`;

const PlacementSchema = z.object({
  roomId: z.uuid(),
  region: z.string().min(1).max(32),
  nodeId: z.string().min(1).max(64),
  /** Private IP or internal DNS name of the node; never public, never a client's business. */
  controlAddress: z.string().min(1).max(253),
  controlPort: z.number().int().min(1).max(65535),
  /** The worker the room's router lives on, so breakouts can be pinned to it. */
  workerIndex: z.number().int().min(0).max(63).nullable().default(null),
  lessonId: z.uuid().nullable().default(null),
  placedAt: z.iso.datetime(),
});

/** @typedef {z.infer<typeof PlacementSchema>} RoomPlacement */

/**
 * @param {object} deps
 * @param {{ get: Function, set: Function, del: Function, expire: Function }} deps.redis
 *        the state-cluster client from db/redis.js (noeviction)
 * @param {object} [deps.logger]
 * @param {number} [deps.ttlSec]
 */
export const createRoomRegistry = ({ redis, logger = console, ttlSec = DEFAULT_TTL_SEC }) => {
  const parse = (raw, roomId) => {
    if (!raw) return null;
    try {
      const result = PlacementSchema.safeParse(JSON.parse(raw));
      if (result.success) return result.data;
      logger.warn?.({ roomId, issues: result.error.issues.length }, 'malformed room placement');
    } catch (cause) {
      logger.warn?.({ roomId, err: cause }, 'unreadable room placement');
    }
    return null;
  };

  /** @returns {Promise<RoomPlacement | null>} */
  const get = async (roomId) => parse(await redis.get(roomKey(roomId)), roomId);

  /**
   * Claims the room for a node. Returns the placement that is actually in
   * force: the one passed in when the claim won, the existing one when it did
   * not. A caller compares `nodeId` to see which happened.
   *
   * @param {Omit<RoomPlacement, 'placedAt'> & { placedAt?: string }} placement
   */
  const claim = async (placement) => {
    const value = PlacementSchema.parse({
      placedAt: new Date().toISOString(),
      ...placement,
    });

    const stored = await redis.set(roomKey(value.roomId), JSON.stringify(value), 'EX', ttlSec, 'NX');
    if (stored) return { placement: value, claimed: true };

    const existing = await get(value.roomId);
    // A key that vanished between SET NX and GET (expired, released): try once
    // more rather than sending the room nowhere.
    if (!existing) {
      await redis.set(roomKey(value.roomId), JSON.stringify(value), 'EX', ttlSec);
      return { placement: value, claimed: true };
    }
    return { placement: existing, claimed: false };
  };

  /**
   * Moves a room to another node: a drained node, a dead node, a cascade that
   * changed the owner. Overwrites unconditionally, because the decision was
   * already made by placement.
   */
  const move = async (roomId, placement) => {
    const value = PlacementSchema.parse({
      roomId,
      placedAt: new Date().toISOString(),
      ...placement,
    });
    await redis.set(roomKey(roomId), JSON.stringify(value), 'EX', ttlSec);
    logger.info?.({ roomId, nodeId: value.nodeId, region: value.region }, 'room re-placed');
    return value;
  };

  /** Keeps a live room's entry from expiring. Called on join, leave and heartbeat. */
  const touch = async (roomId) => {
    const refreshed = await redis.expire(roomKey(roomId), ttlSec);
    return refreshed === 1 || refreshed === true;
  };

  /** The room ended or emptied: the node is free to drain. */
  const release = async (roomId) => {
    const removed = await redis.del(roomKey(roomId));
    return removed === 1 || removed === true;
  };

  /**
   * Releases the entry only when it still points at the given node, so a room
   * that has already been re-placed is not unplaced by a straggler on the old
   * node.
   */
  const releaseIfOn = async (roomId, nodeId) => {
    const existing = await get(roomId);
    if (!existing || existing.nodeId !== nodeId) return false;
    return release(roomId);
  };

  return Object.freeze({ get, claim, move, touch, release, releaseIfOn, roomKey, ttlSec });
};

export { PlacementSchema as RoomPlacementSchema };
export default createRoomRegistry;