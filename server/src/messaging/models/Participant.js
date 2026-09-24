// classroom-app/server/src/messaging/models/Participant.js
/**
 * Participant  (F6)
 *
 * Membership of a conversation, and the per-person state that goes with it:
 * muted (optionally until a time), where they have read up to, and whether
 * they deleted the thread for themselves.
 *
 * `last_read_at` is a timestamp rather than a message id: an id breaks when
 * that message is deleted, and a timestamp answers the only question anyone
 * asks — "how many arrived after this" — with a range scan.
 *
 * Leaving sets `left_at` rather than deleting the row. "Deleted for me" sets
 * `hidden_at` and `cleared_at` (020): the thread leaves this person's list and
 * their history restarts, while the other side keeps everything.
 *
 * Display names come from `users`; `profiles` has none.
 */

import { pool } from '../../db/pool.js';

/** A mute with an end time that has passed is no longer a mute. */
export const isMutedNow = (row, now = Date.now()) =>
  Boolean(row?.muted) && (!row.muted_until || new Date(row.muted_until).getTime() > now);

export const toParticipant = (row) => ({
  userId: row.user_id,
  profile: {
    userId: row.user_id,
    displayName: row.display_name ?? 'Unknown',
    avatarUrl: row.avatar_url ?? null,
  },
  role: row.role === 'owner' ? 'owner' : 'member',
  joinedAt: row.joined_at ? new Date(row.joined_at).toISOString() : null,
  lastReadAt: row.last_read_at ? new Date(row.last_read_at).toISOString() : null,
  muted: isMutedNow(row),
});

export const listForConversation = async (conversationId) => {
  const { rows } = await pool.query(
    `SELECT cp.user_id, cp.role, cp.joined_at, cp.last_read_at, cp.muted, cp.muted_until,
            cp.hidden_at, cp.cleared_at, u.display_name, NULL::text AS avatar_url
       FROM conversation_participants cp
       JOIN users u ON u.id = cp.user_id
      WHERE cp.conversation_id = $1 AND cp.left_at IS NULL
      ORDER BY cp.joined_at ASC`,
    [conversationId],
  );
  return rows;
};

/** One person's row in one conversation, or null. */
export const state = async ({ conversationId, userId }) => {
  const { rows } = await pool.query(
    `SELECT conversation_id, user_id, role, muted, muted_until, hidden_at, cleared_at,
            last_read_at, left_at
       FROM conversation_participants
      WHERE conversation_id = $1 AND user_id = $2`,
    [conversationId, userId],
  );
  return rows[0] ?? null;
};

export const isParticipant = async ({ conversationId, userId }) => {
  const { rows } = await pool.query(
    `SELECT 1 FROM conversation_participants
      WHERE conversation_id = $1 AND user_id = $2 AND left_at IS NULL LIMIT 1`,
    [conversationId, userId],
  );
  return rows.length > 0;
};

export const add = async ({ conversationId, userId, role = 'member' }) => {
  // Rejoining reuses the row and clears left_at, so the old read position and
  // mute preference survive.
  await pool.query(
    `INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at)
     VALUES ($1, $2, $3, now())
     ON CONFLICT (conversation_id, user_id)
     DO UPDATE SET left_at = NULL, role = EXCLUDED.role`,
    [conversationId, userId, role],
  );
};

export const remove = async ({ conversationId, userId }) => {
  await pool.query(
    `UPDATE conversation_participants SET left_at = now()
      WHERE conversation_id = $1 AND user_id = $2 AND left_at IS NULL`,
    [conversationId, userId],
  );
};

/**
 * Mute, optionally until a time. `until` null with muted true is "until I turn
 * it back on"; unmuting clears both.
 */
export const setMuted = async ({ conversationId, userId, muted, until = null }) => {
  await pool.query(
    `UPDATE conversation_participants
        SET muted = $3,
            muted_until = CASE WHEN $3 THEN $4::timestamptz ELSE NULL END
      WHERE conversation_id = $1 AND user_id = $2`,
    [conversationId, userId, muted, until],
  );
};

/** "Delete for me": out of the list, history restarts now. The other side is untouched. */
export const hide = async ({ conversationId, userId }) => {
  const { rowCount } = await pool.query(
    `UPDATE conversation_participants
        SET hidden_at = now(), cleared_at = now()
      WHERE conversation_id = $1 AND user_id = $2 AND left_at IS NULL`,
    [conversationId, userId],
  );
  return rowCount > 0;
};

/** Back into the list, with history still starting at cleared_at. */
export const reveal = async ({ conversationId, userId }) => {
  await pool.query(
    `UPDATE conversation_participants SET hidden_at = NULL
      WHERE conversation_id = $1 AND user_id = $2 AND hidden_at IS NOT NULL`,
    [conversationId, userId],
  );
};

/**
 * Moves the read marker forward, never back. `greatest` matters: two devices
 * reading the same thread out of order would otherwise make a thread unread
 * again on the device that was ahead.
 */
export const markRead = async ({ conversationId, userId, readAt, messageId = null }) => {
  const { rows } = await pool.query(
    `UPDATE conversation_participants
        SET last_read_at = greatest(coalesce(last_read_at, to_timestamp(0)), $3::timestamptz),
            last_read_message_id = $4
      WHERE conversation_id = $1 AND user_id = $2
      RETURNING last_read_at`,
    [conversationId, userId, readAt, messageId],
  );
  return rows[0]?.last_read_at ?? null;
};

/** Channel membership carries the same preferences under a different key. */
export const markChannelRead = async ({ channelId, userId, readAt, messageId = null }) => {
  const { rows } = await pool.query(
    `INSERT INTO channel_members (channel_id, user_id, last_read_at, last_read_message_id)
     VALUES ($1, $2, $3, $4)
     ON CONFLICT (channel_id, user_id)
     DO UPDATE SET last_read_at = greatest(coalesce(channel_members.last_read_at, to_timestamp(0)), EXCLUDED.last_read_at),
                   last_read_message_id = EXCLUDED.last_read_message_id
     RETURNING last_read_at`,
    [channelId, userId, readAt, messageId],
  );
  return rows[0]?.last_read_at ?? null;
};

/**
 * A person muting a channel for themselves, optionally until a time. Stored on
 * their membership row; moderation mutes (someone else silencing them) live in
 * chat_mutes and are a different thing.
 */
export const setChannelMuted = async ({ channelId, userId, muted, until = null }) => {
  await pool.query(
    `INSERT INTO channel_members (channel_id, user_id, muted, muted_until)
     VALUES ($1, $2, $3, CASE WHEN $3 THEN $4::timestamptz ELSE NULL END)
     ON CONFLICT (channel_id, user_id)
     DO UPDATE SET muted = EXCLUDED.muted, muted_until = EXCLUDED.muted_until`,
    [channelId, userId, muted, until],
  );
};

/** This person's own mute state for some channels: Map<channelId, { muted, mutedUntil }>. */
export const channelMuteStates = async ({ userId, channelIds }) => {
  if (!channelIds.length) return new Map();
  const { rows } = await pool.query(
    `SELECT channel_id, muted, muted_until FROM channel_members
      WHERE user_id = $1 AND channel_id = ANY($2::uuid[])`,
    [userId, channelIds],
  );
  return new Map(
    rows.map((row) => [row.channel_id, { muted: isMutedNow(row), mutedUntil: isMutedNow(row) ? row.muted_until : null }]),
  );
};

/** Who should be notified: everyone present except the author and anyone muted right now. */
export const notifiableIds = async ({ conversationId, excludeUserId }) => {
  const { rows } = await pool.query(
    `SELECT user_id FROM conversation_participants
      WHERE conversation_id = $1 AND left_at IS NULL AND user_id <> $2
        AND NOT (muted AND (muted_until IS NULL OR muted_until > now()))`,
    [conversationId, excludeUserId],
  );
  return rows.map((row) => row.user_id);
};

export default {
  listForConversation, state, isParticipant, add, remove, setMuted, hide, reveal,
  markRead, toParticipant, isMutedNow,
};
