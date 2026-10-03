// classroom-app/server/src/hub/SpaceChat.js
/**
 * The chat of a space  (Community)
 *
 * Replaces the chat part of HubExtras with the same building blocks as
 * Messages (messaging/ChatExtras.js), minus calls — those are what rooms are for:
 *
 *   list      the newest 80, or everything that changed after a cursor — new
 *             messages, edits, deletions and reactions alike (updated_at,
 *             033), so an open chat never shows something stale
 *   send      text, files (pictures, videos, documents) or one voice message,
 *             optionally as a reply; calm mode and posting blocks as before
 *   edit      your own text, within CHAT_EDIT_WINDOW_MIN
 *   remove    your own message ("deleted"), or anyone's as owner or moderator
 *             ("removed by a moderator", logged); members never delete others'
 *   react     one emoji at a time, at most 12 different per person
 *   media     pictures and videos · files · voice messages of the chat
 *
 * Members are told something changed (hub:chat) and fetch the changes; with no
 * live connection they catch up on their next poll.
 */

import { pool } from '../db/pool.js';
import { env } from '../config/env.js';
import { logger } from '../observability/logger.js';
import { internals } from './HubService.js';
import * as HubRules from './hubRules.js';
import * as Part3 from './partRules.js';
import * as Rules from './spaceChatRules.js';
import * as Extras from '../messaging/chatExtrasRules.js';
import * as Files from '../files/FileService.js';

const log = logger.child({ component: 'space-chat' });
const { loadSpace, notBlocked, iso, fail, logAction } = internals;

const LIMIT = 80;
const LIVE_FANOUT_LIMIT = 150;
const CURSOR = (column) => `to_char(${column} AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')`;

const requireFullView = async (viewer, spaceId) => {
  const loaded = await loadSpace(viewer, spaceId);
  if (HubRules.viewOf(loaded.space, loaded.membership) !== 'full') fail('forbidden', 'Join the space to see this.');
  return loaded;
};

const messageRow = async (messageId) => {
  const { rows } = await pool.query(`SELECT * FROM space_messages WHERE id = $1`, [messageId]);
  if (!rows[0]) fail('not_found', 'No such message');
  return rows[0];
};

/** Tell the other members something changed; best effort. */
const signal = async (spaceId, exceptUserId) => {
  try {
    const { rows } = await pool.query(
      `SELECT user_id FROM space_memberships WHERE space_id = $1 AND user_id <> $2 LIMIT ${LIVE_FANOUT_LIMIT}`,
      [spaceId, exceptUserId],
    );
    const { pushToUser } = await import('../realtime/userEvents.js');
    await Promise.all(rows.map((row) => pushToUser(row.user_id, 'hub:chat', { spaceId })));
  } catch (cause) {
    log.debug({ err: cause }, 'chat live signal not sent; members catch up on their next fetch');
  }
};

const touch = (messageId) => pool.query(`UPDATE space_messages SET updated_at = now() WHERE id = $1`, [messageId]);

// ---------------------------------------------------------------------------
// Views
// ---------------------------------------------------------------------------

const toFile = (row) => ({
  ...Files.toView(row),
  voice: row.voice_duration_ms !== null && row.voice_duration_ms !== undefined,
  durationMs: row.voice_duration_ms ?? null,
});

const extrasFor = async (ids, viewerId) => {
  const result = new Map(ids.map((id) => [id, { files: [], rows: [] }]));
  if (!ids.length) return result;
  const [{ rows: files }, { rows: reactions }] = await Promise.all([
    pool.query(
      `SELECT mf.message_id, mf.position, mf.voice_duration_ms, f.*
         FROM space_message_files mf JOIN files f ON f.id = mf.file_id
        WHERE mf.message_id = ANY($1::uuid[]) AND f.deleted_at IS NULL AND f.status = 'ready'
        ORDER BY mf.message_id, mf.position`,
      [ids],
    ),
    pool.query(
      `SELECT r.message_id, r.emoji, r.user_id, r.created_at, u.display_name
         FROM space_message_reactions r JOIN users u ON u.id = r.user_id
        WHERE r.message_id = ANY($1::uuid[]) ORDER BY r.created_at`,
      [ids],
    ),
  ]);
  for (const row of files) result.get(row.message_id)?.files.push(toFile(row));
  for (const row of reactions) result.get(row.message_id)?.rows.push(row);
  for (const [, entry] of result) entry.reactions = Extras.summariseReactions(entry.rows, viewerId);
  return result;
};

const toViews = async (rows, viewer, membership) => {
  const live = rows.filter((row) => !row.deleted_at).map((row) => row.id);
  const extras = await extrasFor(live, viewer.userId);
  return rows.map((row) => {
    const deleted = Boolean(row.deleted_at);
    const entry = extras.get(row.id);
    const removeAs = deleted ? null : Rules.removalBy({ authorId: row.author_id, viewerId: viewer.userId, membership });
    return {
      messageId: row.id,
      body: deleted ? '' : row.body,
      author: { userId: row.author_id, displayName: row.display_name ?? 'Someone', you: row.author_id === viewer.userId },
      createdAt: iso(row.created_at),
      editedAt: deleted ? null : iso(row.edited_at),
      deletedAt: iso(row.deleted_at),
      deletedBy: Rules.deletedByRole({ deletedBy: row.deleted_at ? row.deleted_by ?? row.author_id : null, authorId: row.author_id }),
      replyToId: row.reply_to_id ?? null,
      files: entry?.files ?? [],
      reactions: entry?.reactions ?? [],
      cursor: row.cursor,
      canRemove: Boolean(removeAs),
      removeAs,
      canEdit: Rules.canEdit({ authorId: row.author_id, viewerId: viewer.userId, deletedAt: row.deleted_at, createdAt: row.created_at, body: row.body, windowMin: env.CHAT_EDIT_WINDOW_MIN ?? 15 }),
    };
  });
};

const SELECT = `m.id, m.author_id, m.body, m.created_at, m.updated_at, m.edited_at, m.deleted_at, m.deleted_by, m.reply_to_id,
                ${CURSOR('m.updated_at')} AS cursor, u.display_name`;

// ---------------------------------------------------------------------------
// List
// ---------------------------------------------------------------------------

/**
 * Without `after`: the newest 80 messages, oldest first. With `after`: every
 * message that changed since (new, edited, deleted, reacted to), in the order
 * they changed. nextCursor is the newest change seen.
 */
export const list = async ({ viewer, spaceId, after = null }) => {
  const { space, membership } = await requireFullView(viewer, spaceId);
  let rows;
  if (after) {
    ({ rows } = await pool.query(
      `SELECT ${SELECT} FROM space_messages m JOIN users u ON u.id = m.author_id
        WHERE m.space_id = $1 AND m.updated_at > $3::timestamptz AND ${notBlocked('m.author_id', '$2')}
        ORDER BY m.updated_at ASC LIMIT 200`,
      [spaceId, viewer.userId, after],
    ));
  } else {
    ({ rows } = await pool.query(
      `SELECT * FROM (
         SELECT ${SELECT} FROM space_messages m JOIN users u ON u.id = m.author_id
          WHERE m.space_id = $1 AND ${notBlocked('m.author_id', '$2')}
          ORDER BY m.created_at DESC LIMIT ${LIMIT}) latest
        ORDER BY created_at ASC`,
      [spaceId, viewer.userId],
    ));
  }
  const { rows: newest } = await pool.query(`SELECT ${CURSOR('max(updated_at)')} AS cursor FROM space_messages WHERE space_id = $1`, [spaceId]);
  const items = await toViews(rows, viewer, membership);
  return {
    items,
    nextCursor: newest[0]?.cursor ?? after,
    calmSeconds: space.chatSlowSeconds ?? 0,
    canModerate: Rules.isModerator(membership),
    postingBlocked: HubRules.postingBlockedBecause(space, membership),
    editWindowMin: env.CHAT_EDIT_WINDOW_MIN ?? 15,
    serverTime: new Date().toISOString(),
  };
};

// ---------------------------------------------------------------------------
// Send
// ---------------------------------------------------------------------------

const checkFiles = async ({ viewer, fileIds = [], voice = null }) => {
  const ids = [...new Set(fileIds)];
  if (!ids.length) return { ids, durationMs: null };
  if (ids.length > Extras.MAX_FILES_PER_MESSAGE) fail('validation_failed', `Up to ${Extras.MAX_FILES_PER_MESSAGE} files per message.`);
  const { rows } = await pool.query(
    `SELECT id, kind FROM files WHERE id = ANY($1::uuid[]) AND owner_id = $2 AND tenant_id = $3 AND status = 'ready' AND deleted_at IS NULL`,
    [ids, viewer.userId, viewer.tenantId],
  );
  if (rows.length !== ids.length) fail('validation_failed', 'One of the files is not ready yet or is no longer available. Upload it again.');
  let durationMs = null;
  if (voice) {
    if (ids.length !== 1 || !['audio', 'video'].includes(rows[0].kind)) fail('validation_failed', 'A voice message is one recording.');
    durationMs = Extras.voiceDuration(voice.durationMs);
  }
  return { ids, durationMs };
};

export const send = async ({ viewer, spaceId, input }) => {
  const { space, membership } = await requireFullView(viewer, spaceId);
  const blocked = HubRules.postingBlockedBecause(space, membership);
  if (blocked) fail('forbidden', blocked);
  const body = String(input.body ?? '').trim();
  const fileIds = input.fileIds ?? [];
  if (!body && !fileIds.length) fail('validation_failed', 'A message needs text or a file.');

  if (space.chatSlowSeconds > 0 && !Rules.isModerator(membership)) {
    const { rows: last } = await pool.query(
      `SELECT max(created_at) AS at FROM space_messages WHERE space_id = $1 AND author_id = $2 AND deleted_at IS NULL`,
      [spaceId, viewer.userId],
    );
    const wait = Part3.calmWait({ slowSeconds: space.chatSlowSeconds, lastPostAt: last[0]?.at });
    if (wait > 0) fail('forbidden', Part3.calmMessage(wait));
  }

  if (input.replyToId) {
    const { rows } = await pool.query(`SELECT 1 FROM space_messages WHERE id = $1 AND space_id = $2`, [input.replyToId, spaceId]);
    if (!rows[0]) fail('validation_failed', 'The message you reply to is not in this space.');
  }
  const checked = await checkFiles({ viewer, fileIds, voice: input.voice ?? null });

  const { rows } = await pool.query(
    `INSERT INTO space_messages (space_id, author_id, body, reply_to_id) VALUES ($1, $2, $3, $4) RETURNING id`,
    [spaceId, viewer.userId, body, input.replyToId ?? null],
  );
  const messageId = rows[0].id;
  if (checked.ids.length) {
    await pool.query(
      `INSERT INTO space_message_files (message_id, file_id, position, voice_duration_ms)
       SELECT $1, f.id, f.position - 1, $3 FROM unnest($2::uuid[]) WITH ORDINALITY AS f(id, position)
       ON CONFLICT DO NOTHING`,
      [messageId, checked.ids, checked.durationMs],
    );
  }
  void signal(spaceId, viewer.userId);
  return view(viewer, membership, messageId);
};

const view = async (viewer, membership, messageId) => {
  const { rows } = await pool.query(`SELECT ${SELECT} FROM space_messages m JOIN users u ON u.id = m.author_id WHERE m.id = $1`, [messageId]);
  return (await toViews(rows, viewer, membership))[0];
};

// ---------------------------------------------------------------------------
// Edit, remove, react
// ---------------------------------------------------------------------------

export const edit = async ({ viewer, messageId, body }) => {
  const row = await messageRow(messageId);
  const { membership } = await requireFullView(viewer, row.space_id);
  const text = String(body ?? '').trim();
  if (!text) fail('validation_failed', 'A message cannot be empty. Delete it instead.');
  if (row.author_id !== viewer.userId) fail('forbidden', 'You can only edit your own messages.');
  if (row.deleted_at) fail('gone', 'This message was deleted.');
  const windowMin = env.CHAT_EDIT_WINDOW_MIN ?? 15;
  if (!Rules.canEdit({ authorId: row.author_id, viewerId: viewer.userId, createdAt: row.created_at, body: row.body, windowMin })) {
    fail('conflict', `Messages can be edited for ${windowMin} minutes after sending.`);
  }
  await pool.query(`UPDATE space_messages SET body = $2, edited_at = now(), updated_at = now() WHERE id = $1`, [messageId, text]);
  void signal(row.space_id, viewer.userId);
  return view(viewer, membership, messageId);
};

export const remove = async ({ viewer, messageId }) => {
  const row = await messageRow(messageId);
  if (row.deleted_at) return { removed: true };
  const { membership } = await requireFullView(viewer, row.space_id);
  const as = Rules.removalBy({ authorId: row.author_id, viewerId: viewer.userId, membership });
  if (!as) fail('forbidden', 'You can only delete your own messages.');
  await pool.query(`UPDATE space_messages SET deleted_at = now(), deleted_by = $2, updated_at = now() WHERE id = $1`, [messageId, viewer.userId]);
  if (as === 'moderator') await logAction(row.space_id, viewer.userId, 'chat.remove');
  void signal(row.space_id, viewer.userId);
  return { removed: true, as };
};

export const react = async ({ viewer, messageId, emoji, action = 'add' }) => {
  if (!Extras.isEmoji(emoji)) fail('validation_failed', 'A reaction is one emoji.');
  const row = await messageRow(messageId);
  if (row.deleted_at) fail('gone', 'This message was deleted.');
  await requireFullView(viewer, row.space_id);
  if (action === 'remove') {
    await pool.query(`DELETE FROM space_message_reactions WHERE message_id = $1 AND user_id = $2 AND emoji = $3`, [messageId, viewer.userId, emoji]);
  } else {
    const { rows } = await pool.query(
      `SELECT count(*)::int AS n FROM space_message_reactions WHERE message_id = $1 AND user_id = $2 AND emoji <> $3`,
      [messageId, viewer.userId, emoji],
    );
    if ((rows[0]?.n ?? 0) >= Extras.MAX_REACTIONS_PER_PERSON) fail('conflict', 'That is enough reactions on one message.');
    await pool.query(`INSERT INTO space_message_reactions (message_id, user_id, emoji) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING`, [messageId, viewer.userId, emoji]);
  }
  await touch(messageId);
  const { rows: current } = await pool.query(
    `SELECT r.emoji, r.user_id, r.created_at, u.display_name FROM space_message_reactions r JOIN users u ON u.id = r.user_id
      WHERE r.message_id = $1 AND r.emoji = $2 ORDER BY r.created_at`,
    [messageId, emoji],
  );
  void signal(row.space_id, viewer.userId);
  const summary = Extras.summariseReactions(current, viewer.userId)[0] ?? { emoji, count: 0, reacted: false, names: [] };
  return { messageId, ...summary };
};

// ---------------------------------------------------------------------------
// Everything shared in the chat
// ---------------------------------------------------------------------------

const GALLERY_WHERE = {
  voice: 'mf.voice_duration_ms IS NOT NULL',
  media: "mf.voice_duration_ms IS NULL AND f.kind IN ('image', 'video')",
  files: "mf.voice_duration_ms IS NULL AND f.kind NOT IN ('image', 'video')",
};

export const media = async ({ viewer, spaceId, kind = 'media', before = null, limit = 60 }) => {
  if (!Extras.MEDIA_KINDS.includes(kind)) fail('validation_failed', 'Unknown kind.');
  await requireFullView(viewer, spaceId);
  const size = Math.min(Math.max(Number(limit) || 60, 1), 200);
  const { rows } = await pool.query(
    `SELECT mf.voice_duration_ms, f.*, m.id AS message_id, m.created_at AS sent_at, m.author_id, u.display_name AS author_name
       FROM space_message_files mf
       JOIN space_messages m ON m.id = mf.message_id
       JOIN files f ON f.id = mf.file_id
       LEFT JOIN users u ON u.id = m.author_id
      WHERE m.space_id = $1 AND m.deleted_at IS NULL AND f.deleted_at IS NULL AND f.status = 'ready'
        AND ($2::timestamptz IS NULL OR m.created_at < $2)
        AND ${notBlocked('m.author_id', '$4')}
        AND ${GALLERY_WHERE[kind]}
      ORDER BY m.created_at DESC, mf.position
      LIMIT $3`,
    [spaceId, before, size + 1, viewer.userId],
  );
  const page = rows.slice(0, size);
  return {
    items: page.map((row) => ({ ...toFile(row), messageId: row.message_id, sentAt: iso(row.sent_at), authorId: row.author_id, authorName: row.author_name ?? 'Someone' })),
    nextBefore: rows.length > size ? iso(page.at(-1).sent_at) : null,
  };
};

export default { list, send, edit, remove, react, media };
