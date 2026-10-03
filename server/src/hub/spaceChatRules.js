// classroom-app/server/src/hub/spaceChatRules.js
/**
 * Who may do what in a space chat  (Community)
 *
 * Pure, tested in server/test/hub/spaceChatRules.check.mjs. The same rules
 * people know from group chats:
 *
 *   delete    your own messages, for everyone ("This message was deleted")
 *   remove    owners and moderators may remove anyone's message ("Removed by a
 *             moderator"); members never delete other people's messages
 *   edit      your own text, within the edit window, never someone else's
 */

export const isModerator = (membership) => membership?.role === 'owner' || membership?.role === 'moderator';

/** 'author' · 'moderator' · null — how this viewer may take a message down. */
export const removalBy = ({ authorId, viewerId, membership }) => {
  if (authorId && authorId === viewerId) return 'author';
  if (isModerator(membership)) return 'moderator';
  return null;
};

export const canEdit = ({ authorId, viewerId, deletedAt = null, createdAt, body = '', windowMin = 0, now = Date.now() }) => {
  if (!authorId || authorId !== viewerId || deletedAt || !String(body).trim()) return false;
  if (!windowMin || windowMin <= 0) return true;
  const created = new Date(createdAt).getTime();
  return !Number.isNaN(created) && now - created <= windowMin * 60_000;
};

/** How a removed message reads, from who removed it. */
export const deletedByRole = ({ deletedBy, authorId }) => (!deletedBy ? null : deletedBy === authorId ? 'author' : 'moderator');

export default { isModerator, removalBy, canEdit, deletedByRole };
