// classroom-app/server/src/messaging/ChatExtras.js
/**
 * Reactions, attachments and voice messages  (Messages)
 *
 *   checkFiles / attachFiles   files from the upload pipeline (files, 029) on a
 *                              message: only your own, ready files; checked
 *                              before the message is written, attached after
 *   applyExtras                adds files and reactions to message views, for a
 *                              whole page in two queries
 *   react                      add or remove one emoji; everyone in the chat
 *                              sees it live (chat:message.reaction)
 *   media                      the files of a conversation for the details
 *                              panel: media · files · voice
 *
 * Who may open an attached file: the participants of its conversation
 * (FileService.canView). A deleted message shows none of its files.
 */

import { ApiError } from '@classroom/contracts';
import { pool } from '../db/pool.js';
import * as Message from './models/Message.js';
import * as Files from '../files/FileService.js';
import * as Rules from './chatExtrasRules.js';

const fail = (code, detail) => {
  throw new ApiError(code, { detail });
};

// ---------------------------------------------------------------------------
// Attachments
// ---------------------------------------------------------------------------

/** Before the message is written: the files exist, are ready and are the author's. */
export const checkFiles = async ({ authorId, tenantId, fileIds = [], voice = null }) => {
  const ids = [...new Set(fileIds)];
  if (ids.length === 0) return { ids, durationMs: null };
  if (ids.length > Rules.MAX_FILES_PER_MESSAGE) fail('validation_failed', `Up to ${Rules.MAX_FILES_PER_MESSAGE} files per message.`);

  const { rows } = await pool.query(
    `SELECT id, kind FROM files
      WHERE id = ANY($1::uuid[]) AND owner_id = $2 AND ($3::uuid IS NULL OR tenant_id = $3)
        AND status = 'ready' AND deleted_at IS NULL`,
    [ids, authorId, tenantId ?? null],
  );
  if (rows.length !== ids.length) fail('validation_failed', 'One of the files is not ready yet or is no longer available. Upload it again.');

  let durationMs = null;
  if (voice) {
    if (ids.length !== 1 || !['audio', 'video'].includes(rows[0].kind)) fail('validation_failed', 'A voice message is one recording.');
    durationMs = Rules.voiceDuration(voice.durationMs);
  }
  return { ids, durationMs };
};

/** After the message is written. Idempotent, like the send it belongs to. */
export const attachFiles = async ({ messageId, checked }) => {
  if (!checked?.ids?.length) return;
  await pool.query(
    `INSERT INTO message_files (message_id, file_id, position, voice_duration_ms)
     SELECT $1, f.id, f.position - 1, $3
       FROM unnest($2::uuid[]) WITH ORDINALITY AS f(id, position)
     ON CONFLICT (message_id, file_id) DO NOTHING`,
    [messageId, checked.ids, checked.durationMs],
  );
};

const toFile = (row) => ({
  ...Files.toView(row),
  voice: row.voice_duration_ms !== null && row.voice_duration_ms !== undefined,
  durationMs: row.voice_duration_ms ?? null,
});

// ---------------------------------------------------------------------------
// Views
// ---------------------------------------------------------------------------

const extrasFor = async ({ messageIds, viewerId }) => {
  const result = new Map(messageIds.map((id) => [id, { files: [], reactionRows: [] }]));
  if (messageIds.length === 0) return result;

  const [{ rows: files }, { rows: reactions }] = await Promise.all([
    pool.query(
      `SELECT mf.message_id, mf.position, mf.voice_duration_ms, f.*
         FROM message_files mf JOIN files f ON f.id = mf.file_id
        WHERE mf.message_id = ANY($1::uuid[]) AND f.deleted_at IS NULL AND f.status = 'ready'
        ORDER BY mf.message_id, mf.position`,
      [messageIds],
    ),
    pool.query(
      `SELECT r.message_id, r.emoji, r.user_id, r.created_at, u.display_name
         FROM message_reactions r JOIN users u ON u.id = r.user_id
        WHERE r.message_id = ANY($1::uuid[])
        ORDER BY r.created_at`,
      [messageIds],
    ),
  ]);
  for (const row of files) result.get(row.message_id)?.files.push(toFile(row));
  for (const row of reactions) result.get(row.message_id)?.reactionRows.push(row);
  for (const [, entry] of result) entry.reactions = Rules.summariseReactions(entry.reactionRows, viewerId);
  return result;
};

/** Message views with their files and reactions, as `viewerId` sees them. */
export const applyExtras = async (messages, viewerId) => {
  const ids = messages.filter((m) => !m.deletedAt).map((m) => m.messageId);
  const extras = await extrasFor({ messageIds: ids, viewerId });
  return messages.map((message) => {
    const entry = extras.get(message.messageId);
    return { ...message, files: entry?.files ?? [], reactions: entry?.reactions ?? [] };
  });
};

// ---------------------------------------------------------------------------
// Reactions
// ---------------------------------------------------------------------------

export const react = async ({ messageId, userId, emoji, action = 'add' }) => {
  if (!Rules.isEmoji(emoji)) fail('validation_failed', 'A reaction is one emoji.');
  const row = await Message.findById(messageId);
  if (!row) fail('not_found', 'Message not found.');
  if (row.deleted_at) fail('gone', 'This message was deleted.');

  const target = Message.toMessage(row, {}).target;
  const { authoriseRead } = await import('./DirectMessageService.js');
  await authoriseRead({ target, userId });

  if (action === 'remove') {
    await pool.query(`DELETE FROM message_reactions WHERE message_id = $1 AND user_id = $2 AND emoji = $3`, [messageId, userId, emoji]);
  } else {
    const { rows } = await pool.query(
      `SELECT count(*)::int AS n FROM message_reactions WHERE message_id = $1 AND user_id = $2 AND emoji <> $3`,
      [messageId, userId, emoji],
    );
    if ((rows[0]?.n ?? 0) >= Rules.MAX_REACTIONS_PER_PERSON) fail('conflict', 'That is enough reactions on one message.');
    await pool.query(
      `INSERT INTO message_reactions (message_id, user_id, emoji) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING`,
      [messageId, userId, emoji],
    );
  }

  const { rows: current } = await pool.query(
    `SELECT r.emoji, r.user_id, r.created_at, u.display_name
       FROM message_reactions r JOIN users u ON u.id = r.user_id
      WHERE r.message_id = $1 AND r.emoji = $2 ORDER BY r.created_at`,
    [messageId, emoji],
  );
  const summary = Rules.summariseReactions(current, userId)[0] ?? { emoji, count: 0, reacted: false, names: [] };
  // Names as everyone else sees them: "You" is only true for the reactor.
  const namesForOthers = current.slice(0, 10).map((r) => r.display_name ?? 'Someone');

  const { broadcastReaction } = await import('./chatGateway.js');
  broadcastReaction({ target, messageId, emoji, userId, action: action === 'remove' ? 'remove' : 'add', count: summary.count, names: namesForOthers });

  return { messageId, ...summary };
};

// ---------------------------------------------------------------------------
// The details panel: everything that was shared in a conversation
// ---------------------------------------------------------------------------

const GALLERY_WHERE = {
  voice: 'mf.voice_duration_ms IS NOT NULL',
  media: "mf.voice_duration_ms IS NULL AND f.kind IN ('image', 'video')",
  files: "mf.voice_duration_ms IS NULL AND f.kind NOT IN ('image', 'video')",
};

export const media = async ({ conversationId, viewerId, kind = 'media', before = null, limit = 60 }) => {
  const size = Math.min(Math.max(Number(limit) || 60, 1), 200);
  if (!Rules.MEDIA_KINDS.includes(kind)) fail('validation_failed', 'Unknown kind.');
  const { assertParticipant } = await import('./ConversationService.js');
  await assertParticipant({ conversationId, userId: viewerId });

  const { rows } = await pool.query(
    `SELECT mf.voice_duration_ms, f.*, m.message_id, m.created_at AS sent_at, m.author_id, u.display_name AS author_name
       FROM message_files mf
       JOIN messages m ON m.message_id = mf.message_id
       JOIN files f ON f.id = mf.file_id
       LEFT JOIN users u ON u.id = m.author_id
       JOIN conversation_participants p ON p.conversation_id = m.conversation_id AND p.user_id = $2
      WHERE m.conversation_id = $1 AND m.deleted_at IS NULL
        AND f.deleted_at IS NULL AND f.status = 'ready'
        AND m.created_at > coalesce(p.cleared_at, '-infinity'::timestamptz)
        AND ($3::timestamptz IS NULL OR m.created_at < $3)
        AND ${GALLERY_WHERE[kind]}
      ORDER BY m.created_at DESC, mf.position
      LIMIT $4`,
    [conversationId, viewerId, before, size + 1],
  );
  const page = rows.slice(0, size);
  return {
    items: page.map((row) => ({
      ...toFile(row),
      messageId: row.message_id,
      sentAt: new Date(row.sent_at).toISOString(),
      authorId: row.author_id,
      authorName: row.author_name ?? 'Someone',
    })),
    nextBefore: rows.length > size ? new Date(page.at(-1).sent_at).toISOString() : null,
  };
};

export default { checkFiles, attachFiles, applyExtras, react, media };
