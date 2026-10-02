// classroom-app/server/src/messaging/ConversationExtras.js
/**
 * The details of a conversation, and pinning  (Messages)
 *
 *   details    for the panel beside a chat: when it started, how many
 *              messages you can see, the spaces you share with the other
 *              person, and how long messages stay editable
 *   setPinned  pin a chat to the top of your own list (MAX_PINNED at most);
 *              only your participant row changes
 *
 * Who may ask: participants only (ConversationService.assertParticipant).
 */

import { ApiError } from '@classroom/contracts';
import { pool } from '../db/pool.js';
import { env } from '../config/env.js';
import * as ConversationService from './ConversationService.js';
import * as Rules from './conversationRules.js';

export const details = async ({ conversationId, viewerId }) => {
  await ConversationService.assertParticipant({ conversationId, userId: viewerId });

  const { rows } = await pool.query(
    `SELECT c.id, c.kind, c.created_at, p.pinned_at, p.cleared_at
       FROM conversations c
       JOIN conversation_participants p ON p.conversation_id = c.id AND p.user_id = $2
      WHERE c.id = $1`,
    [conversationId, viewerId],
  );
  const conversation = rows[0];
  if (!conversation) throw new ApiError('not_found', { detail: 'Conversation not found.' });

  const { rows: counted } = await pool.query(
    `SELECT count(*)::int AS n FROM messages
      WHERE conversation_id = $1 AND deleted_at IS NULL
        AND created_at > coalesce($2::timestamptz, '-infinity'::timestamptz)`,
    [conversationId, conversation.cleared_at],
  );

  // Spaces shared with everyone else in the conversation (for a direct chat:
  // the other person). Read through to_jsonb so a missing optional column
  // (emoji, archived_at) is simply null.
  const { rows: others } = await pool.query(
    `SELECT user_id FROM conversation_participants WHERE conversation_id = $1 AND user_id <> $2 AND left_at IS NULL`,
    [conversationId, viewerId],
  );
  let sharedSpaces = [];
  if (others.length > 0 && others.length <= 20) {
    const { rows: spaces } = await pool.query(
      `SELECT s.id AS space_id, s.name, to_jsonb(s) ->> 'emoji' AS emoji
         FROM spaces s
         JOIN space_memberships mine ON mine.space_id = s.id AND mine.user_id = $1
        WHERE (to_jsonb(s) ->> 'archived_at') IS NULL
          AND (SELECT count(DISTINCT o.user_id) FROM space_memberships o
                WHERE o.space_id = s.id AND o.user_id = ANY($2::uuid[])) = cardinality($2::uuid[])
        ORDER BY lower(s.name)
        LIMIT 20`,
      [viewerId, others.map((row) => row.user_id)],
    );
    sharedSpaces = spaces;
  }

  return Rules.toDetails({
    conversation,
    sharedSpaces,
    messageCount: counted[0]?.n ?? 0,
    editWindowMin: env.CHAT_EDIT_WINDOW_MIN ?? 0,
  });
};

export const setPinned = async ({ conversationId, userId, pinned }) => {
  await ConversationService.assertParticipant({ conversationId, userId });
  if (pinned) {
    const { rows } = await pool.query(
      `SELECT count(*)::int AS n FROM conversation_participants
        WHERE user_id = $1 AND pinned_at IS NOT NULL AND left_at IS NULL AND hidden_at IS NULL AND conversation_id <> $2`,
      [userId, conversationId],
    );
    if ((rows[0]?.n ?? 0) >= Rules.MAX_PINNED) {
      throw new ApiError('conflict', { detail: `You can pin up to ${Rules.MAX_PINNED} chats. Unpin one first.` });
    }
  }
  await pool.query(
    `UPDATE conversation_participants SET pinned_at = CASE WHEN $3 THEN coalesce(pinned_at, now()) ELSE NULL END
      WHERE conversation_id = $1 AND user_id = $2`,
    [conversationId, userId, Boolean(pinned)],
  );
  return ConversationService.getById({ conversationId, viewerId: userId });
};

export default { details, setPinned };
