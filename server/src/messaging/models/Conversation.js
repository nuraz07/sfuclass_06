// classroom-app/server/src/messaging/models/Conversation.js
/**
 * Conversation  (F6)
 *
 * A participant set. A 1:1 chat and a small group chat are the same object with
 * a different size, which is why there is no separate "DirectMessage" table.
 *
 * Column names are the table's (008_messaging.sql, 020): the primary key is
 * `id`. Every query aliases it to `conversation_id`, the name the rest of the
 * messaging domain and the contract use, so the rename happens in exactly one
 * place.
 *
 * One direct conversation per pair of people is guaranteed by the database:
 * `participant_key` holds the two user ids, sorted, and the unique index on
 * (tenant_id, participant_key) settles two clicks at the same moment. The model
 * only has to compute the key the same way every time — directKey() below.
 *
 * Per-person state (muted, muted_until, hidden_at, cleared_at, last_read_at)
 * lives on conversation_participants; the list query reads it for the viewer.
 */

import { pool } from '../../db/pool.js';

/** Sorted pair of user ids. Same order as `ORDER BY uuid` in 020's backfill. */
export const directKey = (userA, userB) =>
  [String(userA).toLowerCase(), String(userB).toLowerCase()].sort().join(':');

const SELECT = `
  c.id AS conversation_id, c.tenant_id, c.kind, c.title, c.created_by,
  c.created_at, c.updated_at, c.last_message_at
`;

const iso = (value) => (value ? new Date(value).toISOString() : null);

/**
 * API shape (Chat.ConversationSchema). `mutedUntil` and `lastMessagePreview`
 * are additive fields the conversation list uses; `lastMessage` stays null
 * because the contract types it as a full Message.
 */
export const toConversation = (
  row,
  { participants = [], unreadCount = 0, muted = false, mutedUntil = null, lastMessagePreview = null } = {},
) => ({
  conversationId: row.conversation_id,
  kind: row.kind,
  title: row.title,
  participants,
  createdBy: row.created_by,
  lastMessage: null,
  lastMessageAt: iso(row.last_message_at),
  lastMessagePreview,
  unreadCount,
  muted,
  mutedUntil: iso(mutedUntil),
  archived: false,
  createdAt: iso(row.created_at),
  updatedAt: iso(row.updated_at ?? row.created_at),
});

export const findById = async (conversationId, client = pool) => {
  const { rows } = await client.query(
    `SELECT ${SELECT} FROM conversations c WHERE c.id = $1`,
    [conversationId],
  );
  return rows[0] ?? null;
};

/** The existing 1:1 between two people in a tenant, or null. */
export const findDirectBetween = async ({ tenantId = null, userA, userB }, client = pool) => {
  const { rows } = await client.query(
    `SELECT ${SELECT}
       FROM conversations c
      WHERE c.kind = 'direct'
        AND c.participant_key = $1
        AND ($2::uuid IS NULL OR c.tenant_id = $2)
      LIMIT 1`,
    [directKey(userA, userB), tenantId],
  );
  return rows[0] ?? null;
};

/**
 * Creates a conversation and its participants in one transaction. `hiddenFor`
 * lists participants who should not see it in their list yet: a direct
 * conversation someone opened but has not written in stays invisible to the
 * other person until the first message arrives (touch() reveals it).
 */
export const create = async ({
  conversationId,
  tenantId,
  kind,
  title = null,
  createdBy,
  participantIds,
  hiddenFor = [],
}) => {
  const participantKey = kind === 'direct' ? directKey(participantIds[0], participantIds[1]) : null;
  const client = await pool.connect();

  try {
    await client.query('BEGIN');

    await client.query(
      `INSERT INTO conversations (id, tenant_id, kind, title, participant_key, created_by, created_at, updated_at)
       VALUES ($1, $2, $3, $4, $5, $6, now(), now())`,
      [conversationId, tenantId, kind, title, participantKey, createdBy],
    );

    // One statement rather than a loop: a group of fifty would otherwise be
    // fifty round trips inside a transaction.
    await client.query(
      `INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at, hidden_at)
       SELECT $1, member, CASE WHEN member = $3 THEN 'owner' ELSE 'member' END, now(),
              CASE WHEN member = ANY($4::uuid[]) THEN now() END
         FROM unnest($2::uuid[]) AS member`,
      [conversationId, participantIds, createdBy, hiddenFor],
    );

    await client.query('COMMIT');
  } catch (cause) {
    await client.query('ROLLBACK');
    throw cause;
  } finally {
    client.release();
  }

  return findById(conversationId);
};

/**
 * A person's visible conversations, most recently active first, with their
 * unread count and a short preview of the last message — both counted from
 * after this person's cleared_at, so a thread they deleted and that came back
 * shows only what is new to them.
 *
 * `conversationId` narrows it to one thread (used to push a single updated
 * row to someone's list).
 */
export const listForUser = async ({ userId, cursor = null, limit = 25, conversationId = null }) => {
  const params = [userId, limit + 1, conversationId];
  const where = ['p.user_id = $1', 'p.left_at IS NULL', '($3::uuid IS NULL OR c.id = $3)'];

  // A thread requested by id is returned even while hidden: the caller is
  // pushing an update the person must see.
  if (!conversationId) where.push('p.hidden_at IS NULL');

  if (cursor) {
    params.push(cursor);
    where.push(`coalesce(c.last_message_at, c.created_at) < $${params.length}::timestamptz`);
  }

  const { rows } = await pool.query(
    `SELECT ${SELECT},
            p.muted, p.muted_until, p.last_read_at, p.cleared_at, p.hidden_at,
            coalesce(c.last_message_at, c.created_at) AS sort_at,
            (SELECT count(*)::int FROM messages m
              WHERE m.conversation_id = c.id
                AND m.deleted_at IS NULL
                AND m.author_id <> $1
                AND m.created_at > greatest(coalesce(p.last_read_at, '-infinity'::timestamptz),
                                            coalesce(p.cleared_at, '-infinity'::timestamptz))
            ) AS unread_count,
            (SELECT jsonb_build_object(
                      'messageId', m.message_id,
                      'authorId', m.author_id,
                      'body', left(m.body, 140),
                      'createdAt', m.created_at)
               FROM messages m
              WHERE m.conversation_id = c.id
                AND m.deleted_at IS NULL
                AND m.created_at > coalesce(p.cleared_at, '-infinity'::timestamptz)
              ORDER BY m.created_at DESC
              LIMIT 1
            ) AS last_message_preview
       FROM conversations c
       JOIN conversation_participants p ON p.conversation_id = c.id
      WHERE ${where.join(' AND ')}
      ORDER BY sort_at DESC, c.id DESC
      LIMIT $2`,
    params,
  );

  const hasMore = rows.length > limit;
  const page = hasMore ? rows.slice(0, limit) : rows;

  return {
    rows: page,
    hasMore,
    nextCursor: hasMore ? iso(page.at(-1)?.sort_at) : null,
  };
};

/**
 * A message was sent. Keeps the list ordered, and brings the thread back for
 * anyone who had deleted it or had not seen it yet — their cleared_at still
 * hides what came before.
 */
export const touch = async (conversationId) => {
  await pool.query(
    `UPDATE conversations SET last_message_at = now(), updated_at = now() WHERE id = $1`,
    [conversationId],
  );
  await pool.query(
    `UPDATE conversation_participants SET hidden_at = NULL
      WHERE conversation_id = $1 AND hidden_at IS NOT NULL AND left_at IS NULL`,
    [conversationId],
  );
};

export default { directKey, findById, findDirectBetween, create, listForUser, touch, toConversation };
