// classroom-app/server/src/messaging/conversationRules.js
/**
 * Small rules for the Messages page  (Messages)
 *
 * Pure, tested in server/test/messaging/conversationRules.check.mjs.
 */

/** How many conversations someone can pin. Messengers keep this small on purpose. */
export const MAX_PINNED = 5;

/** Whether a message can still be edited: own, not deleted, inside the window (0 = always). */
export const canEdit = ({ authorId, viewerId, deletedAt = null, createdAt, windowMin, now = Date.now() }) => {
  if (!authorId || authorId !== viewerId || deletedAt) return false;
  if (!windowMin || windowMin <= 0) return true;
  const created = new Date(createdAt).getTime();
  if (Number.isNaN(created)) return false;
  return now - created <= windowMin * 60_000;
};

const iso = (value) => (value ? new Date(value).toISOString() : null);

/** A space both people belong to, as the details panel shows it. */
export const toSharedSpace = (row) => ({
  spaceId: row.space_id,
  name: row.name ?? 'A space',
  emoji: row.emoji ?? null,
});

/** The details panel's data for one conversation. */
export const toDetails = ({ conversation, sharedSpaces = [], messageCount = 0, editWindowMin = 0 }) => ({
  conversationId: conversation.id,
  startedAt: iso(conversation.created_at),
  pinnedAt: iso(conversation.pinned_at),
  messageCount: Number(messageCount) || 0,
  sharedSpaces: sharedSpaces.map(toSharedSpace),
  editWindowMin: Number(editWindowMin) || 0,
});

export default { MAX_PINNED, canEdit, toSharedSpace, toDetails };
