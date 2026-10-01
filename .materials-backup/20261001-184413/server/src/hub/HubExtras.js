// classroom-app/server/src/hub/HubExtras.js
/**
 * Community, part 2  (Community)
 *
 *   knowledge cards   moderators save a good answer as a card; everyone in the
 *                     space can search the cards later
 *   materials         links the space keeps at hand, pinned ones first
 *   chat              quick messages in a space, next to the threads
 *   rooms             drop-in rooms that belong to the space: any member can
 *                     start one; they use the rooms feature (doors, seats,
 *                     lobby, closing on time) and the space's members may enter
 *   live now          which rooms in your spaces are open, and how many are in
 *
 * Same rules as part 1 (hub/hubRules.js): what a space shows to whom,
 * blocks in both directions, posting pauses, ended study groups.
 */

import { pool } from '../db/pool.js';
import { logger } from '../observability/logger.js';
import * as Rules from './hubRules.js';
import { internals } from './HubService.js';
import * as Part3 from './partRules.js';

const log = logger.child({ component: 'community-extras' });
const { loadSpace, notify, notBlocked, iso, fail, logAction } = internals;

const requireFullView = async (viewer, spaceId) => {
  const loaded = await loadSpace(viewer, spaceId);
  if (Rules.viewOf(loaded.space, loaded.membership) !== 'full') fail('forbidden', 'Join the space to see this.');
  return loaded;
};

// ---------------------------------------------------------------------------
// Knowledge cards
// ---------------------------------------------------------------------------

const toCard = (row) => ({
  cardId: row.id,
  spaceId: row.space_id,
  threadId: row.thread_id ?? null,
  postId: row.post_id ?? null,
  title: row.title,
  body: row.body,
  createdBy: row.author_name ?? null,
  createdAt: iso(row.created_at),
  updatedAt: iso(row.updated_at),
});

export const listCards = async ({ viewer, spaceId, q = null }) => {
  const { membership } = await requireFullView(viewer, spaceId);
  const params = [spaceId];
  let search = '';
  if (q) {
    params.push(q);
    search = `AND (c.title ILIKE '%' || $2 || '%' OR c.body ILIKE '%' || $2 || '%')`;
  }
  const { rows } = await pool.query(
    `SELECT c.*, u.display_name AS author_name FROM space_cards c LEFT JOIN users u ON u.id = c.created_by
      WHERE c.space_id = $1 AND c.deleted_at IS NULL ${search}
      ORDER BY c.updated_at DESC LIMIT 200`,
    params,
  );
  return { items: rows.map(toCard), canCurate: Rules.canCurate(membership) };
};

export const createCard = async ({ viewer, spaceId, input }) => {
  const { membership } = await requireFullView(viewer, spaceId);
  if (!Rules.canCurate(membership)) fail('forbidden', 'Only moderators save knowledge cards.');
  let threadId = null;
  if (input.postId) {
    const { rows } = await pool.query(
      `SELECT p.thread_id FROM posts p JOIN threads t ON t.id = p.thread_id WHERE p.id = $1 AND t.space_id = $2 AND p.deleted_at IS NULL`,
      [input.postId, spaceId],
    );
    if (!rows[0]) fail('not_found', 'That reply is not in this space.');
    threadId = rows[0].thread_id;
  }
  const { rows } = await pool.query(
    `INSERT INTO space_cards (space_id, thread_id, post_id, title, body, created_by)
     VALUES ($1, $2, $3, $4, $5, $6) RETURNING *`,
    [spaceId, threadId, input.postId ?? null, input.title, input.body, viewer.userId],
  );
  log.info({ spaceId, cardId: rows[0].id }, 'knowledge card saved');
  return toCard({ ...rows[0], author_name: viewer.displayName });
};

const loadCard = async (viewer, cardId) => {
  const { rows } = await pool.query(`SELECT * FROM space_cards WHERE id = $1 AND deleted_at IS NULL`, [cardId]);
  if (!rows[0]) fail('not_found', 'No such card');
  const { membership } = await requireFullView(viewer, rows[0].space_id);
  if (!Rules.canCurate(membership)) fail('forbidden', 'Only moderators change knowledge cards.');
  return rows[0];
};

export const updateCard = async ({ viewer, cardId, patch }) => {
  const card = await loadCard(viewer, cardId);
  const { rows } = await pool.query(
    `UPDATE space_cards SET title = coalesce($2, title), body = coalesce($3, body), updated_at = now() WHERE id = $1 RETURNING *`,
    [card.id, patch.title ?? null, patch.body ?? null],
  );
  return toCard(rows[0]);
};

export const removeCard = async ({ viewer, cardId }) => {
  const card = await loadCard(viewer, cardId);
  await pool.query(`UPDATE space_cards SET deleted_at = now() WHERE id = $1`, [card.id]);
  await logAction(card.space_id, viewer.userId, 'card.remove', { detail: { title: card.title } });
  return { removed: true };
};

// ---------------------------------------------------------------------------
// Materials
// ---------------------------------------------------------------------------

const toMaterial = (row) => {
  let host = null;
  try {
    host = new URL(row.url).hostname.replace(/^www\./, '');
  } catch {
    host = null;
  }
  return {
    materialId: row.id,
    title: row.title,
    url: row.url,
    host,
    note: row.note ?? null,
    pinned: Boolean(row.pinned),
    addedBy: row.author_name ?? null,
    createdAt: iso(row.created_at),
  };
};

export const listMaterials = async ({ viewer, spaceId }) => {
  const { membership } = await requireFullView(viewer, spaceId);
  const { rows } = await pool.query(
    `SELECT m.*, u.display_name AS author_name FROM space_materials m LEFT JOIN users u ON u.id = m.added_by
      WHERE m.space_id = $1 AND m.deleted_at IS NULL ORDER BY m.pinned DESC, m.created_at DESC LIMIT 200`,
    [spaceId],
  );
  return { items: rows.map(toMaterial), canCurate: Rules.canCurate(membership) };
};

export const addMaterial = async ({ viewer, spaceId, input }) => {
  const { membership } = await requireFullView(viewer, spaceId);
  if (!Rules.canCurate(membership)) fail('forbidden', 'Only moderators add materials.');
  const url = Rules.safeUrl(input.url);
  if (!url) fail('validation_failed', 'A web address starting with https:// is needed.');
  const { rows } = await pool.query(
    `INSERT INTO space_materials (space_id, title, url, note, pinned, added_by) VALUES ($1, $2, $3, $4, $5, $6) RETURNING *`,
    [spaceId, input.title, url, input.note ?? null, Boolean(input.pinned), viewer.userId],
  );
  return toMaterial({ ...rows[0], author_name: viewer.displayName });
};

const loadMaterial = async (viewer, materialId) => {
  const { rows } = await pool.query(`SELECT * FROM space_materials WHERE id = $1 AND deleted_at IS NULL`, [materialId]);
  if (!rows[0]) fail('not_found', 'No such material');
  const { membership } = await requireFullView(viewer, rows[0].space_id);
  if (!Rules.canCurate(membership)) fail('forbidden', 'Only moderators change materials.');
  return rows[0];
};

export const pinMaterial = async ({ viewer, materialId, pinned }) => {
  const material = await loadMaterial(viewer, materialId);
  const { rows } = await pool.query(`UPDATE space_materials SET pinned = $2 WHERE id = $1 RETURNING *`, [material.id, Boolean(pinned)]);
  return toMaterial(rows[0]);
};

export const removeMaterial = async ({ viewer, materialId }) => {
  const material = await loadMaterial(viewer, materialId);
  await pool.query(`UPDATE space_materials SET deleted_at = now() WHERE id = $1`, [material.id]);
  await logAction(material.space_id, viewer.userId, 'material.remove', { detail: { title: material.title } });
  return { removed: true };
};

// ---------------------------------------------------------------------------
// Chat
// ---------------------------------------------------------------------------

const toMessage = (row, viewer, membership) => ({
  messageId: row.id,
  body: row.body,
  author: { userId: row.author_id, displayName: row.display_name, you: row.author_id === viewer.userId },
  createdAt: iso(row.created_at),
  // Microseconds, as stored: a millisecond timestamp would fetch the last message twice.
  cursor: row.cursor,
  canRemove: Rules.canRemoveMessage({ authorId: row.author_id, viewerId: viewer.userId, membership }),
});

const CURSOR = `to_char(m.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')`;

/** The newest 80 messages, or those after a cursor (for catching up). Oldest first. */
export const listMessages = async ({ viewer, spaceId, after = null }) => {
  const { space, membership } = await requireFullView(viewer, spaceId);
  const params = [spaceId, viewer.userId];
  let since = '';
  if (after) {
    params.push(after);
    since = `AND m.created_at > $3::timestamptz`;
  }
  const { rows } = await pool.query(
    `SELECT * FROM (
       SELECT m.id, m.author_id, m.body, m.created_at, ${CURSOR} AS cursor, u.display_name
         FROM space_messages m JOIN users u ON u.id = m.author_id
        WHERE m.space_id = $1 AND m.deleted_at IS NULL ${since} AND ${notBlocked('m.author_id', '$2')}
        ORDER BY m.created_at DESC LIMIT 80) latest
      ORDER BY created_at ASC`,
    params,
  );
  const items = rows.map((row) => toMessage(row, viewer, membership));
  return {
    items,
    nextCursor: items.length ? items[items.length - 1].cursor : after,
    calmSeconds: space.chatSlowSeconds ?? 0,
    canModerate: Rules.isModerator(membership),
    postingBlocked: Rules.postingBlockedBecause(space, membership),
    serverTime: new Date().toISOString(),
  };
};

/** Members who are told a message arrived, so their open chat fetches it at once. */
const LIVE_FANOUT_LIMIT = 150;

export const sendMessage = async ({ viewer, spaceId, input }) => {
  const { space, membership } = await requireFullView(viewer, spaceId);
  const blocked = Rules.postingBlockedBecause(space, membership);
  if (blocked) fail('forbidden', blocked);
  if (space.chatSlowSeconds > 0 && !Rules.isModerator(membership)) {
    const { rows: last } = await pool.query(
      `SELECT max(created_at) AS at FROM space_messages WHERE space_id = $1 AND author_id = $2 AND deleted_at IS NULL`,
      [spaceId, viewer.userId],
    );
    const wait = Part3.calmWait({ slowSeconds: space.chatSlowSeconds, lastPostAt: last[0]?.at });
    if (wait > 0) fail('forbidden', Part3.calmMessage(wait));
  }
  const { rows } = await pool.query(
    `INSERT INTO space_messages AS m (space_id, author_id, body) VALUES ($1, $2, $3)
     RETURNING m.id, m.author_id, m.body, m.created_at, ${CURSOR} AS cursor`,
    [spaceId, viewer.userId, input.body],
  );
  try {
    const { rows: members } = await pool.query(
      `SELECT user_id FROM space_memberships WHERE space_id = $1 AND user_id <> $2 LIMIT ${LIVE_FANOUT_LIMIT}`,
      [spaceId, viewer.userId],
    );
    const { pushToUser } = await import('../realtime/userEvents.js');
    await Promise.all(members.map((member) => pushToUser(member.user_id, 'hub:chat', { spaceId })));
  } catch (cause) {
    log.debug({ err: cause }, 'chat live signal not sent; members catch up on their next fetch');
  }
  return toMessage({ ...rows[0], display_name: viewer.displayName }, viewer, membership);
};

export const removeMessage = async ({ viewer, messageId }) => {
  const { rows } = await pool.query(`SELECT id, space_id, author_id FROM space_messages WHERE id = $1 AND deleted_at IS NULL`, [messageId]);
  if (!rows[0]) fail('not_found', 'No such message');
  const { membership } = await requireFullView(viewer, rows[0].space_id);
  if (!Rules.canRemoveMessage({ authorId: rows[0].author_id, viewerId: viewer.userId, membership })) fail('forbidden', 'You cannot remove this message.');
  await pool.query(`UPDATE space_messages SET deleted_at = now(), deleted_by = $2 WHERE id = $1`, [messageId, viewer.userId]);
  if (rows[0].author_id !== viewer.userId) await logAction(rows[0].space_id, viewer.userId, 'chat.remove');
  return { removed: true };
};

// ---------------------------------------------------------------------------
// Rooms of a space
// ---------------------------------------------------------------------------

const occupancy = async (liveId) => {
  try {
    const { occupancy: read } = await import('../capacity/CapacityGuard.js');
    return (await read(liveId)).occupied ?? 0;
  } catch {
    return 0;
  }
};

const roomRules = () => import('../rooms/roomRules.js');

const toSpaceRoom = async (row) => {
  const R = await roomRules();
  const room = {
    startsAt: row.starts_at, endsAt: row.ends_at, status: row.status, earlyEntryMinutes: row.early_entry_min,
  };
  const phase = R.phaseOf(room);
  return {
    code: row.room_code,
    title: row.title,
    hostName: row.host_name,
    startsAt: iso(row.starts_at),
    endsAt: iso(row.ends_at),
    phase,
    dropIn: Boolean(row.room_settings?.dropIn),
    here: phase === 'live' || phase === 'doors-open' ? await occupancy(row.id) : 0,
    spaceId: row.space_id,
    spaceName: row.space_name ?? undefined,
  };
};

const ROOM_SELECT = `
  SELECT s.id, s.room_code, s.title, s.starts_at, s.ends_at, s.status, s.early_entry_min, s.room_settings, s.space_id,
         u.display_name AS host_name, sp.name AS space_name
    FROM scheduled_sessions s
    JOIN users u ON u.id = s.host_id
    JOIN spaces sp ON sp.id = s.space_id`;

/** Upcoming and running rooms of one space. */
export const listRooms = async ({ viewer, spaceId }) => {
  await requireFullView(viewer, spaceId);
  const { rows } = await pool.query(
    `${ROOM_SELECT}
      WHERE s.space_id = $1 AND s.room_code IS NOT NULL AND s.status IN ('scheduled', 'live') AND s.ends_at > now()
      ORDER BY s.starts_at LIMIT 20`,
    [spaceId],
  );
  return { items: await Promise.all(rows.map(toSpaceRoom)) };
};

/** What is live right now in any of my spaces, for Home and the rail. */
export const liveInMySpaces = async ({ viewer }) => {
  const { rows } = await pool.query(
    `${ROOM_SELECT}
      JOIN space_memberships m ON m.space_id = s.space_id AND m.user_id = $1
      WHERE s.room_code IS NOT NULL AND s.status IN ('scheduled', 'live')
        AND s.ends_at > now() AND s.starts_at - make_interval(mins => s.early_entry_min) <= now()
      ORDER BY s.starts_at LIMIT 10`,
    [viewer.userId],
  );
  return Promise.all(rows.map(toSpaceRoom));
};

/** "HH:MM" wall-clock of now in a time zone, as the room editor would send it. */
const localNow = (timeZone) => {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).formatToParts(new Date());
  const get = (type) => parts.find((part) => part.type === type)?.value ?? '00';
  return `${get('year')}-${get('month')}-${get('day')}T${get('hour') === '24' ? '00' : get('hour')}:${get('minute')}`;
};

/**
 * Starts a drop-in room for the space, now, for an hour. If one is already
 * open in this space, that one is returned instead: one study hall at a time.
 */
export const startDropIn = async ({ viewer, spaceId }) => {
  const { space, membership } = await requireFullView(viewer, spaceId);
  const blocked = Rules.postingBlockedBecause(space, membership);
  if (blocked) fail('forbidden', blocked);

  const { rows: open } = await pool.query(
    `${ROOM_SELECT}
      WHERE s.space_id = $1 AND s.room_code IS NOT NULL AND s.status IN ('scheduled', 'live')
        AND s.ends_at > now() AND s.starts_at <= now() + interval '5 minutes'
        AND (s.room_settings ->> 'dropIn') = 'true'
      ORDER BY s.starts_at LIMIT 1`,
    [spaceId],
  );
  if (open[0]) return { room: await toSpaceRoom(open[0]), started: false };

  const { rows: zone } = await pool.query(`SELECT time_zone FROM users WHERE id = $1`, [viewer.userId]);
  const timeZone = zone[0]?.time_zone || 'UTC';
  const Rooms = await import('../rooms/ScheduledRooms.js');
  let created;
  try {
    [created] = await Rooms.create({
      tenantId: viewer.tenantId,
      hostId: viewer.userId,
      input: {
        title: `${space.name}: drop-in`,
        description: `An open study room for everyone in ${space.name}.`,
        startsAtLocal: localNow(timeZone),
        durationMinutes: Rules.DROP_IN_MINUTES,
        timeZone,
        earlyEntryMinutes: 3,
        lateJoinMinutes: null,
        capacity: null,
        access: 'invited',
        approval: false,
        inviteeIds: [],
        cohostIds: [],
        settings: { learnersJoinMuted: true, reactionsEnabled: true, learnersMayShare: true, dropIn: true },
        recurrence: null,
      },
    });
  } catch (cause) {
    if (cause?.code === 'conflict') fail('conflict', 'You already have a room at this time. Join that one, or end it first.');
    throw cause;
  }
  await pool.query(
    `UPDATE scheduled_sessions SET space_id = $2, room_settings = room_settings || '{"dropIn": true}'::jsonb WHERE id = $1`,
    [created.id, spaceId],
  );
  const { rows } = await pool.query(`${ROOM_SELECT} WHERE s.id = $1`, [created.id]);
  const room = await toSpaceRoom(rows[0]);

  const { rows: members } = await pool.query(
    // Part 3: only people who want each notification from this space; "daily" gets it in the summary.
    `SELECT user_id FROM space_memberships WHERE space_id = $1 AND user_id <> $2 AND notify_mode = 'each' LIMIT 500`,
    [spaceId, viewer.userId],
  );
  await notify({
    userIds: members.map((member) => member.user_id),
    type: 'space.live',
    title: `${viewer.displayName} opened a drop-in room in ${space.name}`,
    body: 'Come in for the next hour.',
    href: `/rooms/${room.code}/lobby`,
    actorId: viewer.userId,
    data: { spaceId, roomCode: room.code },
    dedupeKey: `space.live:${spaceId}:${Math.floor(Date.now() / 3_600_000)}`,
  });
  log.info({ spaceId, code: room.code }, 'drop-in room started');
  return { room, started: true };
};

export { localNow };

export default {
  listCards, createCard, updateCard, removeCard, listMaterials, addMaterial, pinMaterial, removeMaterial,
  listMessages, sendMessage, removeMessage, listRooms, liveInMySpaces, startDropIn,
};
