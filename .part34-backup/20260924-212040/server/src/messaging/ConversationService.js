// classroom-app/server/src/messaging/ConversationService.js
/**
 * Conversations  (F6)
 *
 * Opening a private chat resolves here. `openDirect` is idempotent: it returns
 * the existing conversation or creates one, and the database's unique key on
 * the participant pair settles two clicks at the same moment.
 *
 * Before it creates anything it answers a question only the server can answer:
 * may these two people talk? That needs the target's DM setting, both block
 * lists, the sender's role and whether they share a course, a space or the
 * live room they are in right now.
 *
 * The rules (canMessage):
 *
 *   blocked either way      no — outranks everything, teachers included
 *   sender is a teacher     yes — a course must be able to reach its people,
 *   or owner                even someone who switched private messages off
 *   DM setting 'anyone'     yes
 *   DM setting 'nobody'     no  ("receive private messages: off")
 *   DM setting 'shared'     yes when they share a course, a space, or the
 *   (the default)           live room the request came from
 *
 * Per-person state — mute with an end time, "deleted for me" — is written
 * here through Participant, never shared between the two sides.
 */

import { randomUUID } from 'node:crypto';
import { ApiError } from '@classroom/contracts';
import { env } from '../config/env.js';
import { pool } from '../db/pool.js';
import { logger } from '../observability/logger.js';
import * as Conversation from './models/Conversation.js';
import * as Participant from './models/Participant.js';
import * as Block from './models/Block.js';

const log = logger.child({ component: 'conversations' });

const MAX_GROUP = 50;
const TEACHING_ROLES = new Set(['teacher', 'owner']);

/** The contract says 'shared-context', the table says 'shared-only'. Same setting. */
export const toDbPolicy = (policy) =>
  policy === 'shared-context' || policy === 'shared' ? 'shared-only' : policy;

// ---------------------------------------------------------------------------
// Shared context
// ---------------------------------------------------------------------------

/** A course or a space in common. Missing tables in a partial schema count as "no". */
const sharesCourseOrSpace = async (userA, userB) => {
  try {
    const { rows } = await pool.query(
      `SELECT 1 FROM (
         SELECT course_id AS id FROM enrollments WHERE user_id = $1 AND status = 'active'
         INTERSECT
         SELECT course_id AS id FROM enrollments WHERE user_id = $2 AND status = 'active'
         UNION ALL
         SELECT space_id AS id FROM space_memberships WHERE user_id = $1
         INTERSECT
         SELECT space_id AS id FROM space_memberships WHERE user_id = $2
       ) shared LIMIT 1`,
      [userA, userB],
    );
    return rows.length > 0;
  } catch (cause) {
    log.warn({ err: cause }, 'shared-context lookup failed; treating as no shared context');
    return false;
  }
};

/**
 * Both are in the same live room right now. Rooms live in the SFU process;
 * in development that is this process. Where it is not, the answer is "no" and
 * the course/space rule still applies.
 */
const sharesLiveRoom = async (userA, userB, roomId) => {
  if (!roomId) return false;
  try {
    const RoomManager = await import('../classroom/RoomManager.js');
    const room = RoomManager.getRoom(roomId);
    return Boolean(room?.findPeerByUser?.(userA) && room?.findPeerByUser?.(userB));
  } catch {
    return false;
  }
};

// ---------------------------------------------------------------------------
// Permission
// ---------------------------------------------------------------------------

/**
 * The single source of truth for "may A message B". Used here, and by
 * profile.routes to fill `canMessage`, so the button and the send agree.
 *
 * @returns {Promise<{ allowed: boolean, code?: string, reason?: string }>}
 */
export const canMessage = async ({ fromUserId, toUserId, roomId = null }) => {
  if (!fromUserId || !toUserId || fromUserId === toUserId) {
    return { allowed: false, code: 'validation_failed', reason: 'You cannot message yourself.' };
  }

  const { blocked } = await Block.areBlocked(fromUserId, toUserId);
  if (blocked) {
    // Same answer whichever direction the block runs: telling someone they
    // have been blocked is information the blocker did not choose to share.
    return { allowed: false, code: 'blocked_by_user', reason: 'You cannot message this person.' };
  }

  const { rows } = await pool.query(
    `SELECT u.id, u.tenant_id, u.role, p.dm_policy
       FROM users u
       LEFT JOIN profiles p ON p.user_id = u.id
      WHERE u.id = ANY($1::uuid[]) AND u.deleted_at IS NULL`,
    [[fromUserId, toUserId]],
  );
  const sender = rows.find((row) => row.id === fromUserId);
  const target = rows.find((row) => row.id === toUserId);

  if (!sender || !target || sender.tenant_id !== target.tenant_id) {
    return { allowed: false, code: 'not_found', reason: 'This person could not be found.' };
  }

  if (TEACHING_ROLES.has(sender.role)) return { allowed: true, reason: 'teacher' };

  const policy = target.dm_policy ?? toDbPolicy(env.CHAT_DEFAULT_DM_POLICY ?? 'shared-only');

  if (policy === 'anyone') return { allowed: true };
  if (policy === 'nobody') {
    return { allowed: false, code: 'dm_not_allowed', reason: 'This person does not accept private messages.' };
  }

  if ((await sharesLiveRoom(fromUserId, toUserId, roomId)) || (await sharesCourseOrSpace(fromUserId, toUserId))) {
    return { allowed: true };
  }
  return {
    allowed: false,
    code: 'dm_not_allowed',
    reason: 'This person only accepts private messages from people they share a course or lesson with.',
  };
};

// ---------------------------------------------------------------------------
// Shaping
// ---------------------------------------------------------------------------

/** One conversation as `viewerId` sees it: their mute, their unread count, their preview. */
const hydrate = async ({ row, viewerId, created = false }) => {
  const participants = await Participant.listForConversation(row.conversation_id);
  const viewer = participants.find((participant) => participant.user_id === viewerId) ?? row;

  return {
    ...Conversation.toConversation(row, {
      participants: participants.map(Participant.toParticipant),
      muted: Participant.isMutedNow(viewer),
      mutedUntil: Participant.isMutedNow(viewer) ? viewer.muted_until ?? null : null,
      unreadCount: Number(row.unread_count ?? 0),
      lastMessagePreview: row.last_message_preview ?? null,
    }),
    created,
  };
};

/** The viewer's own row for one conversation (unread, preview), hidden or not. */
const rowFor = async ({ conversationId, userId }) => {
  const page = await Conversation.listForUser({ userId, conversationId, limit: 1 });
  return page.rows[0] ?? null;
};

// ---------------------------------------------------------------------------
// Open or create
// ---------------------------------------------------------------------------

/**
 * Idempotent. The person who opens the chat sees it immediately; the other
 * person sees it once the first message arrives (Conversation.create hides it
 * for them, Conversation.touch reveals it).
 *
 * Reopening a chat you deleted brings it back into your list with history
 * still starting where you deleted it.
 */
export const openDirect = async ({ fromUserId, toUserId, tenantId, roomId = null }) => {
  const existing = await Conversation.findDirectBetween({ tenantId, userA: fromUserId, userB: toUserId });
  if (existing) {
    await Participant.reveal({ conversationId: existing.conversation_id, userId: fromUserId });
    const row = await rowFor({ conversationId: existing.conversation_id, userId: fromUserId });
    return hydrate({ row: row ?? existing, viewerId: fromUserId });
  }

  const permission = await canMessage({ fromUserId, toUserId, roomId });
  if (!permission.allowed) {
    throw new ApiError(permission.code ?? 'forbidden', {
      detail: permission.reason ?? 'You cannot message this person.',
    });
  }

  try {
    const created = await Conversation.create({
      conversationId: randomUUID(),
      tenantId,
      kind: 'direct',
      createdBy: fromUserId,
      participantIds: [fromUserId, toUserId],
      hiddenFor: [toUserId],
    });

    log.info({ conversationId: created.conversation_id }, 'direct conversation opened');
    const row = await rowFor({ conversationId: created.conversation_id, userId: fromUserId });
    const conversation = await hydrate({ row: row ?? created, viewerId: fromUserId, created: true });

    // The opener's other tabs and devices add it to their list too.
    const { notifyConversationCreated } = await import('./chatGateway.js');
    notifyConversationCreated({ conversation, userIds: [fromUserId] });

    return conversation;
  } catch (cause) {
    // Unique violation on the participant pair: the other person opened it a
    // moment ago. Theirs is as good as ours.
    if (cause?.code === '23505') {
      const raced = await Conversation.findDirectBetween({ tenantId, userA: fromUserId, userB: toUserId });
      if (raced) {
        await Participant.reveal({ conversationId: raced.conversation_id, userId: fromUserId });
        const row = await rowFor({ conversationId: raced.conversation_id, userId: fromUserId });
        return hydrate({ row: row ?? raced, viewerId: fromUserId });
      }
    }
    throw cause;
  }
};

export const createGroup = async ({ createdBy, participantIds, title = null, tenantId }) => {
  const unique = [...new Set([createdBy, ...participantIds])];

  if (unique.length < 3) {
    throw new ApiError('validation_failed', {
      detail: 'A group needs at least three people. Use a private message for two.',
    });
  }
  if (unique.length > MAX_GROUP) {
    throw new ApiError('validation_failed', { detail: `A group holds at most ${MAX_GROUP} people.` });
  }

  for (const userId of unique) {
    if (userId === createdBy) continue;
    const permission = await canMessage({ fromUserId: createdBy, toUserId: userId });
    if (!permission.allowed) {
      throw new ApiError(permission.code ?? 'forbidden', {
        detail: 'One of the people you selected cannot be added.',
      });
    }
  }

  const created = await Conversation.create({
    conversationId: randomUUID(),
    tenantId,
    kind: 'group',
    title,
    createdBy,
    participantIds: unique,
  });

  const row = await rowFor({ conversationId: created.conversation_id, userId: createdBy });
  return hydrate({ row: row ?? created, viewerId: createdBy, created: true });
};

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

export const assertParticipant = async ({ conversationId, userId }) => {
  if (!(await Participant.isParticipant({ conversationId, userId }))) {
    // 404, not 403: whether a conversation exists is not the caller's business.
    throw new ApiError('not_found', { detail: 'Conversation not found.' });
  }
};

export const getById = async ({ conversationId, viewerId }) => {
  await assertParticipant({ conversationId, userId: viewerId });
  const row = await rowFor({ conversationId, userId: viewerId });
  if (!row) throw new ApiError('not_found', { detail: 'Conversation not found.' });
  return hydrate({ row, viewerId });
};

/** The viewer's visible conversations, newest activity first. */
export const list = async ({ userId, cursor = null, limit = 25 }) => {
  const page = await Conversation.listForUser({ userId, cursor, limit });
  const items = await Promise.all(page.rows.map((row) => hydrate({ row, viewerId: userId })));
  return { items, nextCursor: page.nextCursor, hasMore: page.hasMore };
};

// ---------------------------------------------------------------------------
// Per-person state
// ---------------------------------------------------------------------------

/**
 * Mute for a while or until turned back on. `until` must lie in the future;
 * `muted: false` ends any mute.
 */
export const setMuted = async ({ conversationId, userId, muted, until = null }) => {
  await assertParticipant({ conversationId, userId });

  if (muted && until && new Date(until).getTime() <= Date.now()) {
    throw new ApiError('validation_failed', { detail: 'A mute has to end in the future.' });
  }

  await Participant.setMuted({ conversationId, userId, muted: Boolean(muted), until: muted ? until : null });
  return getById({ conversationId, viewerId: userId });
};

/**
 * "Delete for me". Only this person's view changes: the thread leaves their
 * list and their history restarts now. The other side keeps everything, and a
 * new message brings the thread back for this person without the old ones.
 */
export const deleteForMe = async ({ conversationId, userId }) => {
  await assertParticipant({ conversationId, userId });
  await Participant.hide({ conversationId, userId });

  const { clear } = await import('./UnreadService.js');
  await clear({ userId, target: { kind: 'conversation', conversationId } }).catch(() => undefined);

  return { conversationId, deleted: true };
};

/** Leaving a group removes you; "leaving" a direct chat is deleting it for yourself. */
export const leave = async ({ conversationId, userId }) => {
  const row = await Conversation.findById(conversationId);
  if (!row) return false;

  if (row.kind === 'direct') {
    await deleteForMe({ conversationId, userId });
    return true;
  }

  await Participant.remove({ conversationId, userId });
  return true;
};

// ---------------------------------------------------------------------------
// Live list updates
// ---------------------------------------------------------------------------

/**
 * A message landed in a conversation. Every participant's list gets the
 * updated row — their own unread count, their own preview — on their personal
 * socket room, so a thread appears and a badge moves without a reload.
 */
export const announceActivity = async ({ conversationId }) => {
  const { notifyConversationUpdated } = await import('./chatGateway.js');
  const participants = await Participant.listForConversation(conversationId);

  await Promise.all(
    participants.map(async ({ user_id: userId }) => {
      const row = await rowFor({ conversationId, userId });
      if (!row || row.hidden_at) return;
      notifyConversationUpdated({ userId, conversation: await hydrate({ row, viewerId: userId }) });
    }),
  );
};

export default {
  canMessage, openDirect, createGroup, getById, list, setMuted, deleteForMe, leave,
  assertParticipant, announceActivity, toDbPolicy,
};
