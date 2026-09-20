// server/src/realtime/PresenceService.js
//
// Presence of users across the platform — one source of truth for the classroom (F1), the community (F2) and chat
// (F6). Moved here from community/ in v7: presence belongs to the realtime transport, not to one product domain.
//
// Model (cache Redis cluster, db/redis.js — volatile-lru: every key carries a TTL, losing presence is harmless):
//
//   presence:{t:<tenantId>}:user:<userId>      HASH  connectionId → {"status","roomId","at"}     TTL 90 s
//   presence:{t:<tenantId>}:room:<roomId>      ZSET  userId, score = last heartbeat (ms)           TTL 90 s
//
// A user can be connected from several devices and tabs; each Socket.IO connection is one hash field. The user's
// visible status is the strongest fresh one:  in-class > online > away > offline (no fresh connection).
// Connections heartbeat every 25 s (Socket.IO ping); an entry older than 75 s counts as gone, so a crashed task or a
// lost network ends presence within ~75 s without any cleanup job.
//
// Every write runs as one Lua script (all keys of a tenant share the hash tag, i.e. one cluster slot) and returns the
// user's aggregate status before and after, so the gateways broadcast only real transitions:
//   realtime/presenceGateway.js   → presence.changed to the tenant's subscribers
//   signaling/socketHandlers.js   → in-class state and room rosters
//   messaging/chatGateway.js      → online dots in conversations
//
// Visibility (who may see whom) is decided by the gateways (profile privacy, blocking), not here.
//
// Owner: F6 Messaging and Chat (+ F1, F2 as consumers).

const STATUSES = Object.freeze(['in-class', 'online', 'away']);
const RANK = Object.freeze({ 'in-class': 3, online: 2, away: 1, offline: 0 });
const ID = /^[A-Za-z0-9._:-]{1,128}$/;

// KEYS[1] user hash · KEYS[2] room of this operation · KEYS[3] previous room (set only). Unused room keys are a
// placeholder in the same hash tag, so all three keys always share one cluster slot (no CROSSSLOT).
// ARGV: op ("set" | "touch" | "remove"), connectionId, status, roomId, previousRoomId, now, staleMs, ttlSeconds, userId
const WRITE_SCRIPT = `
local userKey, roomKey, prevRoomKey = KEYS[1], KEYS[2], KEYS[3]
local op, conn, status, roomId, prevRoomId = ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]
local now, staleMs, ttl, userId = tonumber(ARGV[6]), tonumber(ARGV[7]), tonumber(ARGV[8]), ARGV[9]
local rank = { ['in-class'] = 3, online = 2, away = 1 }

-- Fresh entries of the user (stale ones are deleted on the way).
local function fresh()
  local out = {}
  local entries = redis.call('HGETALL', userKey)
  for i = 1, #entries, 2 do
    local ok, e = pcall(cjson.decode, entries[i + 1])
    if ok and type(e) == 'table' and tonumber(e.at) and (now - tonumber(e.at)) <= staleMs then
      out[entries[i]] = e
    else
      redis.call('HDEL', userKey, entries[i])
    end
  end
  return out
end

local function aggregate(entries)
  local best, bestRank, bestRoom = 'offline', 0, ''
  for _, e in pairs(entries) do
    local r = rank[e.status] or 0
    if r > bestRank then best, bestRank, bestRoom = e.status, r, (e.roomId or '') end
  end
  return best, bestRoom
end

-- Leave a room roster unless another fresh connection of the user is still in it.
local function leaveIfLast(key, rid, entries)
  if rid == '' then return end
  for c, e in pairs(entries) do
    if e.roomId == rid then return end
  end
  redis.call('ZREM', key, userId)
end

local entries = fresh()
local before, beforeRoom = aggregate(entries)

if op == 'touch' then
  local e = entries[conn]
  if not e then return { before, beforeRoom, before, beforeRoom, 0 } end
  e.at = now
  redis.call('HSET', userKey, conn, cjson.encode(e))
elseif op == 'remove' then
  redis.call('HDEL', userKey, conn)
  entries[conn] = nil
  leaveIfLast(roomKey, roomId, entries)
else
  local e = { status = status, roomId = roomId, at = now }
  redis.call('HSET', userKey, conn, cjson.encode(e))
  entries[conn] = e
  if prevRoomId ~= roomId then leaveIfLast(prevRoomKey, prevRoomId, entries) end
end

if op ~= 'remove' and roomId ~= '' then
  redis.call('ZADD', roomKey, now, userId)
  redis.call('EXPIRE', roomKey, ttl)
end
if redis.call('HLEN', userKey) > 0 then redis.call('EXPIRE', userKey, ttl) end

local after, afterRoom = aggregate(entries)
return { before, beforeRoom, after, afterRoom, 1 }
`;

export class PresenceService {
  /**
   * @param {object} options
   * @param {import('ioredis').Redis | import('ioredis').Cluster} options.redis   cache cluster (db/redis.js)
   * @param {number} [options.staleMs=75000]     a connection without heartbeat for this long is gone
   * @param {number} [options.ttlSeconds=90]     key TTL (covers a missed heartbeat)
   * @param {() => number} [options.now]
   */
  constructor({ redis, staleMs = 75_000, ttlSeconds = 90, now = Date.now }) {
    if (!redis) throw new TypeError('PresenceService: redis is required');
    if (ttlSeconds * 1000 <= staleMs) throw new RangeError('PresenceService: ttlSeconds must exceed staleMs');
    this.redis = redis;
    this.staleMs = staleMs;
    this.ttlSeconds = ttlSeconds;
    this.now = now;
    if (typeof redis.presenceWrite !== 'function') {
      redis.defineCommand('presenceWrite', { numberOfKeys: 3, lua: WRITE_SCRIPT });
    }
  }

  static keys = Object.freeze({
    user: (tenantId, userId) => `presence:{t:${tenantId}}:user:${userId}`,
    room: (tenantId, roomId) => `presence:{t:${tenantId}}:room:${roomId}`,
    none: (tenantId) => `presence:{t:${tenantId}}:none`, // placeholder, never written
  });

  /**
   * A connection announces or changes its status (connect, join or leave a lesson, idle → away).
   * @param {{ tenantId: string, userId: string, connectionId: string, status: 'in-class'|'online'|'away',
   *           roomId?: string | null, previousRoomId?: string | null }} input
   * @returns {Promise<Transition>}
   */
  async set({ tenantId, userId, connectionId, status, roomId = null, previousRoomId = null }) {
    this.#validate({ tenantId, userId, connectionId, roomId, previousRoomId });
    if (!STATUSES.includes(status)) throw new TypeError(`PresenceService: unknown status '${status}'`);
    if (status === 'in-class' && !roomId) throw new TypeError('PresenceService: in-class requires roomId');
    const room = status === 'in-class' ? roomId : null;
    return this.#write('set', { tenantId, userId, connectionId, status, roomId: room, previousRoomId });
  }

  /** Heartbeat of an existing connection (every Socket.IO ping, 25 s). No-op for unknown connections. */
  async heartbeat({ tenantId, userId, connectionId, roomId = null }) {
    this.#validate({ tenantId, userId, connectionId, roomId });
    return this.#write('touch', { tenantId, userId, connectionId, status: '', roomId, previousRoomId: null });
  }

  /** Connection closed (disconnect, task shutdown). */
  async remove({ tenantId, userId, connectionId, roomId = null }) {
    this.#validate({ tenantId, userId, connectionId, roomId });
    return this.#write('remove', { tenantId, userId, connectionId, status: '', roomId, previousRoomId: null });
  }

  /**
   * Aggregate status of many users (conversation lists, participant lists, community avatars).
   * @returns {Promise<Map<string, { status: string, roomId: string | null, lastSeen: number | null }>>}
   */
  async getMany(tenantId, userIds) {
    this.#validate({ tenantId });
    const unique = [...new Set(userIds)].filter((id) => ID.test(id));
    const result = new Map();
    if (unique.length === 0) return result;
    const now = this.now();
    const pipeline = this.redis.pipeline();
    for (const userId of unique) pipeline.hgetall(PresenceService.keys.user(tenantId, userId));
    const replies = await pipeline.exec();
    unique.forEach((userId, i) => {
      const [err, hash] = replies[i];
      result.set(userId, err ? offline() : aggregate(hash, now, this.staleMs));
    });
    return result;
  }

  /** Users currently in a lesson room (fresh within staleMs), most recent first. */
  async roomRoster(tenantId, roomId, { limit = 500 } = {}) {
    this.#validate({ tenantId, roomId });
    const key = PresenceService.keys.room(tenantId, roomId);
    const min = this.now() - this.staleMs;
    await this.redis.zremrangebyscore(key, '-inf', `(${min}`);
    return this.redis.zrevrangebyscore(key, '+inf', min, 'LIMIT', 0, limit);
  }

  async #write(op, { tenantId, userId, connectionId, status, roomId, previousRoomId }) {
    const keys = PresenceService.keys;
    const reply = await this.redis.presenceWrite(
      keys.user(tenantId, userId),
      roomId ? keys.room(tenantId, roomId) : keys.none(tenantId),
      previousRoomId ? keys.room(tenantId, previousRoomId) : keys.none(tenantId),
      op, connectionId, status, roomId ?? '', previousRoomId ?? '', this.now(), this.staleMs, this.ttlSeconds, userId,
    );
    const [before, beforeRoom, after, afterRoom, applied] = reply;
    return {
      userId,
      applied: applied === 1,
      before: { status: before, roomId: beforeRoom || null },
      after: { status: after, roomId: afterRoom || null },
      changed: before !== after || beforeRoom !== afterRoom,
    };
  }

  #validate(ids) {
    for (const [name, value] of Object.entries(ids)) {
      if (value === null || value === undefined) {
        if (['tenantId', 'userId', 'connectionId'].includes(name)) throw new TypeError(`PresenceService: ${name} is required`);
        continue;
      }
      if (!ID.test(value)) throw new TypeError(`PresenceService: invalid ${name}`);
    }
  }
}

function offline() {
  return { status: 'offline', roomId: null, lastSeen: null };
}

function aggregate(hash, now, staleMs) {
  let best = offline();
  let lastSeen = null;
  for (const raw of Object.values(hash ?? {})) {
    let entry;
    try {
      entry = JSON.parse(raw);
    } catch {
      continue;
    }
    if (typeof entry.at !== 'number') continue;
    lastSeen = Math.max(lastSeen ?? 0, entry.at);
    if (now - entry.at > staleMs) continue;
    if ((RANK[entry.status] ?? 0) > RANK[best.status]) best = { status: entry.status, roomId: entry.roomId || null };
  }
  return { ...best, lastSeen };
}

/**
 * @typedef {{ userId: string, applied: boolean, changed: boolean,
 *             before: { status: string, roomId: string | null }, after: { status: string, roomId: string | null } }} Transition
 */