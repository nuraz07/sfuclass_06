#!/usr/bin/env bash
# rooms-links-install.sh — Rooms update: links always use the public address.
#
# Run from the project folder (the one containing server/, packages/ and apps/):
#   bash rooms-links-install.sh                  (in a Codespace: also makes port 5173 public)
#   bash rooms-links-install.sh --keep-private   (links fixed, ports left as they are)
#
# Room links, QR codes, calendar files, reminder and invitation emails,
# password-reset and verification links were built from APP_URL, which is
# http://localhost:5173 in development. They now use the address the app is
# really reachable at — worked out on every start (Codespaces, Gitpod,
# PUBLIC_APP_URL, APP_URL), so a fresh clone in a new Codespace needs no
# editing.
#
# Writes 9 files, patches 3 more, keeps a backup in
# .rooms-links-backup/<timestamp>/, checks everything and restarts API and worker.
# Undo: bash rooms-links-install.sh --restore
set -euo pipefail

if [ ! -d server/src/messaging ] || [ ! -d packages/core-client/src ] || [ ! -d apps/web/src ]; then
  echo "Run this from the project folder (the one that contains server/, packages/ and apps/)." >&2
  exit 1
fi

TOUCHED=(
  server/src/config/publicUrlRules.js
  server/src/config/publicUrl.js
  server/src/rooms/ScheduledRooms.js
  server/src/routes/scheduledRooms.routes.js
  server/test/rooms/publicUrl.check.mjs
  packages/core-client/src/api/roomsApi.ts
  apps/web/src/components/Rooms/roomModel.js
  apps/web/src/components/Rooms/__checks__/roomModel.check.mjs
  apps/web/src/pages/RoomLobbyPage.jsx
  server/src/notifications/config.js
  server/src/identity/AuthService.js
  server/src/identity/passkeys.js
)

if [ "${1:-}" = "--restore" ]; then
  FIRST=$(ls -1d .rooms-links-backup/* 2>/dev/null | head -1 || true)
  [ -n "$FIRST" ] || { echo "No backup found." >&2; exit 1; }
  for f in "${TOUCHED[@]}"; do
    if [ -f "$FIRST/$f" ]; then mkdir -p "$(dirname "$f")"; cp "$FIRST/$f" "$f"; echo "restored $f";
    elif [ -f "$f" ]; then rm "$f"; echo "removed $f (did not exist before)"; fi
  done
  touch server/src/server.js 2>/dev/null || true
  [ -f server/src/worker.js ] && touch server/src/worker.js || true
  echo "Restored from $FIRST. Port visibility in the Codespace is left as it is."
  exit 0
fi

KEEP_PRIVATE=0
[ "${1:-}" = "--keep-private" ] && KEEP_PRIVATE=1

MISSING=()
need() { # need <file> <text> <why>
  if [ ! -f "$1" ]; then MISSING+=("$1 is missing ($3)");
  elif ! grep -qF -- "$2" "$1"; then MISSING+=("$1 has no '$2' ($3)"); fi
}
need server/src/rooms/ScheduledRooms.js "export const roomUrl" "the rooms feature"
need server/src/routes/scheduledRooms.routes.js "/:code/qr" "the rooms feature"
need apps/web/src/pages/RoomLobbyPage.jsx "SharePanel" "the rooms feature"
need server/src/notifications/config.js "appUrl" "Settings Phase B"
need server/src/identity/passkeys.js "relyingParty" "Settings Phase C"
need server/src/identity/AuthService.js "reset-password" "sign-in"
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "This tree does not match what this update expects. Nothing was changed:" >&2
  for m in "${MISSING[@]}"; do echo "  - $m" >&2; done
  exit 1
fi

BACKUP=".rooms-links-backup/$(date +%Y%m%d-%H%M%S)"
for f in "${TOUCHED[@]}"; do
  if [ -f "$f" ]; then mkdir -p "$BACKUP/$(dirname "$f")"; cp "$f" "$BACKUP/$f"; fi
done
echo "backup: $BACKUP"

mkdir -p server/src/config
cat > server/src/config/publicUrlRules.js <<'__RL_EOF__'
// classroom-app/server/src/config/publicUrlRules.js
/**
 * Pure rules behind config/publicUrl.js: which address a link should use.
 * No env.js import, so the checks can run without a configured environment
 * (server/test/rooms/publicUrl.check.mjs).
 */

const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '0.0.0.0', '[::1]', '::1']);

export const originOf = (value) => {
  try {
    const url = new URL(String(value));
    return url.protocol === 'http:' || url.protocol === 'https:' ? url.origin : null;
  } catch {
    return null;
  }
};

export const isLocalOrigin = (origin) => {
  try {
    return LOCAL_HOSTS.has(new URL(origin).hostname);
  } catch {
    return false;
  }
};

const portOf = (origin) => {
  const url = new URL(origin);
  return url.port || (url.protocol === 'https:' ? '443' : '80');
};

/**
 * The forwarded address of a local port in a hosted workspace, or null.
 * Pure: takes the environment as a parameter so it can be tested.
 */
export const hostedWorkspaceUrl = ({ environment, port }) => {
  if (environment.CODESPACE_NAME) {
    const domain = environment.GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN || 'app.github.dev';
    return `https://${environment.CODESPACE_NAME}-${port}.${domain}`;
  }
  if (environment.GITPOD_WORKSPACE_URL) {
    const workspace = originOf(environment.GITPOD_WORKSPACE_URL);
    if (workspace) return `https://${port}-${new URL(workspace).host}`;
  }
  return null;
};

/** Pure version of publicAppUrl(). */
export const resolvePublicAppUrl = ({ environment = {}, appUrl = null } = {}) => {
  const explicit = originOf(environment.PUBLIC_APP_URL);
  if (explicit) return explicit;

  const configured = originOf(appUrl) ?? 'http://localhost:5173';
  if (isLocalOrigin(configured)) {
    const hosted = hostedWorkspaceUrl({ environment, port: portOf(configured) });
    if (hosted) return hosted;
  }
  return configured;
};

/** Pure: which address a link for this request should use. */
export const chooseLinkOrigin = ({ candidates, fallback, trusted }) => {
  for (const candidate of candidates) {
    const origin = originOf(candidate);
    if (!origin || !trusted(origin)) continue;
    // A local address works only on this machine; a shared link must not use it.
    if (isLocalOrigin(origin) && !isLocalOrigin(fallback)) continue;
    return origin;
  }
  return fallback;
};
__RL_EOF__
echo "wrote server/src/config/publicUrlRules.js"

mkdir -p server/src/config
cat > server/src/config/publicUrl.js <<'__RL_EOF__'
// classroom-app/server/src/config/publicUrl.js
/**
 * The address people open the app at  (Rooms · links)
 *
 * APP_URL in .env is where the app runs for the developer — usually
 * http://localhost:5173. That is the wrong address for a link somebody else
 * opens: a room invitation, a reminder email, a QR code, a calendar entry,
 * a password reset. This module works out the public address instead, and
 * does it by itself on every start, so a fresh clone in a new Codespace (a
 * new address every time) needs no editing.
 *
 * In order:
 *
 *   1. PUBLIC_APP_URL          set it to pin the address, e.g. in production
 *                              or behind your own domain
 *   2. the hosted workspace    when APP_URL points at this machine and the
 *                              app runs in GitHub Codespaces or Gitpod: the
 *                              forwarded address of APP_URL's port
 *   3. APP_URL                 as configured
 *
 * For a request from a browser, publicAppUrlFor(req) prefers the address
 * that browser is actually on (Origin, then Referer, then ?origin=) — when it
 * is one this app trusts and not a local address that nobody else can open.
 *
 * Read from process.env, not config/env.js: PUBLIC_APP_URL is optional and
 * not part of the env schema that check-env-schema.js compares.
 */

import { env, isProduction } from './env.js';
import {
  chooseLinkOrigin,
  isLocalOrigin,
  originOf,
  resolvePublicAppUrl,
} from './publicUrlRules.js';

export { chooseLinkOrigin, hostedWorkspaceUrl, isLocalOrigin, originOf, resolvePublicAppUrl } from './publicUrlRules.js';

let cached = null;

/** The public address of the web app, without a trailing slash. */
export const publicAppUrl = () => {
  cached ??= resolvePublicAppUrl({ environment: process.env, appUrl: env.APP_URL ?? process.env.APP_URL });
  return cached;
};

/** Origins a browser may legitimately be on. */
export const isTrustedOrigin = (origin, { environment = process.env, production = isProduction } = {}) => {
  if (!origin) return false;
  const trusted = new Set(
    [publicAppUrl(), originOf(env.APP_URL ?? environment.APP_URL), ...(env.ALLOWED_ORIGINS ?? []).map(originOf)].filter(Boolean),
  );
  if (trusted.has(origin)) return true;
  if (production) return false;
  // Development: this workspace's own forwarded addresses, and this machine.
  const host = new URL(origin).hostname;
  if (isLocalOrigin(origin)) return true;
  if (environment.CODESPACE_NAME) {
    const domain = environment.GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN || 'app.github.dev';
    return host.startsWith(`${environment.CODESPACE_NAME}-`) && host.endsWith(`.${domain}`);
  }
  return false;
};

/** The address to put in a link produced for this request. */
export const publicAppUrlFor = (req) =>
  chooseLinkOrigin({
    candidates: [req?.get?.('origin'), req?.get?.('referer'), req?.query?.origin].filter(Boolean),
    fallback: publicAppUrl(),
    trusted: (origin) => isTrustedOrigin(origin),
  });

export default publicAppUrl;
__RL_EOF__
echo "wrote server/src/config/publicUrl.js"

mkdir -p server/src/rooms
cat > server/src/rooms/ScheduledRooms.js <<'__RL_EOF__'
// classroom-app/server/src/rooms/ScheduledRooms.js
/**
 * Rooms people create themselves  (Rooms)
 *
 * A created room is a scheduled session (scheduling/ScheduleService, 010 +
 * 024) with a room code of its own. This module is everything around it:
 *
 *   create · preview · update · cancel · extend · end    for the host
 *   detail, entry decision, knock, waiting list          for the lobby
 *   admissionFor · applyToRoom                           for the socket join
 *   startEnforcer                                        closes rooms at their
 *                                                        end time, hands freed
 *                                                        seats to the waiting
 *                                                        list, marks rooms ended
 *
 * The rules themselves (when the doors open, who may enter) are pure and live
 * in rooms/roomRules.js. Short-lived state — who was already in, who knocked,
 * who was let in, the waiting list, held seats — is in Redis next to the
 * seats (capacity/CapacityGuard) and expires a day after the room ends.
 *
 * Ad-hoc rooms (any other id in /rooms/<id>) are untouched: admissionFor()
 * answers null for them and the join works exactly as before.
 */

import { env, isProduction } from '../config/env.js';
import { publicAppUrl } from '../config/publicUrl.js';
import { pool } from '../db/pool.js';
import { stateRedis as redis } from '../db/redis.js';
import { logger } from '../observability/logger.js';
import * as Rules from './roomRules.js';

const log = logger.child({ component: 'scheduled-rooms' });

const P = env.REDIS_PREFIX;
const keys = {
  joined: (code) => `${P}:room:${code}:joined`,
  admitted: (code) => `${P}:room:${code}:admitted`,
  knocks: (code) => `${P}:room:${code}:knocks`,
  waitlist: (code) => `${P}:room:${code}:waitlist`,
  holds: (code) => `${P}:room:${code}:holds`,
  withWaitlist: () => `${P}:rooms:with-waitlist`,
  enforcerLock: () => `${P}:rooms:enforcer-lock`,
};

const fail = (code, message, details) => {
  throw Object.assign(new Error(message), { code, details });
};

const iso = (value) => (value ? new Date(value).toISOString() : null);

// ---------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------

const COLUMNS = `
  s.id, s.tenant_id, s.series_id, s.host_id, s.room_id, s.room_code, s.title, s.description,
  s.starts_at, s.ends_at, s.time_zone, s.status, s.sequence, s.recurrence,
  s.early_entry_min, s.late_join_min, s.capacity, s.access, s.approval,
  s.cohost_ids, s.room_settings, s.created_at, s.cancelled_at, s.cancel_reason
`;

const toRoom = (row) =>
  row && {
    id: row.id,
    tenantId: row.tenant_id,
    seriesId: row.series_id,
    hostId: row.host_id,
    code: row.room_code,
    title: row.title,
    description: row.description,
    startsAt: iso(row.starts_at),
    endsAt: iso(row.ends_at),
    timeZone: row.time_zone,
    status: row.status,
    sequence: row.sequence,
    recurrence: row.recurrence,
    earlyEntryMinutes: row.early_entry_min,
    lateJoinMinutes: row.late_join_min,
    capacity: row.capacity,
    access: row.access,
    approval: row.approval,
    cohostIds: row.cohost_ids ?? [],
    settings: row.room_settings ?? {},
    createdAt: iso(row.created_at),
    cancelledAt: iso(row.cancelled_at),
    cancelReason: row.cancel_reason ?? null,
  };

export const findByCode = async (code, client = pool) => {
  if (!Rules.isRoomCode(code)) return null;
  const { rows } = await client.query(`SELECT ${COLUMNS} FROM scheduled_sessions s WHERE s.room_code = $1`, [code]);
  return toRoom(rows[0]);
};

const isInvited = async (sessionId, userId) => {
  const { rows } = await pool.query(
    `SELECT 1 FROM session_invitees WHERE session_id = $1 AND user_id = $2`,
    [sessionId, userId],
  );
  return rows.length > 0;
};

const tenantOfUser = async (userId) => {
  const { rows } = await pool.query(`SELECT tenant_id FROM users WHERE id = $1 AND deleted_at IS NULL`, [userId]);
  return rows[0]?.tenant_id ?? null;
};

export const relationFor = async (room, { userId, tenantId = null }) => {
  const tenant = tenantId ?? (await tenantOfUser(userId));
  const sameTenant = tenant === room.tenantId;
  if (!sameTenant) return null;
  return Rules.relationOf(room, { userId, invited: await isInvited(room.id, userId), sameTenant });
};

/** Seats for learners: the room's own limit, never above the platform maximum. */
export const capacityOf = (room) => Math.min(room.capacity ?? Rules.CAPACITY.max, Rules.CAPACITY.max);

// ---------------------------------------------------------------------------
// Redis state
// ---------------------------------------------------------------------------

const expireWithRoom = async (key, room) => {
  const at = Math.floor(new Date(room.endsAt).getTime() / 1000) + 86_400;
  await redis.expireat(key, at).catch(() => undefined);
};

const liveHolds = async (room) => {
  const raw = (await redis.hgetall(keys.holds(room.code)).catch(() => ({}))) ?? {};
  const now = Date.now();
  const holds = new Map();
  for (const [userId, expiry] of Object.entries(raw)) {
    if (Number(expiry) > now) holds.set(userId, Number(expiry));
    else void redis.hdel(keys.holds(room.code), userId).catch(() => undefined);
  }
  return holds;
};

const occupancyOf = async (room) => {
  try {
    const { occupancy } = await import('../capacity/CapacityGuard.js');
    return await occupancy(room.code);
  } catch {
    return { occupied: 0, userIds: [] };
  }
};

/** Everything the entry decision needs about one person, read together. */
const stateFor = async (room, userId) => {
  const [joined, admitted, knocked, position, holds, seats] = await Promise.all([
    redis.sismember(keys.joined(room.code), userId).catch(() => 0),
    redis.sismember(keys.admitted(room.code), userId).catch(() => 0),
    redis.hexists(keys.knocks(room.code), userId).catch(() => 0),
    redis.zrank(keys.waitlist(room.code), userId).catch(() => null),
    liveHolds(room),
    occupancyOf(room),
  ]);
  const others = seats.userIds.filter((id) => id !== userId);
  const heldForOthers = [...holds.keys()].filter((id) => id !== userId).length;
  return {
    joinedBefore: joined === 1,
    admitted: admitted === 1,
    knocked: knocked === 1,
    waitlistPosition: position === null || position === undefined ? null : Number(position) + 1,
    holdsSeat: holds.has(userId),
    holdUntil: holds.get(userId) ?? null,
    occupied: seats.occupied,
    occupiedByOthers: others.length,
    heldForOthers,
  };
};

export const decide = async ({ room, userId, tenantId = null, now = Date.now() }) => {
  const relation = await relationFor(room, { userId, tenantId });
  const state = await stateFor(room, userId);
  const decision = Rules.entryDecision({
    room,
    relation,
    now,
    joinedBefore: state.joinedBefore,
    admitted: state.admitted,
    occupiedByOthers: state.occupiedByOthers,
    heldForOthers: state.heldForOthers,
    holdsSeat: state.holdsSeat,
    capacity: capacityOf(room),
  });
  return { relation, state, decision };
};

const markLive = (room) =>
  pool
    .query(
      `UPDATE scheduled_sessions SET status = 'live', room_id = coalesce(room_id, room_code), updated_at = now()
        WHERE id = $1 AND status = 'scheduled'`,
      [room.id],
    )
    .catch((cause) => log.warn({ err: cause, code: room.code }, 'room not marked live'));

// ---------------------------------------------------------------------------
// The socket join (signaling/socketHandlers.js)
// ---------------------------------------------------------------------------

/**
 * null for rooms that are not scheduled — their join is unchanged. Otherwise
 * whether this person may come in now, their role in the room, the seat
 * limit to reserve against and the settings the room starts with.
 */
export const admissionFor = async ({ roomId, userId, tenantId }) => {
  if (!Rules.isRoomCode(roomId)) return null;
  let room;
  try {
    room = await findByCode(roomId);
  } catch (cause) {
    // A database problem must not turn every room into a locked one.
    log.error({ err: cause, roomId }, 'scheduled room lookup failed; joining as an ad-hoc room');
    return null;
  }
  if (!room) return null;

  const { relation, decision } = await decide({ room, userId, tenantId });
  if (!decision.allowed) return { allowed: false, code: decision.code, message: decision.message };

  const moderator = Rules.isModerator(relation);
  await Promise.all([
    redis.sadd(keys.joined(room.code), userId).then(() => expireWithRoom(keys.joined(room.code), room)),
    redis.hdel(keys.holds(room.code), userId),
    redis.zrem(keys.waitlist(room.code), userId),
    redis.hdel(keys.knocks(room.code), userId),
  ]).catch(() => undefined);
  await markLive(room);

  return {
    allowed: true,
    role: relation === 'host' ? 'host' : relation === 'cohost' ? 'cohost' : 'learner',
    hostId: room.hostId,
    // Hosts and co-hosts always get in: 0 is "no limit" for reserveSeat.
    capacity: moderator ? 0 : capacityOf(room),
    code: room.code,
    endsAt: room.endsAt,
    settings: room.settings,
  };
};

/** The room's own starting settings, once, when the live room is created. */
export const applyToRoom = (liveRoom, admission) => {
  if (!liveRoom || !admission || liveRoom.scheduled) return;
  const settings = admission.settings ?? {};
  // The lobby is the waiting room for scheduled rooms (knock and admit), so
  // the classroom's own waiting room stays off.
  liveRoom.settings.waitingRoom = false;
  if (typeof settings.learnersJoinMuted === 'boolean') liveRoom.settings.startMuted = settings.learnersJoinMuted;
  if (typeof settings.reactionsEnabled === 'boolean') liveRoom.settings.reactionsEnabled = settings.reactionsEnabled;
  if (typeof settings.learnersMayShare === 'boolean') liveRoom.settings.learnersMayShare = settings.learnersMayShare;
  liveRoom.hostUserId = admission.hostId;
  liveRoom.scheduled = { code: admission.code, endsAt: admission.endsAt };
};

// ---------------------------------------------------------------------------
// Lobby: knocking, the waiting list
// ---------------------------------------------------------------------------

export const knock = async ({ room, user }) => {
  await redis.hset(
    keys.knocks(room.code),
    user.userId,
    JSON.stringify({ displayName: user.displayName ?? 'Someone', at: new Date().toISOString() }),
  );
  await expireWithRoom(keys.knocks(room.code), room);
  const { pushToUser } = await import('../realtime/userEvents.js');
  for (const id of [room.hostId, ...room.cohostIds]) {
    await pushToUser(id, 'room:knock', { code: room.code, displayName: user.displayName ?? 'Someone' });
  }
};

export const withdrawKnock = (room, userId) => redis.hdel(keys.knocks(room.code), userId);

export const listKnocks = async (room) => {
  const raw = (await redis.hgetall(keys.knocks(room.code))) ?? {};
  return Object.entries(raw)
    .map(([userId, value]) => {
      try {
        return { userId, ...JSON.parse(value) };
      } catch {
        return { userId, displayName: 'Someone', at: null };
      }
    })
    .sort((a, b) => String(a.at).localeCompare(String(b.at)));
};

/** Lets people in. `userIds` empty means everyone who is knocking. */
export const admit = async ({ room, userIds = [] }) => {
  const targets = userIds.length ? userIds : (await listKnocks(room)).map((entry) => entry.userId);
  if (targets.length === 0) return { admitted: 0 };
  await redis.sadd(keys.admitted(room.code), ...targets);
  await expireWithRoom(keys.admitted(room.code), room);
  await redis.hdel(keys.knocks(room.code), ...targets);
  const { pushToUser } = await import('../realtime/userEvents.js');
  for (const id of targets) await pushToUser(id, 'room:admitted', { code: room.code });
  return { admitted: targets.length };
};

export const deny = async ({ room, userId }) => {
  await redis.hdel(keys.knocks(room.code), userId);
  const { pushToUser } = await import('../realtime/userEvents.js');
  await pushToUser(userId, 'room:denied', { code: room.code });
  return { denied: true };
};

export const joinWaitlist = async ({ room, userId }) => {
  await redis.zadd(keys.waitlist(room.code), 'NX', Date.now(), userId);
  await expireWithRoom(keys.waitlist(room.code), room);
  await redis.sadd(keys.withWaitlist(), room.code);
  const rank = await redis.zrank(keys.waitlist(room.code), userId);
  return { position: rank === null ? null : Number(rank) + 1 };
};

export const leaveWaitlist = async ({ room, userId }) => {
  await redis.zrem(keys.waitlist(room.code), userId);
  await redis.hdel(keys.holds(room.code), userId);
  return { position: null };
};

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

const namesOf = async (userIds) => {
  if (userIds.length === 0) return new Map();
  const { rows } = await pool.query(
    `SELECT u.id, u.display_name, p.handle FROM users u LEFT JOIN profiles p ON p.user_id = u.id
      WHERE u.id = ANY($1::uuid[])`,
    [userIds],
  );
  return new Map(rows.map((row) => [row.id, { userId: row.id, displayName: row.display_name, handle: row.handle ?? null }]));
};

const inviteesOf = async (sessionId) => {
  const { rows } = await pool.query(`SELECT user_id FROM session_invitees WHERE session_id = $1`, [sessionId]);
  return rows.map((row) => row.user_id);
};

/**
 * The link to a room's lobby. `base` is the address the asking browser is on
 * (routes pass publicAppUrlFor(req)); without it, the public address of the
 * app (config/publicUrl.js) — never localhost in a Codespace.
 */
export const roomUrl = (code, base = publicAppUrl()) => `${String(base).replace(/\/$/, '')}/rooms/${code}/lobby`;

/** What a person sees of a room: the lobby, the room card, the editor. */
export const detailFor = async ({ room, userId, tenantId = null, now = Date.now(), baseUrl = undefined }) => {
  const { relation, state, decision } = await decide({ room, userId, tenantId, now });
  if (!relation) fail('not_found', 'No such room, or it is not shared with you.');

  const moderator = Rules.isModerator(relation);
  const invitees = moderator ? await inviteesOf(room.id) : [];
  const names = await namesOf([...new Set([room.hostId, ...room.cohostIds, ...invitees])]);
  const time = Rules.windowFor(room);

  return {
    code: room.code,
    sessionId: room.id,
    seriesId: room.seriesId,
    title: room.title,
    description: room.description,
    agenda: room.settings.agenda ?? null,
    startsAt: room.startsAt,
    endsAt: room.endsAt,
    timeZone: room.timeZone,
    doorsOpenAt: new Date(time.doorsOpenAt).toISOString(),
    hostOpensAt: new Date(time.hostOpensAt).toISOString(),
    lateUntil: time.lateUntil ? new Date(time.lateUntil).toISOString() : null,
    earlyEntryMinutes: room.earlyEntryMinutes,
    lateJoinMinutes: room.lateJoinMinutes,
    status: room.status,
    phase: Rules.phaseOf(room, now),
    access: room.access,
    approval: room.approval,
    capacity: room.capacity,
    effectiveCapacity: capacityOf(room),
    occupied: state.occupied,
    settings: {
      learnersJoinMuted: room.settings.learnersJoinMuted ?? null,
      reactionsEnabled: room.settings.reactionsEnabled ?? null,
      learnersMayShare: room.settings.learnersMayShare ?? null,
    },
    host: names.get(room.hostId) ?? { userId: room.hostId, displayName: 'Host' },
    cohosts: room.cohostIds.map((id) => names.get(id) ?? { userId: id, displayName: 'Co-host' }),
    invitees: moderator ? invitees.map((id) => names.get(id) ?? { userId: id, displayName: 'Invitee' }) : undefined,
    url: roomUrl(room.code, baseUrl),
    cancelReason: room.cancelReason,
    viewer: {
      relation,
      moderator,
      canEnter: decision.allowed,
      reason: decision.code,
      message: decision.message,
      opensAt: decision.opensAt ? new Date(decision.opensAt).toISOString() : null,
      knocked: state.knocked,
      admitted: state.admitted,
      waitlistPosition: state.waitlistPosition,
      holdUntil: state.holdUntil ? new Date(state.holdUntil).toISOString() : null,
    },
    serverTime: new Date(now).toISOString(),
  };
};

/** "My rooms": hosted, co-hosted or invited; upcoming (incl. running) or past. */
export const listMine = async ({ userId, when = 'upcoming', limit = 50 }) => {
  const upcoming = when !== 'past';
  const { rows } = await pool.query(
    `SELECT ${COLUMNS},
            (SELECT count(*)::int FROM session_invitees i WHERE i.session_id = s.id) AS invitee_count,
            u.display_name AS host_name
       FROM scheduled_sessions s
       JOIN users u ON u.id = s.host_id
      WHERE s.room_code IS NOT NULL
        AND (s.host_id = $1 OR $1 = ANY(s.cohost_ids)
             OR EXISTS (SELECT 1 FROM session_invitees i WHERE i.session_id = s.id AND i.user_id = $1))
        AND ${upcoming
          ? `s.ends_at >= now() AND s.status IN ('scheduled', 'live')`
          : `(s.ends_at < now() OR s.status IN ('ended', 'cancelled')) AND s.starts_at > now() - interval '90 days'`}
      ORDER BY s.starts_at ${upcoming ? 'ASC' : 'DESC'}
      LIMIT $2`,
    [userId, limit],
  );
  const now = Date.now();
  return {
    items: rows.map((row) => {
      const room = toRoom(row);
      const relation = room.hostId === userId ? 'host' : room.cohostIds.includes(userId) ? 'cohost' : 'invitee';
      return {
        code: room.code,
        sessionId: room.id,
        seriesId: room.seriesId,
        title: room.title,
        startsAt: room.startsAt,
        endsAt: room.endsAt,
        doorsOpenAt: new Date(Rules.windowFor(room).doorsOpenAt).toISOString(),
        timeZone: room.timeZone,
        status: room.status,
        phase: Rules.phaseOf(room, now),
        access: room.access,
        capacity: room.capacity,
        inviteeCount: row.invitee_count,
        hostName: row.host_name,
        relation,
      };
    }),
  };
};

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

const Schedule = () => import('../scheduling/ScheduleService.js');
const Reminders = () => import('../scheduling/ReminderRules.js');

const withTransaction = async (fn) => {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (cause) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw cause;
  } finally {
    client.release();
  }
};

/** Occurrences a create or a reschedule would make, and what they collide with. */
export const preview = async ({ tenantId, hostId, startsAtLocal, durationMinutes, timeZone, recurrence = null, excludeSessionIds = [] }) => {
  const S = await Schedule();
  S.assertTimeZone(timeZone);
  const first = S.parseLocalDateTime(startsAtLocal, timeZone);
  const instants = S.expandRecurrence(first.wall, timeZone, recurrence ?? null);
  const occurrences = instants.map((start) => ({
    startsAt: new Date(start).toISOString(),
    endsAt: new Date(start + durationMinutes * 60_000).toISOString(),
  }));
  const conflicts = [];
  for (const occurrence of occurrences.slice(0, 60)) {
    const found = await S.findHostConflicts({
      tenantId,
      hostId,
      startsAt: new Date(occurrence.startsAt),
      endsAt: new Date(occurrence.endsAt),
      excludeSessionIds,
    });
    for (const conflict of found) {
      conflicts.push({ at: occurrence.startsAt, title: conflict.title, startsAt: iso(conflict.startsAt), endsAt: iso(conflict.endsAt) });
    }
  }
  return {
    occurrences,
    conflicts,
    adjusted: first.adjusted,
    inPast: new Date(occurrences[0].startsAt).getTime() < Date.now() - 60_000,
  };
};

const notifyPeople = async ({ userIds, type, title, body, code, actorId }) => {
  const recipients = [...new Set(userIds)].filter((id) => id && id !== actorId);
  if (recipients.length === 0) return;
  try {
    const { notifyMany } = await import('../community/NotificationService.js');
    await notifyMany({
      userIds: recipients,
      type,
      title,
      body,
      href: `/rooms/${code}/lobby`,
      actorId,
      data: { roomCode: code },
      dedupeKey: `${type}:${code}`,
    });
  } catch (cause) {
    log.warn({ err: cause, type }, 'room notification not queued');
  }
};

const whenText = (room) =>
  new Intl.DateTimeFormat('en-GB', { timeZone: room.timeZone, dateStyle: 'medium', timeStyle: 'short' }).format(
    new Date(room.startsAt),
  );

const cleanPeople = (ids, hostId) => [...new Set(ids)].filter((id) => id && id !== hostId);

/**
 * Creates a room, or one room per date of a series. One transaction: either
 * every date exists or none does.
 */
export const create = async ({ input, tenantId, hostId }) => {
  const S = await Schedule();
  const R = await Reminders();
  S.assertTimeZone(input.timeZone);

  if (input.capacity && input.capacity > Rules.CAPACITY.max) {
    fail('validation_failed', `A room holds at most ${Rules.CAPACITY.max} people.`);
  }
  const first = S.parseLocalDateTime(input.startsAtLocal, input.timeZone);
  if (first.date.getTime() < Date.now() - 60_000) fail('validation_failed', 'That start time is in the past.');

  const recurrence = input.recurrence ?? null;
  const instants = S.expandRecurrence(first.wall, input.timeZone, recurrence);
  const cohostIds = cleanPeople(input.cohostIds ?? [], hostId);
  const inviteeIds = cleanPeople([...(input.inviteeIds ?? [])], hostId).filter((id) => !cohostIds.includes(id));
  const seriesId = recurrence ? (await import('node:crypto')).randomUUID() : null;
  const durationMs = input.durationMinutes * 60_000;

  const created = await withTransaction(async (client) => {
    const rooms = [];
    for (const start of instants) {
      const startsAt = new Date(start);
      const endsAt = new Date(start + durationMs);
      const conflicts = await S.findHostConflicts({ tenantId, hostId, startsAt, endsAt }, client);
      if (conflicts.length > 0) {
        fail('conflict', `You already have “${conflicts[0].title}” at that time.`, {
          at: startsAt.toISOString(),
          conflictWith: conflicts.map((c) => ({ title: c.title, startsAt: iso(c.startsAt) })),
        });
      }

      const { rows } = await client.query(
        `INSERT INTO scheduled_sessions
           (tenant_id, series_id, host_id, title, description, starts_at, ends_at, time_zone,
            status, sequence, waiting_room, recurrence, created_by,
            room_code, early_entry_min, late_join_min, capacity, access, approval, cohost_ids, room_settings)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,'scheduled',0,false,$9,$3,$10,$11,$12,$13,$14,$15,$16,$17)
         RETURNING id`,
        [
          tenantId,
          seriesId,
          hostId,
          input.title,
          input.description ?? null,
          startsAt,
          endsAt,
          input.timeZone,
          recurrence ? JSON.stringify(recurrence) : null,
          Rules.newRoomCode(),
          input.earlyEntryMinutes ?? Rules.EARLY_ENTRY.default,
          input.lateJoinMinutes ?? null,
          input.capacity ?? null,
          input.access ?? 'invited',
          Boolean(input.approval),
          cohostIds,
          JSON.stringify(input.settings ?? {}),
        ],
      );
      const id = rows[0].id;
      if (inviteeIds.length > 0) {
        await client.query(
          `INSERT INTO session_invitees (session_id, user_id) SELECT $1, unnest($2::uuid[]) ON CONFLICT DO NOTHING`,
          [id, inviteeIds],
        );
      }
      const { rows: full } = await client.query(`SELECT ${COLUMNS} FROM scheduled_sessions s WHERE s.id = $1`, [id]);
      const room = toRoom(full[0]);
      await R.syncForSession({ id: room.id, startsAt: room.startsAt, status: room.status, sequence: room.sequence }, client);
      rooms.push(room);
    }
    return rooms;
  });

  const firstRoom = created[0];
  await notifyPeople({
    userIds: [...inviteeIds, ...cohostIds],
    type: 'session.invited',
    title: created.length > 1 ? `Invitation: ${firstRoom.title} (${created.length} dates)` : `Invitation: ${firstRoom.title}`,
    body: `${whenText(firstRoom)} (${firstRoom.timeZone.replace(/_/g, ' ')})`,
    code: firstRoom.code,
    actorId: hostId,
  });
  log.info({ hostId, count: created.length }, 'rooms created');
  return created;
};

/** Changes one date of a room. Moving it bumps SEQUENCE and re-plans the reminders. */
export const update = async ({ room, patch, actorId }) => {
  const S = await Schedule();
  const R = await Reminders();
  if (room.status === 'cancelled' || room.status === 'ended') fail('validation_failed', 'This room is over and cannot be changed.');

  const zone = patch.timeZone ?? room.timeZone;
  const timeChanged = patch.startsAtLocal !== undefined || patch.durationMinutes !== undefined || patch.timeZone !== undefined;
  let startsAt = new Date(room.startsAt);
  let endsAt = new Date(room.endsAt);

  if (timeChanged) {
    S.assertTimeZone(zone);
    const duration = patch.durationMinutes ?? Math.round((endsAt - startsAt) / 60_000);
    if (patch.startsAtLocal !== undefined) startsAt = S.parseLocalDateTime(patch.startsAtLocal, zone).date;
    endsAt = new Date(startsAt.getTime() + duration * 60_000);
    if (room.status === 'scheduled' && startsAt.getTime() < Date.now() - 60_000) {
      fail('validation_failed', 'That start time is in the past.');
    }
    const conflicts = await S.findHostConflicts({
      tenantId: room.tenantId, hostId: room.hostId, startsAt, endsAt, excludeSessionIds: [room.id],
    });
    if (conflicts.length > 0) fail('conflict', `You already have “${conflicts[0].title}” at that time.`);
  }

  const cohostIds = patch.cohostIds ? cleanPeople(patch.cohostIds, room.hostId) : room.cohostIds;
  const settings = patch.settings ? { ...room.settings, ...patch.settings } : room.settings;
  const before = await inviteesOf(room.id);

  const updated = await withTransaction(async (client) => {
    const { rows } = await client.query(
      `UPDATE scheduled_sessions
          SET title = $2, description = $3, starts_at = $4, ends_at = $5, time_zone = $6,
              early_entry_min = $7, late_join_min = $8, capacity = $9, access = $10, approval = $11,
              cohost_ids = $12, room_settings = $13,
              sequence = sequence + CASE WHEN $14 THEN 1 ELSE 0 END, updated_at = now()
        WHERE id = $1
        RETURNING id`,
      [
        room.id,
        patch.title ?? room.title,
        patch.description !== undefined ? patch.description : room.description,
        startsAt,
        endsAt,
        zone,
        patch.earlyEntryMinutes ?? room.earlyEntryMinutes,
        patch.lateJoinMinutes !== undefined ? patch.lateJoinMinutes : room.lateJoinMinutes,
        patch.capacity !== undefined ? patch.capacity : room.capacity,
        patch.access ?? room.access,
        patch.approval ?? room.approval,
        cohostIds,
        JSON.stringify(settings),
        timeChanged,
      ],
    );
    if (!rows[0]) fail('not_found', 'No such room');

    if (patch.inviteeIds) {
      const next = cleanPeople(patch.inviteeIds, room.hostId).filter((id) => !cohostIds.includes(id));
      await client.query(`DELETE FROM session_invitees WHERE session_id = $1 AND NOT (user_id = ANY($2::uuid[]))`, [room.id, next]);
      if (next.length) {
        await client.query(
          `INSERT INTO session_invitees (session_id, user_id) SELECT $1, unnest($2::uuid[]) ON CONFLICT DO NOTHING`,
          [room.id, next],
        );
      }
    }
    const { rows: full } = await client.query(`SELECT ${COLUMNS} FROM scheduled_sessions s WHERE s.id = $1`, [room.id]);
    const next = toRoom(full[0]);
    if (timeChanged) {
      await R.syncForSession({ id: next.id, startsAt: next.startsAt, status: next.status, sequence: next.sequence }, client);
    }
    return next;
  });

  const after = await inviteesOf(room.id);
  const added = [...after.filter((id) => !before.includes(id)), ...cohostIds.filter((id) => !room.cohostIds.includes(id))];
  await notifyPeople({
    userIds: added,
    type: 'session.invited',
    title: `Invitation: ${updated.title}`,
    body: `${whenText(updated)} (${updated.timeZone.replace(/_/g, ' ')})`,
    code: updated.code,
    actorId,
  });
  if (timeChanged) {
    await notifyPeople({
      userIds: [...after, ...cohostIds].filter((id) => !added.includes(id)),
      type: 'session.rescheduled',
      title: `New time: ${updated.title}`,
      body: `${whenText(updated)} (${updated.timeZone.replace(/_/g, ' ')})`,
      code: updated.code,
      actorId,
    });
  }
  return updated;
};

export const cancel = async ({ room, scope = 'this', reason = null, actorId }) => {
  const S = await Schedule();
  const audience = [...(await inviteesOf(room.id)), ...room.cohostIds];
  const cancelled = await S.cancelSession(room.id, { reason, scope }, { userId: actorId });
  await notifyPeople({
    userIds: audience,
    type: 'session.cancelled',
    title: `Cancelled: ${room.title}`,
    body: reason ? `${whenText(room)} — ${reason}` : whenText(room),
    code: room.code,
    actorId,
  });
  return { cancelled: cancelled.length };
};

/** More time for a running room. Refused when it would run into the host's next room. */
export const extend = async ({ room, minutes }) => {
  if (!Rules.EXTEND_MINUTES.includes(minutes)) fail('validation_failed', 'Extend by 5, 10, 15 or 30 minutes.');
  if (Rules.phaseOf(room) === 'ended' || room.status === 'cancelled') fail('validation_failed', 'This room has ended.');
  const S = await Schedule();
  const endsAt = new Date(new Date(room.endsAt).getTime() + minutes * 60_000);
  const conflicts = await S.findHostConflicts({
    tenantId: room.tenantId, hostId: room.hostId, startsAt: new Date(room.endsAt), endsAt, excludeSessionIds: [room.id],
  });
  if (conflicts.length > 0) fail('conflict', `That would run into “${conflicts[0].title}”.`);
  await pool.query(
    `UPDATE scheduled_sessions SET ends_at = $2, sequence = sequence + 1, updated_at = now() WHERE id = $1`,
    [room.id, endsAt],
  );
  return { endsAt: endsAt.toISOString() };
};

/** Ends the room for everyone now. The enforcer closes it on the media node within seconds. */
export const end = async ({ room }) => {
  await pool.query(
    `UPDATE scheduled_sessions SET ends_at = least(ends_at, now()), status = 'ended', updated_at = now()
      WHERE id = $1 AND status IN ('scheduled', 'live')`,
    [room.id],
  );
  try {
    const RoomManager = await import('../classroom/RoomManager.js');
    if (RoomManager.getRoom(room.code)) await RoomManager.closeRoom(room.code, 'ended-by-host');
  } catch {
    // Not the media process: the enforcer there closes it.
  }
  return { ended: true };
};

// ---------------------------------------------------------------------------
// Enforcer (runs where the rooms live: next to the socket handlers)
// ---------------------------------------------------------------------------

let enforcer = null;
let ticks = 0;

const closeEndedRooms = async ({ listRoomIds, closeRoom }) => {
  const codes = listRoomIds().filter(Rules.isRoomCode);
  if (codes.length === 0) return;
  const { rows } = await pool.query(
    `SELECT room_code, ends_at, status FROM scheduled_sessions WHERE room_code = ANY($1::text[])`,
    [codes],
  );
  const now = Date.now();
  for (const row of rows) {
    if (row.status === 'cancelled' || row.status === 'ended' || new Date(row.ends_at).getTime() <= now) {
      log.info({ code: row.room_code }, 'room reached its end time; closing');
      await closeRoom(row.room_code, 'ended-by-host').catch(() => undefined);
    }
  }
};

const promoteWaitlists = async () => {
  const codes = await redis.smembers(keys.withWaitlist());
  for (const code of codes) {
    const room = await findByCode(code);
    const waiting = room ? await redis.zcard(keys.waitlist(code)) : 0;
    if (!room || waiting === 0 || Rules.phaseOf(room) === 'ended' || room.status === 'cancelled') {
      await redis.srem(keys.withWaitlist(), code);
      continue;
    }
    const [holds, seats] = await Promise.all([liveHolds(room), occupancyOf(room)]);
    const free = Rules.freeSeats({ capacity: capacityOf(room), occupied: seats.occupied, held: holds.size });
    if (free === 0) continue;

    const next = await redis.zrange(keys.waitlist(code), 0, free - 1);
    const { pushToUser } = await import('../realtime/userEvents.js');
    for (const userId of next) {
      const until = Date.now() + Rules.HOLD_MS;
      await redis.hset(keys.holds(code), userId, String(until));
      await expireWithRoom(keys.holds(code), room);
      await redis.zrem(keys.waitlist(code), userId);
      await pushToUser(userId, 'room:seat-available', { code, holdUntil: new Date(until).toISOString() });
      await notifyPeople({
        userIds: [userId],
        type: 'session.seat_available',
        title: `A seat is free: ${room.title}`,
        body: 'It is held for you for 2 minutes.',
        code,
        actorId: null,
      });
    }
  }
};

const markEnded = () =>
  pool.query(
    `UPDATE scheduled_sessions SET status = 'ended', updated_at = now()
      WHERE room_code IS NOT NULL AND status IN ('scheduled', 'live') AND ends_at < now()`,
  );

/**
 * Every 15 seconds. Closing rooms runs on every task (rooms are local to a
 * node); the rest runs once cluster-wide behind a short Redis lock. In
 * development it also hands due lesson reminders to the queue, which in
 * production is the maintenance sweep's job.
 */
export const startEnforcer = ({ listRoomIds, closeRoom, intervalMs = 15_000 }) => {
  if (enforcer) return enforcer;
  const tick = async () => {
    ticks += 1;
    try {
      await closeEndedRooms({ listRoomIds, closeRoom });
    } catch (cause) {
      log.warn({ err: cause }, 'room end check failed');
    }
    try {
      const lock = await redis.set(keys.enforcerLock(), String(process.pid), 'PX', intervalMs - 1_000, 'NX');
      if (lock !== 'OK') return;
      await markEnded();
      await promoteWaitlists();
      if (!isProduction && ticks % 4 === 0 && process.env.REMINDER_SWEEP !== 'off') {
        const { enqueueDue } = await import('../scheduling/ReminderRules.js');
        await enqueueDue().catch((cause) => log.debug({ err: cause }, 'reminder sweep skipped'));
      }
    } catch (cause) {
      log.warn({ err: cause }, 'room sweep failed');
    }
  };
  enforcer = setInterval(() => void tick(), intervalMs);
  enforcer.unref?.();
  log.info('scheduled room enforcer started');
  return enforcer;
};

export default {
  findByCode, relationFor, decide, admissionFor, applyToRoom, detailFor, listMine, preview,
  create, update, cancel, extend, end, knock, withdrawKnock, listKnocks, admit, deny,
  joinWaitlist, leaveWaitlist, startEnforcer, capacityOf, roomUrl,
};
__RL_EOF__
echo "wrote server/src/rooms/ScheduledRooms.js"

mkdir -p server/src/routes
cat > server/src/routes/scheduledRooms.routes.js <<'__RL_EOF__'
/**
 * scheduledRooms.routes — create, plan and enter your own rooms  (Rooms)
 *
 * Links (lobby URL, QR code, calendar file) use the address the browser is
 * on (config/publicUrl.js), so they work for others, also in a Codespace.
 *
 * Mounted under /scheduled-rooms (app.js). The room itself is still joined
 * through the classroom socket at /rooms/<code>; this is everything around
 * it. Rules: rooms/roomRules.js; storage and state: rooms/ScheduledRooms.js.
 *
 *   GET    /config                     limits and defaults for the form
 *   POST   /preview                    dates a form would create, and clashes
 *   POST   /                           create (one room, or one per date of a series)
 *   GET    /mine?when=upcoming|past    rooms I host, co-host or am invited to
 *   GET    /:code                      the room as I may see it, with my entry state
 *   GET    /:code/gate                 may I enter now? (the classroom page asks first)
 *   PATCH  /:code                      edit this date            host
 *   POST   /:code/cancel               { scope, reason }         host
 *   POST   /:code/extend               { minutes }               host, co-host
 *   POST   /:code/end                  end now for everyone      host, co-host
 *   POST   /:code/knock                ask to be let in
 *   DELETE /:code/knock
 *   GET    /:code/knocks               who is asking             host, co-host
 *   POST   /:code/admit                { userIds? } empty = all  host, co-host
 *   POST   /:code/deny                 { userId }                host, co-host
 *   POST   /:code/waitlist             wait for the next free seat
 *   DELETE /:code/waitlist
 *   GET    /:code/qr                   the link as a QR code
 *   GET    /:code/calendar.ics         the room for any calendar
 */

import { Router } from 'express';
import { z } from 'zod';

import * as Rooms from '../rooms/ScheduledRooms.js';
import * as Rules from '../rooms/roomRules.js';
import { rateLimit } from '../middleware/rateLimit.js';
import { publicAppUrlFor } from '../config/publicUrl.js';
import { route, validate, requireAuth, tenantOf, notFound, badRequest, forbidden, conflict } from './_helpers.js';

const router = Router();
router.use(requireAuth);

/** Errors the services raise with a code, as the HTTP answers clients understand. */
const asHttp = (fn) => async (req, res) => {
  try {
    return await fn(req, res);
  } catch (error) {
    if (error?.name === 'ScheduleError') {
      if (error.code === 'HOST_CONFLICT') throw conflict(error.message, error.details);
      throw badRequest(error.message);
    }
    switch (error?.code) {
      case 'validation_failed':
        throw badRequest(error.message);
      case 'forbidden':
        throw forbidden(error.message);
      case 'not_found':
        throw notFound(error.message);
      case 'conflict':
        throw conflict(error.message, error.details);
      default:
        throw error;
    }
  }
};

const handle = (fn) => route(asHttp(fn));

/** zod issues as one readable sentence. */
const parse = (schema, body) => {
  const parsed = schema.safeParse(body ?? {});
  if (!parsed.success) {
    const issue = parsed.error.issues[0];
    const where = issue?.path?.length ? `${issue.path.join('.')}: ` : '';
    throw badRequest(`${where}${issue?.message ?? 'invalid input'}`);
  }
  return parsed.data;
};

const codeParam = z.object({ code: z.string().regex(Rules.ROOM_CODE, 'not a room code') });

/** The room, or 404 — also when it exists but is not shared with this person. */
const loadRoom = async (req) => {
  const room = await Rooms.findByCode(req.params.code);
  if (!room) throw notFound('No such room');
  const relation = await Rooms.relationFor(room, { userId: req.user.id, tenantId: tenantOf(req) });
  if (!relation) throw notFound('No such room, or it is not shared with you.');
  return { room, relation };
};

const requireModerator = async (req) => {
  const loaded = await loadRoom(req);
  if (!Rules.isModerator(loaded.relation)) throw forbidden('Only the host and co-hosts can do that.');
  return loaded;
};

const requireHost = async (req) => {
  const loaded = await loadRoom(req);
  if (loaded.relation !== 'host') throw forbidden('Only the host can change this room.');
  return loaded;
};

/** Links in the answer use the address this browser is on, never localhost for a shared link. */
const detail = (req, room) =>
  Rooms.detailFor({ room, userId: req.user.id, tenantId: tenantOf(req), baseUrl: publicAppUrlFor(req) });

/* ------------------------------------------------------------------ *
 * Planning
 * ------------------------------------------------------------------ */

router.get(
  '/config',
  route(async () => ({
    earlyEntry: Rules.EARLY_ENTRY,
    duration: Rules.DURATION,
    capacity: Rules.CAPACITY,
    lateJoinOptions: Rules.LATE_JOIN_OPTIONS,
    extendOptions: Rules.EXTEND_MINUTES,
    hostEarlyMinutes: Rules.HOST_EARLY_MIN,
    limits: { invitees: Rules.MAX_INVITEES, cohosts: Rules.MAX_COHOSTS },
  })),
);

const previewBody = z
  .object({
    startsAtLocal: Rules.CreateRoomSchema.shape.startsAtLocal,
    durationMinutes: Rules.CreateRoomSchema.shape.durationMinutes,
    timeZone: z.string().min(1).max(64),
    recurrence: Rules.CreateRoomSchema.shape.recurrence,
    excludeCode: z.string().regex(Rules.ROOM_CODE).optional(),
  })
  .strict();

router.post(
  '/preview',
  rateLimit({ key: 'rooms:preview', points: 120, durationSec: 60, by: ['user'] }),
  handle(async (req) => {
    const input = parse(previewBody, req.body);
    const exclude = input.excludeCode ? await Rooms.findByCode(input.excludeCode) : null;
    return Rooms.preview({
      tenantId: tenantOf(req),
      hostId: req.user.id,
      startsAtLocal: input.startsAtLocal,
      durationMinutes: input.durationMinutes,
      timeZone: input.timeZone,
      recurrence: input.recurrence ?? null,
      excludeSessionIds: exclude && exclude.hostId === req.user.id ? [exclude.id] : [],
    });
  }),
);

router.post(
  '/',
  rateLimit({ key: 'rooms:create', points: 30, durationSec: 3600, by: ['user'] }),
  handle(async (req, res) => {
    const input = parse(Rules.CreateRoomSchema, req.body);
    const created = await Rooms.create({ input, tenantId: tenantOf(req), hostId: req.user.id });
    res.status(201).set('Location', `/scheduled-rooms/${created[0].code}`);
    return {
      room: await detail(req, created[0]),
      occurrences: created.map((room) => ({ code: room.code, startsAt: room.startsAt, endsAt: room.endsAt })),
    };
  }),
);

router.get(
  '/mine',
  validate({ query: z.object({ when: z.enum(['upcoming', 'past']).optional() }).passthrough() }),
  route(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    return Rooms.listMine({ userId: req.user.id, when: req.query.when ?? 'upcoming' });
  }),
);

/* ------------------------------------------------------------------ *
 * One room
 * ------------------------------------------------------------------ */

router.get(
  '/:code',
  validate({ params: codeParam }),
  handle(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    const { room } = await loadRoom(req);
    return detail(req, room);
  }),
);

/** Asked by the classroom page before it opens a socket. Not scheduled: enter as before. */
router.get(
  '/:code/gate',
  handle(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    if (!Rules.isRoomCode(req.params.code)) return { scheduled: false, canEnter: true };
    const room = await Rooms.findByCode(req.params.code);
    if (!room) return { scheduled: false, canEnter: true };
    const { decision } = await Rooms.decide({ room, userId: req.user.id, tenantId: tenantOf(req) });
    return { scheduled: true, canEnter: decision.allowed, reason: decision.code, message: decision.message };
  }),
);

router.patch(
  '/:code',
  validate({ params: codeParam }),
  handle(async (req) => {
    const { room } = await requireHost(req);
    const patch = parse(Rules.UpdateRoomSchema, req.body);
    const updated = await Rooms.update({ room, patch, actorId: req.user.id });
    return detail(req, updated);
  }),
);

router.post(
  '/:code/cancel',
  validate({
    params: codeParam,
    body: z.object({ scope: z.enum(['this', 'following']).default('this'), reason: z.string().trim().max(300).nullish() }).default({}),
  }),
  handle(async (req) => {
    const { room } = await requireHost(req);
    return Rooms.cancel({ room, scope: req.body.scope, reason: req.body.reason ?? null, actorId: req.user.id });
  }),
);

router.post(
  '/:code/extend',
  validate({ params: codeParam, body: z.object({ minutes: z.number().int() }) }),
  handle(async (req) => {
    const { room } = await requireModerator(req);
    return Rooms.extend({ room, minutes: req.body.minutes });
  }),
);

router.post(
  '/:code/end',
  validate({ params: codeParam }),
  handle(async (req) => {
    const { room } = await requireModerator(req);
    return Rooms.end({ room });
  }),
);

/* ------------------------------------------------------------------ *
 * Lobby
 * ------------------------------------------------------------------ */

router.post(
  '/:code/knock',
  rateLimit({ key: 'rooms:knock', points: 20, durationSec: 300, by: ['user'] }),
  validate({ params: codeParam }),
  handle(async (req) => {
    const { room, relation } = await loadRoom(req);
    if (!room.approval || Rules.isModerator(relation)) return detail(req, room);
    const phase = Rules.phaseOf(room);
    if (phase !== 'doors-open' && phase !== 'live') throw badRequest('The doors are not open yet.');
    await Rooms.knock({ room, user: { userId: req.user.id, displayName: req.user.displayName } });
    return detail(req, room);
  }),
);

router.delete(
  '/:code/knock',
  validate({ params: codeParam }),
  handle(async (req) => {
    const { room } = await loadRoom(req);
    await Rooms.withdrawKnock(room, req.user.id);
    return detail(req, room);
  }),
);

router.get(
  '/:code/knocks',
  validate({ params: codeParam }),
  handle(async (req, res) => {
    res.set('Cache-Control', 'no-store');
    const { room } = await requireModerator(req);
    return { items: await Rooms.listKnocks(room) };
  }),
);

router.post(
  '/:code/admit',
  validate({ params: codeParam, body: z.object({ userIds: z.array(z.string().uuid()).max(300).default([]) }).default({}) }),
  handle(async (req) => {
    const { room } = await requireModerator(req);
    return Rooms.admit({ room, userIds: req.body.userIds });
  }),
);

router.post(
  '/:code/deny',
  validate({ params: codeParam, body: z.object({ userId: z.string().uuid() }) }),
  handle(async (req) => {
    const { room } = await requireModerator(req);
    return Rooms.deny({ room, userId: req.body.userId });
  }),
);

router.post(
  '/:code/waitlist',
  validate({ params: codeParam }),
  handle(async (req) => {
    const { room } = await loadRoom(req);
    await Rooms.joinWaitlist({ room, userId: req.user.id });
    return detail(req, room);
  }),
);

router.delete(
  '/:code/waitlist',
  validate({ params: codeParam }),
  handle(async (req) => {
    const { room } = await loadRoom(req);
    await Rooms.leaveWaitlist({ room, userId: req.user.id });
    return detail(req, room);
  }),
);

/* ------------------------------------------------------------------ *
 * Sharing
 * ------------------------------------------------------------------ */

/** The link as a QR code. Uses qrcode (installed with Settings Phase C); 404 without it. */
router.get(
  '/:code/qr',
  validate({ params: codeParam }),
  handle(async (req, res) => {
    const { room } = await loadRoom(req);
    let QRCode;
    try {
      const imported = await import('qrcode');
      QRCode = imported.default ?? imported;
    } catch {
      throw notFound('QR codes are not available on this server.');
    }
    res.set('Cache-Control', 'private, max-age=3600');
    return { dataUrl: await QRCode.toDataURL(Rooms.roomUrl(room.code, publicAppUrlFor(req)), { margin: 1, width: 264, errorCorrectionLevel: 'M' }) };
  }),
);

/* ------------------------------------------------------------------ *
 * Calendar
 * ------------------------------------------------------------------ */

router.get(
  '/:code/calendar.ics',
  validate({ params: codeParam }),
  // Not route(): the answer is a file, not JSON. Errors still go to the error handler.
  (req, res, next) =>
    asHttp(async () => {
      const { room } = await loadRoom(req);
      res.set('Content-Type', 'text/calendar; charset=utf-8');
      res.set('Content-Disposition', `attachment; filename="${room.code}.ics"`);
      res.set('Cache-Control', 'no-store');
      res.send(Rules.icsFor({ room, url: Rooms.roomUrl(room.code, publicAppUrlFor(req)) }));
    })(req, res).catch(next),
);

export default router;
__RL_EOF__
echo "wrote server/src/routes/scheduledRooms.routes.js"

mkdir -p server/test/rooms
cat > server/test/rooms/publicUrl.check.mjs <<'__RL_EOF__'
// Rooms · links — links that open for whoever receives them.
// Run: node --test server/test/rooms/*.check.mjs
// Uses the pure rules only (config/publicUrlRules.js): no environment needed.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  chooseLinkOrigin,
  hostedWorkspaceUrl,
  isLocalOrigin,
  originOf,
  resolvePublicAppUrl,
} from '../../src/config/publicUrlRules.js';

const CS = 'crispy-umbrella-6v97r5rw7pvph5pp5';
const CS_URL = `https://${CS}-5173.app.github.dev`;

test('plain local development keeps APP_URL', () => {
  assert.equal(resolvePublicAppUrl({ environment: {}, appUrl: 'http://localhost:5173' }), 'http://localhost:5173');
  assert.equal(resolvePublicAppUrl({ environment: {}, appUrl: null }), 'http://localhost:5173');
});

test('any Codespace: the forwarded address of APP_URL’s port, with no configuration', () => {
  const environment = { CODESPACE_NAME: CS, GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN: 'app.github.dev' };
  assert.equal(resolvePublicAppUrl({ environment, appUrl: 'http://localhost:5173/' }), CS_URL);
  // A fresh clone lands in a codespace with another name: the link follows.
  assert.equal(
    resolvePublicAppUrl({ environment: { CODESPACE_NAME: 'fuzzy-train-123' }, appUrl: 'http://localhost:3000' }),
    'https://fuzzy-train-123-3000.app.github.dev',
  );
});

test('Gitpod works the same way', () => {
  assert.equal(
    hostedWorkspaceUrl({ environment: { GITPOD_WORKSPACE_URL: 'https://user-repo-abc.ws-eu.gitpod.io' }, port: '5173' }),
    'https://5173-user-repo-abc.ws-eu.gitpod.io',
  );
  assert.equal(hostedWorkspaceUrl({ environment: {}, port: '5173' }), null);
});

test('a real APP_URL is kept, PUBLIC_APP_URL pins everything', () => {
  assert.equal(
    resolvePublicAppUrl({ environment: { CODESPACE_NAME: CS }, appUrl: 'https://classroom.example' }),
    'https://classroom.example',
  );
  assert.equal(
    resolvePublicAppUrl({ environment: { CODESPACE_NAME: CS, PUBLIC_APP_URL: 'https://tunnel.example/' }, appUrl: 'http://localhost:5173' }),
    'https://tunnel.example',
  );
  assert.equal(
    resolvePublicAppUrl({ environment: { PUBLIC_APP_URL: 'not a url' }, appUrl: 'http://localhost:5173' }),
    'http://localhost:5173',
  );
});

test('links for a request: the browser’s own address when trusted, never localhost for others', () => {
  const trusted = (origin) => origin === CS_URL || isLocalOrigin(origin);
  assert.equal(chooseLinkOrigin({ candidates: [CS_URL], fallback: CS_URL, trusted }), CS_URL);
  // Someone on localhost (VS Code on the desktop) still shares the public address.
  assert.equal(chooseLinkOrigin({ candidates: ['http://localhost:5173'], fallback: CS_URL, trusted }), CS_URL);
  // Untrusted origins are never echoed into a link.
  assert.equal(chooseLinkOrigin({ candidates: ['https://evil.example'], fallback: CS_URL, trusted }), CS_URL);
  // Referer with a path: only its origin counts.
  assert.equal(chooseLinkOrigin({ candidates: [`${CS_URL}/rooms/x/lobby`], fallback: 'http://localhost:5173', trusted }), CS_URL);
  // Plain local development: localhost is the right answer.
  assert.equal(
    chooseLinkOrigin({ candidates: ['http://localhost:5173'], fallback: 'http://localhost:5173', trusted }),
    'http://localhost:5173',
  );
});

test('origins', () => {
  assert.equal(originOf('https://a.example/path?q=1'), 'https://a.example');
  assert.equal(originOf('javascript:alert(1)'), null);
  assert.equal(originOf(''), null);
  assert.ok(isLocalOrigin('http://localhost:5173'));
  assert.ok(isLocalOrigin('http://127.0.0.1:4000'));
  assert.ok(!isLocalOrigin(CS_URL));
});
__RL_EOF__
echo "wrote server/test/rooms/publicUrl.check.mjs"

mkdir -p packages/core-client/src/api
cat > packages/core-client/src/api/roomsApi.ts <<'__RL_EOF__'
/**
 * Rooms API  (Rooms: create your own room)
 *
 * Planning, the lobby and the host's controls for rooms people create
 * themselves. Paths are the server's (server/src/routes/scheduledRooms.routes.js,
 * mounted under /scheduled-rooms). The room is still joined through the
 * classroom socket at /rooms/<code>.
 *
 * Links in answers (lobby URL, QR code, calendar file) are built by the
 * server for the address this page is on: the page's origin travels along
 * as ?origin=, and the server only uses it when it trusts it.
 */

import { z } from 'zod';
import type { HttpClient } from '../http/httpClient.js';

const Person = z
  .object({ userId: z.string(), displayName: z.string(), handle: z.string().nullable().default(null) })
  .passthrough();
export type RoomPerson = z.infer<typeof Person>;

export const RoomPhaseSchema = z.enum(['scheduled', 'doors-open', 'live', 'ended', 'cancelled']);
export type RoomPhase = z.infer<typeof RoomPhaseSchema>;

export const RoomDetailSchema = z
  .object({
    code: z.string(),
    sessionId: z.string(),
    seriesId: z.string().nullable().default(null),
    title: z.string(),
    description: z.string().nullable().default(null),
    agenda: z.string().nullable().default(null),
    startsAt: z.string(),
    endsAt: z.string(),
    timeZone: z.string(),
    doorsOpenAt: z.string(),
    hostOpensAt: z.string(),
    lateUntil: z.string().nullable().default(null),
    earlyEntryMinutes: z.number(),
    lateJoinMinutes: z.number().nullable().default(null),
    status: z.string(),
    phase: RoomPhaseSchema,
    access: z.enum(['invited', 'link']),
    approval: z.boolean(),
    capacity: z.number().nullable().default(null),
    effectiveCapacity: z.number(),
    occupied: z.number().default(0),
    settings: z
      .object({
        learnersJoinMuted: z.boolean().nullable().default(null),
        reactionsEnabled: z.boolean().nullable().default(null),
        learnersMayShare: z.boolean().nullable().default(null),
      })
      .passthrough(),
    host: Person,
    cohosts: z.array(Person).default([]),
    invitees: z.array(Person).optional(),
    url: z.string(),
    cancelReason: z.string().nullable().default(null),
    viewer: z
      .object({
        relation: z.enum(['host', 'cohost', 'invitee', 'guest']),
        moderator: z.boolean(),
        canEnter: z.boolean(),
        reason: z.string().nullable().default(null),
        message: z.string().nullable().default(null),
        opensAt: z.string().nullable().default(null),
        knocked: z.boolean().default(false),
        admitted: z.boolean().default(false),
        waitlistPosition: z.number().nullable().default(null),
        holdUntil: z.string().nullable().default(null),
      })
      .passthrough(),
    serverTime: z.string(),
  })
  .passthrough();
export type RoomDetail = z.infer<typeof RoomDetailSchema>;

export const RoomListItemSchema = z
  .object({
    code: z.string(),
    sessionId: z.string(),
    seriesId: z.string().nullable().default(null),
    title: z.string(),
    startsAt: z.string(),
    endsAt: z.string(),
    doorsOpenAt: z.string(),
    timeZone: z.string(),
    status: z.string(),
    phase: RoomPhaseSchema,
    access: z.string(),
    capacity: z.number().nullable().default(null),
    inviteeCount: z.number().default(0),
    hostName: z.string().nullable().default(null),
    relation: z.enum(['host', 'cohost', 'invitee']),
  })
  .passthrough();
export type RoomListItem = z.infer<typeof RoomListItemSchema>;

const ConfigSchema = z
  .object({
    earlyEntry: z.object({ min: z.number(), max: z.number(), default: z.number() }),
    duration: z.object({ min: z.number(), max: z.number(), presets: z.array(z.number()) }),
    capacity: z.object({ min: z.number(), max: z.number(), default: z.number() }),
    lateJoinOptions: z.array(z.number().nullable()),
    extendOptions: z.array(z.number()),
    hostEarlyMinutes: z.number(),
    limits: z.object({ invitees: z.number(), cohosts: z.number() }),
  })
  .passthrough();
export type RoomsConfig = z.infer<typeof ConfigSchema>;

const PreviewSchema = z
  .object({
    occurrences: z.array(z.object({ startsAt: z.string(), endsAt: z.string() })),
    conflicts: z.array(
      z.object({ at: z.string(), title: z.string(), startsAt: z.string().nullable(), endsAt: z.string().nullable() }).passthrough(),
    ),
    adjusted: z.string().nullable().default(null),
    inPast: z.boolean().default(false),
  })
  .passthrough();
export type RoomPreview = z.infer<typeof PreviewSchema>;

const GateSchema = z
  .object({
    scheduled: z.boolean(),
    canEnter: z.boolean(),
    reason: z.string().nullable().optional(),
    message: z.string().nullable().optional(),
  })
  .passthrough();
export type RoomGate = z.infer<typeof GateSchema>;

const KnocksSchema = z.object({
  items: z.array(z.object({ userId: z.string(), displayName: z.string(), at: z.string().nullable() }).passthrough()),
});

export interface RoomRecurrence {
  freq: 'DAILY' | 'WEEKLY';
  interval?: number;
  byDay?: Array<'MO' | 'TU' | 'WE' | 'TH' | 'FR' | 'SA' | 'SU'>;
  count?: number;
  until?: string;
}

export interface RoomInput {
  title: string;
  description?: string | null;
  startsAtLocal: string;
  durationMinutes: number;
  timeZone: string;
  earlyEntryMinutes?: number;
  lateJoinMinutes?: number | null;
  capacity?: number | null;
  access?: 'invited' | 'link';
  approval?: boolean;
  inviteeIds?: string[];
  cohostIds?: string[];
  settings?: {
    learnersJoinMuted?: boolean;
    reactionsEnabled?: boolean;
    learnersMayShare?: boolean;
    agenda?: string | null;
  };
  recurrence?: RoomRecurrence | null;
}

export interface RoomsApi {
  config(signal?: AbortSignal): Promise<RoomsConfig>;
  preview(
    input: Pick<RoomInput, 'startsAtLocal' | 'durationMinutes' | 'timeZone' | 'recurrence'> & { excludeCode?: string },
    signal?: AbortSignal,
  ): Promise<RoomPreview>;
  create(input: RoomInput): Promise<{ room: RoomDetail; occurrences: Array<{ code: string; startsAt: string; endsAt: string }> }>;
  mine(when?: 'upcoming' | 'past', signal?: AbortSignal): Promise<{ items: RoomListItem[] }>;
  get(code: string, signal?: AbortSignal): Promise<RoomDetail>;
  gate(code: string, signal?: AbortSignal): Promise<RoomGate>;
  update(code: string, patch: Partial<Omit<RoomInput, 'recurrence'>>): Promise<RoomDetail>;
  cancel(code: string, input?: { scope?: 'this' | 'following'; reason?: string | null }): Promise<{ cancelled: number }>;
  extend(code: string, minutes: number): Promise<{ endsAt: string }>;
  end(code: string): Promise<{ ended: boolean }>;
  knock(code: string): Promise<RoomDetail>;
  withdrawKnock(code: string): Promise<RoomDetail>;
  knocks(code: string, signal?: AbortSignal): Promise<z.infer<typeof KnocksSchema>>;
  admit(code: string, userIds?: string[]): Promise<{ admitted: number }>;
  deny(code: string, userId: string): Promise<{ denied: boolean }>;
  joinWaitlist(code: string): Promise<RoomDetail>;
  leaveWaitlist(code: string): Promise<RoomDetail>;
  /** The .ics file, for a download link. */
  calendarFile(code: string): Promise<Blob>;
  /** The link as a QR code (a data: URL), for a slide or a printed sheet. */
  qr(code: string): Promise<{ dataUrl: string }>;
}

const BASE = '/scheduled-rooms';
const path = (code: string, rest = '') => `${BASE}/${encodeURIComponent(code)}${rest}`;
const once = { retry: { attempts: 1 } };

/** This page's address, for links the server builds (browsers only). */
const pageOrigin = (): string | undefined => {
  const location = (globalThis as { location?: { origin?: string } }).location;
  return location?.origin && location.origin !== 'null' ? location.origin : undefined;
};

export const createRoomsApi = (http: HttpClient): RoomsApi => ({
  config: (signal) => http.get(`${BASE}/config`, { schema: ConfigSchema, signal }),

  preview: (input, signal) => http.post(`${BASE}/preview`, input, { schema: PreviewSchema, signal, ...once }),

  create: (input) =>
    http.post(BASE, input, {
      schema: z
        .object({
          room: RoomDetailSchema,
          occurrences: z.array(z.object({ code: z.string(), startsAt: z.string(), endsAt: z.string() })),
        })
        .passthrough(),
      ...once,
    }),

  mine: (when = 'upcoming', signal) =>
    http.get(`${BASE}/mine`, { schema: z.object({ items: z.array(RoomListItemSchema) }), query: { when }, signal }),

  get: (code, signal) => http.get(path(code), { schema: RoomDetailSchema, query: { origin: pageOrigin() }, signal }),

  gate: (code, signal) => http.get(path(code, '/gate'), { schema: GateSchema, signal, retry: { attempts: 2 } }),

  update: (code, patch) => http.patch(path(code), patch, { schema: RoomDetailSchema }),

  cancel: (code, input = {}) =>
    http.post(path(code, '/cancel'), input, { schema: z.object({ cancelled: z.number() }).passthrough(), ...once }),

  extend: (code, minutes) =>
    http.post(path(code, '/extend'), { minutes }, { schema: z.object({ endsAt: z.string() }).passthrough(), ...once }),

  end: (code) => http.post(path(code, '/end'), {}, { schema: z.object({ ended: z.boolean() }).passthrough(), ...once }),

  knock: (code) => http.post(path(code, '/knock'), {}, { schema: RoomDetailSchema, ...once }),

  withdrawKnock: (code) => http.delete(path(code, '/knock'), { schema: RoomDetailSchema }),

  knocks: (code, signal) => http.get(path(code, '/knocks'), { schema: KnocksSchema, signal }),

  admit: (code, userIds = []) =>
    http.post(path(code, '/admit'), { userIds }, { schema: z.object({ admitted: z.number() }).passthrough() }),

  deny: (code, userId) =>
    http.post(path(code, '/deny'), { userId }, { schema: z.object({ denied: z.boolean() }).passthrough() }),

  joinWaitlist: (code) => http.post(path(code, '/waitlist'), {}, { schema: RoomDetailSchema, ...once }),

  leaveWaitlist: (code) => http.delete(path(code, '/waitlist'), { schema: RoomDetailSchema }),

  qr: (code) =>
    http.get(path(code, '/qr'), {
      schema: z.object({ dataUrl: z.string() }).passthrough(),
      query: { origin: pageOrigin() },
      retry: { attempts: 1 },
    }),

  calendarFile: async (code) => {
    const origin = pageOrigin();
    const query = origin ? `?origin=${encodeURIComponent(origin)}` : '';
    const response = await http.raw('GET', `${path(code, '/calendar.ics')}${query}`);
    if (!response.ok) throw new Error('The calendar file could not be downloaded.');
    return response.blob();
  },
});
__RL_EOF__
echo "wrote packages/core-client/src/api/roomsApi.ts"

mkdir -p apps/web/src/components/Rooms
cat > apps/web/src/components/Rooms/roomModel.js <<'__RL_EOF__'
/**
 * Pure helpers for creating, showing and entering rooms  (Rooms)
 *
 * No React, no network: tested in __checks__/roomModel.check.mjs. The server
 * decides who may enter (server/src/rooms/roomRules.js); these only shape the
 * form and the words on screen.
 */

export const WEEKDAYS = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'];
export const WORKDAYS = ['MO', 'TU', 'WE', 'TH', 'FR'];

const pad = (n) => String(n).padStart(2, '0');

/** "2026-10-01T18:00" for a moment, as the wall clock shows it in a time zone. */
export const localInputValue = (value, timeZone) => {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(new Date(value));
  const get = (type) => parts.find((part) => part.type === type)?.value ?? '00';
  return `${get('year')}-${get('month')}-${get('day')}T${get('hour') === '24' ? '00' : get('hour')}:${get('minute')}`;
};

/** The next full quarter hour at least 15 minutes away — a sensible default start. */
export const nextSlot = (now = new Date()) => {
  const next = new Date(now.getTime() + 15 * 60_000);
  next.setSeconds(0, 0);
  next.setMinutes(Math.ceil(next.getMinutes() / 15) * 15);
  return next;
};

/** Weekday code of a local date-time string, e.g. 'TU'. */
export const weekdayOf = (localIso) => {
  const [date] = String(localIso).split('T');
  const [y, m, d] = date.split('-').map(Number);
  return WEEKDAYS[new Date(Date.UTC(y, m - 1, d)).getUTCDay()];
};

export const defaultForm = ({ timeZone, roomDefaults = {}, now = new Date() } = {}) => ({
  title: '',
  description: '',
  agenda: '',
  startsAtLocal: localInputValue(nextSlot(now), timeZone),
  durationMinutes: 60,
  timeZone,
  earlyEntryMinutes: 5,
  lateJoinMinutes: null,
  capacityMode: 'limit',
  capacity: 25,
  access: 'invited',
  approval: false,
  invitees: [],
  cohosts: [],
  learnersJoinMuted: roomDefaults.learnersJoinMuted ?? false,
  reactionsEnabled: roomDefaults.reactionsEnabled ?? true,
  learnersMayShare: false,
  repeat: 'none',
  repeatEnd: 'count',
  repeatCount: 4,
  repeatUntil: '',
});

/** The editor's state for an existing room (one date of it). */
export const roomToForm = (room) => ({
  title: room.title,
  description: room.description ?? '',
  agenda: room.agenda ?? '',
  startsAtLocal: localInputValue(room.startsAt, room.timeZone),
  durationMinutes: Math.round((new Date(room.endsAt) - new Date(room.startsAt)) / 60_000),
  timeZone: room.timeZone,
  earlyEntryMinutes: room.earlyEntryMinutes,
  lateJoinMinutes: room.lateJoinMinutes ?? null,
  capacityMode: room.capacity ? 'limit' : 'plan',
  capacity: room.capacity ?? 25,
  access: room.access,
  approval: room.approval,
  invitees: room.invitees ?? [],
  cohosts: room.cohosts ?? [],
  learnersJoinMuted: room.settings?.learnersJoinMuted ?? false,
  reactionsEnabled: room.settings?.reactionsEnabled ?? true,
  learnersMayShare: room.settings?.learnersMayShare ?? false,
  repeat: 'none',
  repeatEnd: 'count',
  repeatCount: 4,
  repeatUntil: '',
});

export const recurrenceOf = (form) => {
  if (form.repeat === 'none') return null;
  const end = form.repeatEnd === 'until' && form.repeatUntil ? { until: form.repeatUntil } : { count: Number(form.repeatCount) };
  if (form.repeat === 'daily') return { freq: 'DAILY', ...end };
  if (form.repeat === 'weekdays') return { freq: 'WEEKLY', byDay: WORKDAYS, ...end };
  if (form.repeat === 'biweekly') return { freq: 'WEEKLY', interval: 2, byDay: [weekdayOf(form.startsAtLocal)], ...end };
  return { freq: 'WEEKLY', byDay: [weekdayOf(form.startsAtLocal)], ...end };
};

/** The API's input for a form. `editing` leaves the series out: one date is edited at a time. */
export const formToInput = (form, { editing = false } = {}) => {
  const input = {
    title: form.title.trim(),
    description: form.description.trim() || null,
    startsAtLocal: form.startsAtLocal,
    durationMinutes: Number(form.durationMinutes),
    timeZone: form.timeZone,
    earlyEntryMinutes: Number(form.earlyEntryMinutes),
    lateJoinMinutes: form.lateJoinMinutes === null || form.lateJoinMinutes === '' ? null : Number(form.lateJoinMinutes),
    capacity: form.capacityMode === 'plan' ? null : Number(form.capacity),
    access: form.access,
    approval: Boolean(form.approval),
    inviteeIds: form.invitees.map((person) => person.userId),
    cohostIds: form.cohosts.map((person) => person.userId),
    settings: {
      learnersJoinMuted: Boolean(form.learnersJoinMuted),
      reactionsEnabled: Boolean(form.reactionsEnabled),
      learnersMayShare: Boolean(form.learnersMayShare),
      agenda: form.agenda.trim() || null,
    },
  };
  if (!editing) input.recurrence = recurrenceOf(form);
  return input;
};

/** Problems with a form, keyed by field; empty when it can be saved. */
export const validateForm = (form, config) => {
  const errors = {};
  if (!form.title.trim()) errors.title = 'Give the room a name.';
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(form.startsAtLocal)) errors.startsAtLocal = 'Choose a date and time.';
  const duration = Number(form.durationMinutes);
  if (!Number.isInteger(duration) || duration < config.duration.min || duration > config.duration.max) {
    errors.durationMinutes = `Between ${config.duration.min} minutes and ${config.duration.max / 60} hours.`;
  }
  const early = Number(form.earlyEntryMinutes);
  if (early < config.earlyEntry.min || early > config.earlyEntry.max) {
    errors.earlyEntryMinutes = `Between ${config.earlyEntry.min} and ${config.earlyEntry.max} minutes.`;
  }
  if (form.capacityMode === 'limit') {
    const seats = Number(form.capacity);
    if (!Number.isInteger(seats) || seats < config.capacity.min || seats > config.capacity.max) {
      errors.capacity = `Between ${config.capacity.min} and ${config.capacity.max} people.`;
    }
  }
  if (form.repeat !== 'none') {
    if (form.repeatEnd === 'until' && !form.repeatUntil) errors.repeat = 'Choose the last date.';
    if (form.repeatEnd === 'until' && form.repeatUntil && form.repeatUntil < form.startsAtLocal.slice(0, 10)) {
      errors.repeat = 'The last date is before the first.';
    }
    if (form.repeatEnd === 'count' && (Number(form.repeatCount) < 2 || Number(form.repeatCount) > 52)) {
      errors.repeat = 'Between 2 and 52 dates.';
    }
  }
  if (form.access === 'invited' && form.invitees.length === 0 && form.cohosts.length === 0) {
    errors.invitees = 'Invite at least one person, or let anyone with the link in.';
  }
  return errors;
};

// ---------------------------------------------------------------------------
// Words
// ---------------------------------------------------------------------------

/** "in 2 h 5 min", "in 4 min", "in 35 s", "now". */
export const countdown = (ms) => {
  if (ms <= 0) return 'now';
  const seconds = Math.ceil(ms / 1000);
  if (seconds < 60) return `in ${seconds} s`;
  const minutes = Math.ceil(seconds / 60);
  if (minutes < 60) return `in ${minutes} min`;
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  if (hours < 48) return rest ? `in ${hours} h ${rest} min` : `in ${hours} h`;
  return `in ${Math.round(hours / 24)} days`;
};

/** "1 h 30 min", "45 min". */
export const durationLabel = (minutes) => {
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  if (!hours) return `${rest} min`;
  return rest ? `${hours} h ${rest} min` : `${hours} h`;
};

export const PHASE_LABELS = {
  scheduled: 'Upcoming',
  'doors-open': 'Doors open',
  live: 'Live now',
  ended: 'Ended',
  cancelled: 'Cancelled',
};

export const phaseLabel = (phase) => PHASE_LABELS[phase] ?? phase;

/** Why someone cannot enter, in words for the lobby. */
export const reasonText = (reason, room) => {
  switch (reason) {
    case 'room_not_open':
      return 'The doors are not open yet.';
    case 'room_closed_for_entry':
      return `New people could join until ${room?.lateJoinMinutes ?? 0} minutes after the start.`;
    case 'needs_admission':
      return 'A host lets people in.';
    case 'room_full':
      return 'All seats are taken.';
    case 'room_ended':
      return 'This room has ended.';
    case 'room_cancelled':
      return 'This room was cancelled.';
    case 'not_invited':
      return 'This room is for invited people only.';
    default:
      return null;
  }
};

/** The time in the room's zone, plus the viewer's own time when it differs. */
export const timeInZones = (value, roomZone, viewerZone, locale) => {
  const format = (zone) =>
    new Intl.DateTimeFormat(locale, { timeZone: zone, hour: '2-digit', minute: '2-digit' }).format(new Date(value));
  const own = format(viewerZone);
  const theirs = format(roomZone);
  return own === theirs ? own : `${own} your time · ${theirs} ${roomZone.split('/').pop().replace(/_/g, ' ')}`;
};

export const REPEAT_OPTIONS = [
  { value: 'none', label: 'Once' },
  { value: 'weekly', label: 'Every week' },
  { value: 'biweekly', label: 'Every two weeks' },
  { value: 'weekdays', label: 'Every weekday (Mon–Fri)' },
  { value: 'daily', label: 'Every day' },
];

// ---------------------------------------------------------------------------
// Joining by code or link
// ---------------------------------------------------------------------------

const ROOM_CODE = /^[a-hjkmnp-z2-9]{3}-[a-hjkmnp-z2-9]{4}-[a-hjkmnp-z2-9]{3}$/;
const ROOM_ID = /^[A-Za-z0-9._:-]{1,64}$/;

/**
 * Where a pasted code or link leads: a scheduled room's lobby, or — for any
 * other room id — the room itself, as before. null for anything else.
 */
export const destinationFor = (input) => {
  const text = String(input ?? '').trim();
  if (!text) return null;
  const fromLink = /\/rooms\/([^/?#\s]+)/.exec(text)?.[1];
  let raw = fromLink ?? text;
  try {
    raw = decodeURIComponent(raw);
  } catch {
    return null;
  }
  if (ROOM_CODE.test(raw.toLowerCase())) return `/rooms/${raw.toLowerCase()}/lobby`;
  if (ROOM_ID.test(raw)) return `/rooms/${raw}`;
  return null;
};

// ---------------------------------------------------------------------------
// Sharing
// ---------------------------------------------------------------------------

const LOCAL = /^(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])$/;

const hostOf = (url) => {
  try {
    return new URL(url).hostname;
  } catch {
    return '';
  }
};

/**
 * The link to share for a room. The server builds it for the address this
 * page is on; should it still point at this machine (an older server, a
 * setting), the page's own address is used instead — a localhost link only
 * ever works for the person who made it.
 */
export const shareLinkFor = (room, pageOrigin) => {
  const fromServer = room?.url ?? '';
  if (fromServer && !(LOCAL.test(hostOf(fromServer)) && pageOrigin && !LOCAL.test(hostOf(pageOrigin)))) {
    return fromServer;
  }
  return pageOrigin ? `${pageOrigin.replace(/\/$/, '')}/rooms/${room.code}/lobby` : fromServer;
};
__RL_EOF__
echo "wrote apps/web/src/components/Rooms/roomModel.js"

mkdir -p apps/web/src/components/Rooms/__checks__
cat > apps/web/src/components/Rooms/__checks__/roomModel.check.mjs <<'__RL_EOF__'
// Rooms — the pure parts of the room form and the lobby.
// Run: node --test apps/web/src/components/Rooms/__checks__/*.check.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  countdown,
  defaultForm,
  destinationFor,
  shareLinkFor,
  durationLabel,
  formToInput,
  localInputValue,
  nextSlot,
  recurrenceOf,
  roomToForm,
  validateForm,
  weekdayOf,
} from '../roomModel.js';

const config = {
  earlyEntry: { min: 3, max: 10, default: 5 },
  duration: { min: 10, max: 480, presets: [30, 45, 60, 90] },
  capacity: { min: 2, max: 300, default: 25 },
};

test('local input values follow the time zone', () => {
  const moment = '2026-03-10T17:30:00Z';
  assert.equal(localInputValue(moment, 'UTC'), '2026-03-10T17:30');
  assert.equal(localInputValue(moment, 'Europe/Berlin'), '2026-03-10T18:30');
  assert.equal(localInputValue(moment, 'America/New_York'), '2026-03-10T13:30');
});

test('the default start is the next quarter hour at least 15 minutes away', () => {
  const slot = nextSlot(new Date('2026-03-10T10:07:12Z'));
  assert.equal(slot.toISOString(), '2026-03-10T10:30:00.000Z');
  assert.equal(nextSlot(new Date('2026-03-10T10:45:00Z')).toISOString(), '2026-03-10T11:00:00.000Z');
});

test('weekdays and series', () => {
  assert.equal(weekdayOf('2026-10-06T18:00'), 'TU');
  const form = { ...defaultForm({ timeZone: 'UTC' }), startsAtLocal: '2026-10-06T18:00' };
  assert.equal(recurrenceOf(form), null);
  assert.deepEqual(recurrenceOf({ ...form, repeat: 'weekly', repeatCount: 6 }), { freq: 'WEEKLY', byDay: ['TU'], count: 6 });
  assert.deepEqual(recurrenceOf({ ...form, repeat: 'biweekly', repeatEnd: 'until', repeatUntil: '2026-12-01' }), {
    freq: 'WEEKLY', interval: 2, byDay: ['TU'], until: '2026-12-01',
  });
  assert.deepEqual(recurrenceOf({ ...form, repeat: 'weekdays', repeatCount: 10 }).byDay, ['MO', 'TU', 'WE', 'TH', 'FR']);
});

test('a form becomes the API input, and an edit carries no series', () => {
  const form = {
    ...defaultForm({ timeZone: 'Europe/Berlin' }),
    title: '  Maths revision ',
    startsAtLocal: '2026-10-06T18:00',
    invitees: [{ userId: 'u1', displayName: 'Anna' }],
    capacityMode: 'plan',
    repeat: 'weekly',
    agenda: ' 1. Fractions ',
  };
  const input = formToInput(form);
  assert.equal(input.title, 'Maths revision');
  assert.equal(input.capacity, null);
  assert.deepEqual(input.inviteeIds, ['u1']);
  assert.equal(input.settings.agenda, '1. Fractions');
  assert.equal(input.recurrence.freq, 'WEEKLY');
  assert.equal('recurrence' in formToInput(form, { editing: true }), false);
});

test('validation explains what is missing', () => {
  const base = { ...defaultForm({ timeZone: 'UTC' }), title: 'Room', access: 'link' };
  assert.deepEqual(validateForm(base, config), {});
  assert.ok(validateForm({ ...base, title: ' ' }, config).title);
  assert.ok(validateForm({ ...base, earlyEntryMinutes: 15 }, config).earlyEntryMinutes);
  assert.ok(validateForm({ ...base, earlyEntryMinutes: 2 }, config).earlyEntryMinutes);
  assert.ok(validateForm({ ...base, capacity: 1 }, config).capacity);
  assert.ok(validateForm({ ...base, access: 'invited' }, config).invitees);
  assert.ok(validateForm({ ...base, repeat: 'weekly', repeatEnd: 'until', repeatUntil: '2000-01-01' }, config).repeat);
});

test('an existing room fills the editor', () => {
  const form = roomToForm({
    title: 'T', description: null, agenda: 'A', startsAt: '2026-10-06T16:00:00Z', endsAt: '2026-10-06T17:30:00Z',
    timeZone: 'Europe/Berlin', earlyEntryMinutes: 7, lateJoinMinutes: 10, capacity: null, access: 'link', approval: true,
    invitees: [], cohosts: [], settings: { learnersJoinMuted: true },
  });
  assert.equal(form.startsAtLocal, '2026-10-06T18:00');
  assert.equal(form.durationMinutes, 90);
  assert.equal(form.capacityMode, 'plan');
  assert.equal(form.learnersJoinMuted, true);
});

test('countdowns and durations read naturally', () => {
  assert.equal(countdown(0), 'now');
  assert.equal(countdown(35_000), 'in 35 s');
  assert.equal(countdown(4 * 60_000 + 1), 'in 5 min');
  assert.equal(countdown((2 * 60 + 5) * 60_000), 'in 2 h 5 min');
  assert.equal(countdown(3 * 24 * 3_600_000), 'in 3 days');
  assert.equal(durationLabel(45), '45 min');
  assert.equal(durationLabel(90), '1 h 30 min');
  assert.equal(durationLabel(120), '2 h');
});

test('a pasted code or link leads to the right place', () => {
  assert.equal(destinationFor('kqz-7hfd-2mx'), '/rooms/kqz-7hfd-2mx/lobby');
  assert.equal(destinationFor(' KQZ-7HFD-2MX '), '/rooms/kqz-7hfd-2mx/lobby');
  assert.equal(destinationFor('https://app.example/rooms/kqz-7hfd-2mx/lobby'), '/rooms/kqz-7hfd-2mx/lobby');
  assert.equal(destinationFor('https://app.example/rooms/kqz-7hfd-2mx'), '/rooms/kqz-7hfd-2mx/lobby');
  assert.equal(destinationFor('00000000-0000-0000-0000-000000000000'), '/rooms/00000000-0000-0000-0000-000000000000');
  assert.equal(destinationFor('not a room!'), null);
  assert.equal(destinationFor(''), null);
});

test('a shared link never points at localhost when the page is not on it', () => {
  const room = { code: 'kqz-7hfd-2mx', url: 'http://localhost:5173/rooms/kqz-7hfd-2mx/lobby' };
  const page = 'https://cs-5173.app.github.dev';
  assert.equal(shareLinkFor(room, page), 'https://cs-5173.app.github.dev/rooms/kqz-7hfd-2mx/lobby');
  assert.equal(shareLinkFor({ ...room, url: 'https://cs-5173.app.github.dev/rooms/kqz-7hfd-2mx/lobby' }, page), 'https://cs-5173.app.github.dev/rooms/kqz-7hfd-2mx/lobby');
  assert.equal(shareLinkFor(room, 'http://localhost:5173'), room.url);
  assert.equal(shareLinkFor({ ...room, url: 'https://class.example.org/rooms/kqz-7hfd-2mx/lobby' }, page), 'https://class.example.org/rooms/kqz-7hfd-2mx/lobby');
});
__RL_EOF__
echo "wrote apps/web/src/components/Rooms/__checks__/roomModel.check.mjs"

mkdir -p apps/web/src/pages
cat > apps/web/src/pages/RoomLobbyPage.jsx <<'__RL_EOF__'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Link, Navigate, useLocation, useNavigate, useParams } from 'react-router-dom';
import { createRoomsApi, useCore } from '@classroom/core-client';

import DeviceCheck from '../components/Rooms/DeviceCheck.jsx';
import { countdown, durationLabel, phaseLabel, reasonText, shareLinkFor, timeInZones } from '../components/Rooms/roomModel.js';
import { formatDate, formatTime } from '../lib/preferences.js';
import { onUserEvent } from '../lib/userEvents.js';
import '../components/Rooms/rooms.css';

/**
 * The lobby of a room  (Rooms)  —  /rooms/<code>/lobby
 *
 * Where a room link lands. Before the doors open: a countdown, what the room
 * is about, and a camera check. When they open: "Enter room". Around that,
 * the lobby handles everything the room's settings ask for — knocking when a
 * host lets people in, the waiting list when every seat is taken (a freed
 * seat is held for you for two minutes) — and, for hosts, sharing, the
 * knock queue, editing and cancelling.
 *
 * What the server allows is the truth (GET /scheduled-rooms/<code>, and the
 * socket join checks again); the clock here is only corrected by the
 * server's time, never trusted on its own.
 */

const viewerZone = () => Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC';

const copy = async (text) => {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
};

function useNow(intervalMs = 1_000) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), intervalMs);
    return () => window.clearInterval(timer);
  }, [intervalMs]);
  return now;
}

function SharePanel({ room, rooms, highlight }) {
  const [copied, setCopied] = useState(false);
  const [qr, setQr] = useState(null);
  const link = shareLinkFor(room, window.location.origin);

  useEffect(() => {
    let cancelled = false;
    rooms
      .qr(room.code)
      .then((result) => !cancelled && setQr(result.dataUrl))
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, [rooms, room.code]);

  const downloadCalendar = async () => {
    const blob = await rooms.calendarFile(room.code);
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = `${room.title.replace(/[^\w-]+/g, '-').slice(0, 40) || 'room'}.ics`;
    link.click();
    window.setTimeout(() => URL.revokeObjectURL(url), 10_000);
  };

  return (
    <section className={highlight ? 'rm-share is-new' : 'rm-share'} aria-label="Share this room">
      {highlight ? <p className="rm-label">Your room is ready. Share the link:</p> : <p className="rm-label">Link</p>}
      <div className="rm-share__row">
        <code className="rm-share__url">{link}</code>
        <button
          type="button"
          className="btn btn--tiny"
          onClick={async () => {
            setCopied(await copy(link));
            window.setTimeout(() => setCopied(false), 2_000);
          }}
        >
          {copied ? 'Copied' : 'Copy link'}
        </button>
        <button type="button" className="btn btn--tiny" onClick={() => downloadCalendar().catch(() => undefined)}>
          Add to calendar
        </button>
      </div>
      <p className="rm-hint">
        {room.access === 'link'
          ? 'Anyone in your organisation who has this link can come in.'
          : 'Only invited people can come in; for everyone else the link does nothing.'}{' '}
        Room code <strong>{room.code}</strong>
      </p>
      {qr ? <img className="rm-share__qr" src={qr} alt={`QR code for ${link}`} width={132} height={132} /> : null}
    </section>
  );
}

function KnockQueue({ room, rooms, onChange }) {
  const [knocks, setKnocks] = useState([]);

  const load = useCallback(async () => {
    try {
      setKnocks((await rooms.knocks(room.code)).items);
    } catch {
      // Shown again on the next poll.
    }
  }, [rooms, room.code]);

  useEffect(() => {
    load();
    const timer = window.setInterval(load, 5_000);
    return () => window.clearInterval(timer);
  }, [load]);

  if (!room.approval) return null;
  const act = async (fn) => {
    await fn().catch(() => undefined);
    await load();
    onChange();
  };

  return (
    <section className="rm-panel" aria-live="polite">
      <div className="rm-panel__head">
        <p className="rm-label">Waiting to be let in ({knocks.length})</p>
        {knocks.length > 1 ? (
          <button type="button" className="btn btn--tiny" onClick={() => act(() => rooms.admit(room.code, []))}>
            Admit all
          </button>
        ) : null}
      </div>
      {knocks.length === 0 ? <p className="rm-hint">Nobody is knocking.</p> : null}
      <ul className="rm-list">
        {knocks.map((knock) => (
          <li key={knock.userId}>
            <span>{knock.displayName}</span>
            <span className="rm-inline">
              <button type="button" className="btn btn--tiny btn--primary" onClick={() => act(() => rooms.admit(room.code, [knock.userId]))}>
                Admit
              </button>
              <button type="button" className="btn btn--tiny" onClick={() => act(() => rooms.deny(room.code, knock.userId))}>
                Decline
              </button>
            </span>
          </li>
        ))}
      </ul>
    </section>
  );
}

function HostPanel({ room, rooms, navigate, reload }) {
  const [cancelling, setCancelling] = useState(false);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);
  const isHost = room.viewer.relation === 'host';
  const open = room.phase !== 'ended' && room.phase !== 'cancelled';

  const cancel = async (scope) => {
    setBusy(true);
    setError(null);
    try {
      await rooms.cancel(room.code, { scope, reason: reason.trim() || null });
      setCancelling(false);
      reload();
    } catch (cause) {
      setError(cause?.detail ?? 'The room was not cancelled.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="rm-panel">
      <p className="rm-label">{isHost ? 'You host this room' : 'You co-host this room'}</p>
      <p className="rm-hint">
        {room.occupied} in the room
        {room.capacity ? ` of ${room.capacity} seats` : ''}
        {room.invitees ? ` · ${room.invitees.length} invited` : ''}
        {room.cohosts.length ? ` · co-hosts: ${room.cohosts.map((c) => c.displayName).join(', ')}` : ''}
      </p>
      {isHost && open ? (
        <div className="rm-inline">
          <Link className="btn btn--tiny" to={`/rooms/${room.code}/edit`}>
            Edit
          </Link>
          <Link className="btn btn--tiny" to={`/rooms/new?from=${room.code}`}>
            Copy to a new date
          </Link>
          <button type="button" className="btn btn--tiny" onClick={() => setCancelling((v) => !v)}>
            Cancel room…
          </button>
        </div>
      ) : null}
      {isHost && !open ? (
        <Link className="btn btn--tiny" to={`/rooms/new?from=${room.code}`}>
          Plan it again
        </Link>
      ) : null}
      {cancelling ? (
        <div className="rm-confirm">
          <input className="rm-input" placeholder="Reason (optional, sent to invitees)" value={reason} maxLength={300} onChange={(e) => setReason(e.target.value)} />
          <div className="rm-inline">
            <button type="button" className="btn btn--tiny btn--danger" disabled={busy} onClick={() => cancel('this')}>
              Cancel this date
            </button>
            {room.seriesId ? (
              <button type="button" className="btn btn--tiny btn--danger" disabled={busy} onClick={() => cancel('following')}>
                Cancel this and all later dates
              </button>
            ) : null}
            <button type="button" className="btn btn--tiny" onClick={() => setCancelling(false)}>
              Keep it
            </button>
          </div>
          {error ? <p className="rm-error">{error}</p> : null}
        </div>
      ) : null}
      {room.viewer.canEnter ? null : (
        <p className="rm-hint">You can open the room from {formatTime(room.hostOpensAt)}.</p>
      )}
      <button type="button" className="rm-link rm-back" onClick={() => navigate('/')}>
        All my rooms
      </button>
    </section>
  );
}

export default function RoomLobbyPage() {
  const { code } = useParams();
  const navigate = useNavigate();
  const location = useLocation();
  const core = useCore();
  const { http, status } = core;
  const rooms = useMemo(() => createRoomsApi(http), [http]);

  const [room, setRoom] = useState(null);
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);
  const [skew, setSkew] = useState(0);
  const now = useNow();
  const loading = useRef(false);

  const load = useCallback(async () => {
    if (loading.current) return;
    loading.current = true;
    try {
      const next = await rooms.get(code);
      setSkew(new Date(next.serverTime).getTime() - Date.now());
      setRoom(next);
      setError(null);
    } catch (cause) {
      setError(cause?.detail ?? cause?.message ?? 'This room could not be loaded.');
    } finally {
      loading.current = false;
    }
  }, [rooms, code]);

  useEffect(() => {
    if (status !== 'authenticated') return undefined;
    load();
    const timer = window.setInterval(load, 10_000);
    return () => window.clearInterval(timer);
  }, [load, status]);

  // Being let in, a freed seat, a knock: reload at once instead of on the next poll.
  useEffect(() => {
    if (status !== 'authenticated') return undefined;
    const offs = ['room:admitted', 'room:denied', 'room:seat-available', 'room:knock'].map((event) =>
      onUserEvent(core, event, (payload) => {
        if (!payload?.code || payload.code === code) load();
      }),
    );
    return () => offs.forEach((off) => off());
  }, [core, status, code, load]);

  // The doors open while someone watches the countdown: ask the server then, not 10 s later.
  const serverNow = now + skew;
  const opensAt = room?.viewer?.opensAt ? new Date(room.viewer.opensAt).getTime() : null;
  useEffect(() => {
    if (opensAt && serverNow >= opensAt && !room?.viewer?.canEnter) load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [opensAt && serverNow >= opensAt]);

  if (status === 'anonymous') {
    return <Navigate to="/login" replace state={{ from: `/rooms/${code}/lobby` }} />;
  }

  if (error && !room) {
    return (
      <main className="rm-lobby">
        <div className="rm-lobby__card">
          <h1>Room not found</h1>
          <p className="muted">{error}</p>
          <Link className="btn" to="/">
            Back
          </Link>
        </div>
      </main>
    );
  }

  if (!room) {
    return (
      <main className="rm-lobby">
        <p className="muted">Loading…</p>
      </main>
    );
  }

  const { viewer } = room;
  const minutes = Math.round((new Date(room.endsAt) - new Date(room.startsAt)) / 60_000);
  const act = async (fn) => {
    setBusy(true);
    try {
      setRoom(await fn());
    } catch (cause) {
      setError(cause?.detail ?? cause?.message ?? 'That did not work.');
    } finally {
      setBusy(false);
    }
  };

  const enter = () => navigate(`/rooms/${room.code}`);
  const startsIn = new Date(room.startsAt).getTime() - serverNow;
  const endsIn = new Date(room.endsAt).getTime() - serverNow;
  const holdLeft = viewer.holdUntil ? new Date(viewer.holdUntil).getTime() - serverNow : 0;

  let action;
  if (viewer.canEnter) {
    action = (
      <>
        {holdLeft > 0 ? <p className="rm-good">A seat is free and held for you — {countdown(holdLeft).replace('in ', '')} left.</p> : null}
        <button type="button" className="btn btn--primary rm-enter" onClick={enter}>
          {room.phase === 'live' ? 'Enter room' : viewer.moderator ? 'Open the room' : 'Enter room'}
        </button>
        <p className="rm-hint">
          {room.phase === 'live' ? `Running · ends ${countdown(endsIn)}` : `Starts ${countdown(startsIn)}`}
        </p>
      </>
    );
  } else if (viewer.reason === 'room_not_open' && opensAt) {
    action = (
      <>
        <p className="rm-countdown" aria-live="polite">
          Doors open {countdown(opensAt - serverNow)}
        </p>
        <p className="rm-hint">at {formatTime(viewer.opensAt)} · the page opens the doors for you</p>
      </>
    );
  } else if (viewer.reason === 'needs_admission') {
    action = viewer.knocked ? (
      <>
        <p className="rm-countdown">Waiting for a host to let you in…</p>
        <button type="button" className="btn btn--tiny" disabled={busy} onClick={() => act(() => rooms.withdrawKnock(room.code))}>
          Stop asking
        </button>
      </>
    ) : (
      <>
        <p className="rm-hint">A host lets people in.</p>
        <button type="button" className="btn btn--primary rm-enter" disabled={busy} onClick={() => act(() => rooms.knock(room.code))}>
          Ask to join
        </button>
      </>
    );
  } else if (viewer.reason === 'room_full') {
    action = viewer.waitlistPosition ? (
      <>
        <p className="rm-countdown">You are number {viewer.waitlistPosition} on the waiting list.</p>
        <p className="rm-hint">When a seat is free it is held for you for 2 minutes, and you are told at once.</p>
        <button type="button" className="btn btn--tiny" disabled={busy} onClick={() => act(() => rooms.leaveWaitlist(room.code))}>
          Leave the waiting list
        </button>
      </>
    ) : (
      <>
        <p className="rm-hint">All {room.effectiveCapacity} seats are taken.</p>
        <button type="button" className="btn btn--primary rm-enter" disabled={busy} onClick={() => act(() => rooms.joinWaitlist(room.code))}>
          Join the waiting list
        </button>
      </>
    );
  } else {
    action = <p className="rm-countdown">{viewer.message ?? reasonText(viewer.reason, room) ?? 'You cannot enter this room.'}</p>;
  }

  return (
    <main className="rm-lobby">
      <div className="rm-lobby__grid">
        <section className="rm-lobby__card">
          <div className="rm-card__top">
            <span className={`rm-phase rm-phase--${room.phase}`}>{phaseLabel(room.phase)}</span>
            <span className="rm-hint">by {room.host.displayName}</span>
          </div>
          <h1 className="rm-lobby__title">{room.title}</h1>
          <p className="rm-card__when">
            {formatDate(room.startsAt)} · {timeInZones(room.startsAt, room.timeZone, viewerZone())} · {durationLabel(minutes)}
          </p>
          {room.cancelReason && room.phase === 'cancelled' ? <p className="rm-error">Cancelled: {room.cancelReason}</p> : null}
          {room.description ? <p className="rm-lobby__text">{room.description}</p> : null}
          {room.agenda ? (
            <div className="rm-agenda">
              <p className="rm-label">Agenda</p>
              <ol>
                {room.agenda
                  .split('\n')
                  .map((line) => line.replace(/^\s*(\d+[.)]|[-*•])\s*/, '').trim())
                  .filter(Boolean)
                  .map((line, index) => (
                    <li key={`${index}-${line}`}>{line}</li>
                  ))}
              </ol>
            </div>
          ) : null}

          <div className="rm-action">{action}</div>
          {error ? <p className="rm-error">{error}</p> : null}

          <ul className="rm-facts">
            <li>Doors open {room.earlyEntryMinutes} minutes before the start ({formatTime(room.doorsOpenAt)})</li>
            {room.lateUntil ? <li>No new arrivals after {formatTime(room.lateUntil)}</li> : null}
            {room.capacity ? <li>{room.capacity} seats</li> : null}
            {room.approval ? <li>A host lets people in</li> : null}
            {room.settings.learnersJoinMuted ? <li>You join muted</li> : null}
          </ul>
        </section>

        <aside className="rm-lobby__side">
          {viewer.moderator || room.access === 'link' ? (
            <SharePanel room={room} rooms={rooms} highlight={Boolean(location.state?.created)} />
          ) : null}
          {location.state?.created && location.state?.occurrences?.length > 1 ? (
            <p className="rm-hint">
              {location.state.occurrences.length} dates created, each with its own link. Find them all under “My rooms”.
            </p>
          ) : null}
          {viewer.moderator ? <KnockQueue room={room} rooms={rooms} onChange={load} /> : null}
          {viewer.moderator ? <HostPanel room={room} rooms={rooms} navigate={navigate} reload={load} /> : null}
          {room.phase !== 'ended' && room.phase !== 'cancelled' ? (
            <section className="rm-panel">
              <p className="rm-label">Camera and microphone</p>
              <DeviceCheck />
            </section>
          ) : null}
          {!viewer.moderator ? (
            <Link className="rm-link rm-back" to="/">
              All my rooms
            </Link>
          ) : null}
        </aside>
      </div>
    </main>
  );
}
__RL_EOF__
echo "wrote apps/web/src/pages/RoomLobbyPage.jsx"

cat > .rooms-links-patch.mjs <<'__RL_EOF__'
import { existsSync, readFileSync, writeFileSync } from 'node:fs';

/*
 * Rooms · links — every other place that builds a link to the app uses the
 * public address (config/publicUrl.js) instead of APP_URL.
 * Every anchor must be found exactly once; if one is not, nothing is written
 * to any of these files and the installer stops.
 */

const plan = [
  {
    file: 'server/src/notifications/config.js',
    marker: 'publicAppUrl',
    edits: [
      {
        name: 'import the public address',
        find: "import { env } from '../config/env.js';\n",
        replace: "import { env } from '../config/env.js';\nimport { publicAppUrl } from '../config/publicUrl.js';\n",
      },
      {
        name: 'links in emails and push open the public address, not localhost',
        find: "  appUrl: String(read('APP_URL', 'http://localhost:5173')).replace(/\\/$/, ''),\n",
        replace: '  appUrl: publicAppUrl(),\n',
      },
    ],
  },
  {
    file: 'server/src/identity/AuthService.js',
    marker: 'publicAppUrl',
    edits: [
      {
        name: 'import the public address',
        find: "import * as LoginChallenge from './loginChallenge.js';\n",
        replace:
          "import * as LoginChallenge from './loginChallenge.js';\n" +
          "import { publicAppUrl } from '../config/publicUrl.js';\n",
      },
      {
        name: 'email verification link',
        find: '    href: `${env.APP_URL}/verify-email?token=${token}`,\n',
        replace: '    href: `${publicAppUrl()}/verify-email?token=${token}`,\n',
      },
      {
        name: 'password reset link',
        find: '      href: `${env.APP_URL}/reset-password?token=${token}`,\n',
        replace: '      href: `${publicAppUrl()}/reset-password?token=${token}`,\n',
      },
    ],
  },
  {
    file: 'server/src/identity/passkeys.js',
    marker: 'publicAppUrl',
    edits: [
      {
        name: 'import the public address',
        find: "import { env } from '../config/env.js';\n",
        replace: "import { env } from '../config/env.js';\nimport { publicAppUrl } from '../config/publicUrl.js';\n",
      },
      {
        name: 'passkeys also work on the public address',
        find: '  const allowed = new Set([originOf(env.APP_URL), ...(env.ALLOWED_ORIGINS ?? []).map(originOf)].filter(Boolean));\n',
        replace:
          '  const allowed = new Set(\n' +
          '    [originOf(env.APP_URL), originOf(publicAppUrl()), ...(env.ALLOWED_ORIGINS ?? []).map(originOf)].filter(Boolean),\n' +
          '  );\n',
      },
    ],
  },
];

const results = [];
for (const entry of plan) {
  if (!existsSync(entry.file)) {
    console.error(`${entry.file}: not found. Nothing was changed in any patched file.`);
    process.exit(1);
  }
  let src = readFileSync(entry.file, 'utf8');
  if (src.includes(entry.marker)) {
    console.log(`${entry.file}: already patched, nothing to do`);
    continue;
  }
  for (const edit of entry.edits) {
    const n = src.split(edit.find).length - 1;
    if (n !== 1) {
      console.error(`${entry.file}: "${edit.name}": expected the anchor exactly once, found ${n}. Nothing was changed in any patched file.`);
      process.exit(1);
    }
  }
  for (const edit of entry.edits) src = src.replace(edit.find, () => edit.replace);
  results.push({ ...entry, src });
}

for (const entry of results) {
  writeFileSync(entry.file, entry.src);
  console.log('patched', entry.file);
  for (const edit of entry.edits) console.log('  -', edit.name);
}
__RL_EOF__
node .rooms-links-patch.mjs
rm -f .rooms-links-patch.mjs

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
echo "--- checks"
ESBUILD=""
[ -x node_modules/.bin/esbuild ] && ESBUILD=node_modules/.bin/esbuild
FAILED=0
for f in "${TOUCHED[@]}"; do
  [ -f "$f" ] || continue
  case "$f" in
    *.js|*.mjs) if node --check "$f"; then echo "ok  $f"; else FAILED=1; fi ;;
    *.ts) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.ts=ts --log-level=error >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
    *.jsx) if [ -n "$ESBUILD" ]; then if "$ESBUILD" "$f" --loader:.jsx=jsx --jsx=automatic --log-level=error >/dev/null; then echo "ok  $f"; else FAILED=1; fi; else echo "--  $f (no esbuild to check)"; fi ;;
    *) echo "ok  $f" ;;
  esac
done
if [ "$FAILED" -ne 0 ]; then
  echo "A file did not pass its check (see above). Undo with: bash rooms-links-install.sh --restore" >&2
  exit 1
fi

echo "--- rules (node --test)"
CHECKS=$(ls server/test/settings/*.check.mjs server/test/rooms/*.check.mjs \
  apps/web/src/components/Settings/__checks__/*.check.mjs apps/web/src/components/Rooms/__checks__/*.check.mjs 2>/dev/null || true)
if node --test $CHECKS > .rooms-links-test.log 2>&1; then
  PASSED=$(grep -E '^(# |ℹ )pass [0-9]+' .rooms-links-test.log | tail -1 | awk '{print $NF}')
  echo "ok  ${PASSED:-all} rule tests passed"
  rm -f .rooms-links-test.log
else
  cat .rooms-links-test.log
  rm -f .rooms-links-test.log
  echo "The rule checks failed (see above). Undo with: bash rooms-links-install.sh --restore" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# The address links will use from now on
# ---------------------------------------------------------------------------
echo "--- public address"
PUBLIC_URL=$(cd server && node --env-file-if-exists=../.env --input-type=module -e "
  const { resolvePublicAppUrl } = await import('./src/config/publicUrlRules.js');
  console.log(resolvePublicAppUrl({ environment: process.env, appUrl: process.env.APP_URL }));
" 2>/dev/null || echo "?")
echo "links now open: $PUBLIC_URL"
echo "(pin a different one with PUBLIC_APP_URL=https://… in .env)"

# ---------------------------------------------------------------------------
# Codespaces: a private port only opens for the Codespace's owner. For other
# people to open a room link, the web port has to be public.
# ---------------------------------------------------------------------------
if [ -n "${CODESPACE_NAME:-}" ]; then
  echo "--- Codespace ports"
  WEB_PORT=$(node -e "try{const u=new URL(process.argv[1]);console.log(u.port||'5173')}catch{console.log('5173')}" "$(grep -E '^APP_URL=' .env 2>/dev/null | tail -1 | cut -d= -f2-)")
  PORTS=("$WEB_PORT")
  # The API port too, if the web app calls it directly rather than through Vite.
  if grep -hqE '^VITE_(API|WS)_URL=.*(:4000|-4000\.)' .env apps/web/.env apps/web/.env.local 2>/dev/null; then PORTS+=("4000"); fi
  if [ "$KEEP_PRIVATE" -eq 1 ]; then
    echo "left as they are (--keep-private). Only you can open links until port $WEB_PORT is public:"
    echo "  gh codespace ports visibility ${WEB_PORT}:public -c \"\$CODESPACE_NAME\""
  else
    ARGS=()
    for p in "${PORTS[@]}"; do ARGS+=("${p}:public"); done
    if gh codespace ports visibility "${ARGS[@]}" -c "$CODESPACE_NAME" >/dev/null 2>&1; then
      echo "made public: ${PORTS[*]} — anyone with a room link can reach the app (they still sign in)"
      echo "back to private: gh codespace ports visibility ${WEB_PORT}:private -c \"\$CODESPACE_NAME\""
    else
      echo "WARN could not change the port visibility. In the Ports tab: right-click ${WEB_PORT} → Port Visibility → Public"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Restart
# ---------------------------------------------------------------------------
touch server/src/server.js
[ -f server/src/worker.js ] && touch server/src/worker.js
echo
echo "Links updated. The API and the worker restart on their own; reload the browser"
echo "tabs with Ctrl+Shift+R. Links already sent by email still point at the old address."