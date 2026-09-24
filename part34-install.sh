#!/usr/bin/env bash
# part34-install.sh — Parts 3 and 4 of the chat rework (client core + interface),
# including blocking for one lesson.
#
# Run from the project folder (the one containing server/, packages/ and apps/):
#   bash part34-install.sh
#
# Writes 14 files, patches 3 more, keeps a backup of every file it touches in
# .part34-backup/<timestamp>/ and checks all of them at the end.
# Undo: bash part34-install.sh --restore   (back to the state before the first install)
set -euo pipefail

if [ ! -d server/src/messaging ] || [ ! -d packages/core-client/src ] || [ ! -d apps/web/src ]; then
  echo "Run this from the project folder (the one that contains server/, packages/ and apps/)." >&2
  exit 1
fi
if ! grep -q "notifyConversationUpdated" server/src/messaging/chatGateway.js; then
  echo "Part 1 is not installed (chatGateway.js has no notifyConversationUpdated). Install Part 1 first." >&2
  exit 1
fi

TOUCHED=(
  server/src/messaging/SessionBlocks.js
  server/src/messaging/ConversationService.js
  server/src/messaging/models/Participant.js
  server/src/messaging/PublicChatService.js
  server/src/routes/messaging.routes.js
  packages/core-client/src/api/chatApi.ts
  packages/core-client/src/api/profileApi.ts
  packages/core-client/src/state/useConversations.ts
  apps/web/src/components/Chat/ChatRooms.jsx
  apps/web/src/components/Chat/chatRooms.css
  apps/web/src/components/Classroom/ClassroomChatPanel.jsx
  apps/web/src/components/Classroom/ParticipantList.jsx
  apps/web/src/pages/SettingsPage.jsx
  apps/web/src/pages/MessagesPage.jsx
  server/src/messaging/DirectMessageService.js
  server/src/classroom/RoomManager.js
  packages/core-client/src/index.ts
)

if [ "${1:-}" = "--restore" ]; then
  FIRST=$(ls -1d .part34-backup/* 2>/dev/null | head -1 || true)
  [ -n "$FIRST" ] || { echo "No backup found." >&2; exit 1; }
  for f in "${TOUCHED[@]}"; do
    if [ -f "$FIRST/$f" ]; then mkdir -p "$(dirname "$f")"; cp "$FIRST/$f" "$f"; echo "restored $f";
    elif [ -f "$f" ]; then rm "$f"; echo "removed $f (did not exist before)"; fi
  done
  echo "Restored from $FIRST."
  exit 0
fi

BACKUP=".part34-backup/$(date +%Y%m%d-%H%M%S)"
for f in "${TOUCHED[@]}"; do
  if [ -f "$f" ]; then mkdir -p "$BACKUP/$(dirname "$f")"; cp "$f" "$BACKUP/$f"; fi
done
echo "backup: $BACKUP"

mkdir -p server/src/messaging
cat > server/src/messaging/SessionBlocks.js <<'__P34_EOF__'
// classroom-app/server/src/messaging/SessionBlocks.js
/**
 * Blocking for one lesson  (F1, F6)
 *
 * "Block for this session": someone in a live room stops a particular person
 * from writing to them privately — for as long as that lesson runs, not for
 * the whole account. The account-wide block (Settings → Blocked people) is
 * identity/Profile.block and a separate thing.
 *
 * Effect, while it lasts: neither of the two can open a private chat with the
 * other, and messages between them in an existing private chat are refused.
 * The same rule as an account block, deliberately — a one-sided block would
 * let the blocker keep writing to someone who cannot answer.
 *
 * Storage (state Redis, never evicted):
 *   <prefix>:sblock:<blockerId>:<blockedId>   → roomId      TTL 12 h
 *   <prefix>:sblock-room:<roomId>             → set of "<blockerId>:<blockedId>"
 *
 * The room set is how RoomManager.closeRoom ends every block of a lesson when
 * the lesson ends. The TTL is only the backstop for a process that died before
 * it could clean up.
 */

import { ApiError } from '@classroom/contracts';
import { env } from '../config/env.js';
import { stateRedis as redis } from '../db/redis.js';

const TTL_SEC = 12 * 60 * 60;

const pairKey = (blockerId, blockedId) => `${env.REDIS_PREFIX}:sblock:${blockerId}:${blockedId}`;
const roomKey = (roomId) => `${env.REDIS_PREFIX}:sblock-room:${roomId}`;

export const block = async ({ roomId, blockerId, blockedId }) => {
  if (!roomId || !blockerId || !blockedId || blockerId === blockedId) {
    throw new ApiError('validation_failed', { detail: 'You cannot block yourself.' });
  }
  // Separate commands rather than MULTI: the keys may live in different
  // cluster slots, and nothing here needs to be atomic.
  await redis.set(pairKey(blockerId, blockedId), roomId, 'EX', TTL_SEC);
  await redis.sadd(roomKey(roomId), `${blockerId}:${blockedId}`);
  await redis.expire(roomKey(roomId), TTL_SEC);
  return { roomId, blockedUserId: blockedId };
};

export const unblock = async ({ roomId, blockerId, blockedId }) => {
  await redis.del(pairKey(blockerId, blockedId));
  await redis.srem(roomKey(roomId), `${blockerId}:${blockedId}`);
  return { roomId, blockedUserId: blockedId };
};

/** Whom `blockerId` has blocked in this lesson. */
export const listFor = async ({ roomId, blockerId }) => {
  const members = await redis.smembers(roomKey(roomId));
  const prefix = `${blockerId}:`;
  return members.filter((member) => member.startsWith(prefix)).map((member) => member.slice(prefix.length));
};

/** True while a lesson block exists between the two, in either direction. */
export const isBlockedEitherWay = async (userA, userB) => {
  if (!userA || !userB) return false;
  const [one, two] = await Promise.all([redis.get(pairKey(userA, userB)), redis.get(pairKey(userB, userA))]);
  return Boolean(one || two);
};

/** The lesson ended: every block made in it ends too. */
export const clearRoom = async (roomId) => {
  const members = await redis.smembers(roomKey(roomId));
  for (const member of members) {
    const [blockerId, blockedId] = member.split(':');
    // Only if the pair still belongs to this lesson; a newer lesson may have
    // set the same pair again.
    if ((await redis.get(pairKey(blockerId, blockedId))) === roomId) {
      await redis.del(pairKey(blockerId, blockedId));
    }
  }
  await redis.del(roomKey(roomId));
  return members.length;
};

export default { block, unblock, listFor, isBlockedEitherWay, clearRoom };
__P34_EOF__
echo "wrote server/src/messaging/SessionBlocks.js"

mkdir -p server/src/messaging
cat > server/src/messaging/ConversationService.js <<'__P34_EOF__'
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
 *   (account or this lesson)
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

  // A block made in a live lesson counts the same while that lesson runs.
  const { isBlockedEitherWay: blockedInSession } = await import('./SessionBlocks.js');
  if (await blockedInSession(fromUserId, toUserId)) {
    return { allowed: false, code: 'blocked_by_user', reason: 'You cannot message this person right now.' };
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
__P34_EOF__
echo "wrote server/src/messaging/ConversationService.js"

mkdir -p server/src/messaging/models
cat > server/src/messaging/models/Participant.js <<'__P34_EOF__'
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
__P34_EOF__
echo "wrote server/src/messaging/models/Participant.js"

mkdir -p server/src/messaging
cat > server/src/messaging/PublicChatService.js <<'__P34_EOF__'
// classroom-app/server/src/messaging/PublicChatService.js
/**
 * Channels  (F6)
 *
 * The public lobby, space channels, course channels, and the persistence side
 * of in-lesson chat.
 *
 * A channel differs from a conversation in exactly one way that matters: its
 * history is readable by anyone in scope, including from before they joined. A
 * learner who enrols in week six can read weeks one to five. That is why
 * membership rows here carry preferences rather than permission — deleting one
 * does not remove access, and the scope check is what gates a read.
 *
 * A person's own mute of a channel (optionally until a time) is one of those
 * preferences: `muted` in the list is true only while the mute is running.
 *
 * Auto-provisioning lives here too. SpaceService and CourseService call
 * `ensureChannelFor` on publish, and it has to be safe to call repeatedly
 * because publishing happens more than once.
 */

import { randomUUID } from 'node:crypto';
import { ApiError } from '@classroom/contracts';
import { logger } from '../observability/logger.js';
import * as Channel from './models/Channel.js';
import * as Participant from './models/Participant.js';
import * as Message from './models/Message.js';

const log = logger.child({ component: 'channels' });

// ---------------------------------------------------------------------------
// Provisioning
// ---------------------------------------------------------------------------

/** One lobby per tenant, created on setup and never deleted. */
export const ensureLobby = async ({ tenantId, name = 'General' }) => {
  const existing = await Channel.findPublicLobby(tenantId);
  if (existing) return existing;

  log.info({ tenantId }, 'creating the tenant lobby');
  return Channel.ensureForScope({
    channelId: randomUUID(),
    tenantId,
    scope: 'public',
    scopeRefId: null,
    name,
  });
};

/**
 * Idempotent. Called on every course publish and every space creation, so the
 * second publish must find the first channel rather than making another.
 */
export const ensureChannelFor = async ({ tenantId, scope, scopeRefId, name }) => {
  if (scope !== 'space' && scope !== 'course') {
    throw new ApiError('validation_failed', { detail: 'A channel is bound to a space or a course.' });
  }

  const channel = await Channel.ensureForScope({
    channelId: randomUUID(),
    tenantId,
    scope,
    scopeRefId,
    name,
  });

  log.info({ channelId: channel.channel_id, scope, scopeRefId }, 'channel ready');
  return channel;
};

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

export const list = async ({ userId, tenantId, scope, limit }) => {
  if (!scope || scope === 'public') await ensureLobby({ tenantId });

  const rows = await Channel.listForUser({ userId, tenantId, scope, limit });
  const mutes = await Participant.channelMuteStates({
    userId,
    channelIds: rows.map((row) => row.channel_id),
  });

  const items = await Promise.all(
    rows.map(async (row) => {
      const mute = mutes.get(row.channel_id) ?? { muted: false, mutedUntil: null };
      return {
        ...Channel.toChannel(row, {
          unreadCount: Number(row.unread_count ?? 0),
          muted: mute.muted,
          memberCount: await Channel.memberCount(row.channel_id),
        }),
        muted: mute.muted,
        mutedUntil: mute.mutedUntil ? new Date(mute.mutedUntil).toISOString() : null,
      };
    }),
  );

  return { items, nextCursor: null, hasMore: false };
};

export const getById = async ({ channelId, userId }) => {
  const row = await Channel.findById(channelId);
  if (!row) throw new ApiError('not_found', { detail: 'Channel not found.' });

  if (!(await Channel.canRead({ channelId, userId }))) {
    throw new ApiError('not_found', { detail: 'Channel not found.' });
  }

  return Channel.toChannel(row, { memberCount: await Channel.memberCount(channelId) });
};

/**
 * Joining records a preference row. It does not grant access — the scope
 * already did — so this is really "start tracking my unread count here".
 */
export const join = async ({ channelId, userId }) => {
  if (!(await Channel.canRead({ channelId, userId }))) {
    throw new ApiError('forbidden', { detail: 'You cannot join this channel.' });
  }

  await Participant.markChannelRead({
    channelId,
    userId,
    readAt: new Date().toISOString(),
  });

  return getById({ channelId, userId });
};

/** A person's own mute, optionally until a time. */
export const setMuted = async ({ channelId, userId, muted, until = null }) => {
  if (!(await Channel.canRead({ channelId, userId }))) {
    throw new ApiError('not_found', { detail: 'Channel not found.' });
  }
  if (muted && until && new Date(until).getTime() <= Date.now()) {
    throw new ApiError('validation_failed', { detail: 'A mute has to end in the future.' });
  }
  await Participant.setChannelMuted({ channelId, userId, muted: Boolean(muted), until: muted ? until : null });
  return { channelId, muted: Boolean(muted), mutedUntil: muted && until ? new Date(until).toISOString() : null };
};

// ---------------------------------------------------------------------------
// Live lesson chat
// ---------------------------------------------------------------------------

/**
 * Called by classroom/interaction/LiveChat.js, *after* the message has already
 * been broadcast to the room.
 *
 * The lesson panel is not a second chat system: it writes into this same table
 * with `target: { kind: 'room' }`, which is what lets a learner who missed the
 * class read it afterwards in the ordinary thread view.
 *
 * A failure here loses the message from the archive but not from the lesson,
 * which is the right way round — so this throws rather than swallowing, and the
 * caller logs it.
 */
export const persistRoomMessage = async ({ message, roomId, lessonId, authorId, tenantId }) => {
  const row = await Message.insert({
    messageId: message.messageId,
    tenantId,
    target: { kind: 'room', roomId },
    authorId,
    kind: message.kind ?? 'text',
    body: message.body,
    replyToId: message.replyToId ?? null,
    clientMessageId: message.clientMessageId ?? null,
  });

  // Indexed so the lesson transcript is searchable with everything else.
  const { indexMessage } = await import('./ChatSearchService.js');
  await indexMessage(Message.toMessage(row, {}), { lessonId }).catch(() => undefined);

  return row.message_id;
};

/** The lesson's chat, read back after the room has ended. */
export const roomHistory = async ({ roomId, viewerId, cursor, limit = 50 }) => {
  const { history } = await import('./DirectMessageService.js');
  return history({ target: { kind: 'room', roomId }, viewerId, cursor, limit, order: 'asc' });
};

// ---------------------------------------------------------------------------
// Moderation surface
// ---------------------------------------------------------------------------

export const setSlowMode = async ({ channelId, seconds, actorId }) => {
  const row = await Channel.setSlowMode(channelId, seconds);
  log.info({ channelId, seconds, actorId }, 'slow mode changed');

  const { broadcastChannelUpdate } = await import('./chatGateway.js');
  broadcastChannelUpdate({ channel: Channel.toChannel(row, {}) });

  return Channel.toChannel(row, {});
};

export default { ensureLobby, ensureChannelFor, list, getById, join, setMuted, persistRoomMessage };
__P34_EOF__
echo "wrote server/src/messaging/PublicChatService.js"

mkdir -p server/src/routes
cat > server/src/routes/messaging.routes.js <<'__P34_EOF__'
/**
 * messaging.routes — conversations · channels · messages (F6)
 *
 * Mounted under /messaging (app.js), so every path here is relative to it.
 *
 * `POST /conversations/direct` is a single idempotent open-or-create: the same
 * pair of people always resolves to the same conversation. The person who
 * opens it sees it at once; the other person sees it when the first message
 * arrives. `roomId` in the body tells the permission check that both are in
 * the same live lesson, which counts as shared context.
 *
 * Per-person state has its own verbs: PATCH mutes (with an optional end time),
 * DELETE removes the conversation for the caller only. Nobody can delete a
 * conversation for someone else.
 *
 * History is keyset-paginated. Sending is at-least-once from the client's
 * side; `clientId` is the dedupe key.
 */

import { Router } from 'express';
import { z } from 'zod';
import { ApiError } from '@classroom/contracts';

import * as ConversationService from '../messaging/ConversationService.js';
import * as DirectMessageService from '../messaging/DirectMessageService.js';
import * as PublicChatService from '../messaging/PublicChatService.js';
import * as ChatAttachmentService from '../messaging/ChatAttachmentService.js';
import * as ChatSearchService from '../messaging/ChatSearchService.js';
import * as UnreadService from '../messaging/UnreadService.js';
import * as ChatModerationService from '../messaging/ChatModerationService.js';
import * as Participant from '../messaging/models/Participant.js';
import { env } from '../config/env.js';
import { rateLimit } from '../middleware/rateLimit.js';
import { route, validate, requireAuth, tenantOf, paging, q, notFound, forbidden, badRequest } from './_helpers.js';

const router = Router();
router.use(requireAuth);

const idParam = z.object({ id: z.string().uuid() });
const pageQuery = z.object({
  cursor: z.string().optional(),
  limit: z.coerce.number().int().min(1).max(100).optional(),
  direction: z.enum(['forward', 'backward']).optional(),
  order: z.enum(['asc', 'desc']).optional(),
});
const isoDateTime = z.iso.datetime({ offset: true });

/**
 * Domain refusals carry their own codes (dm_not_allowed, blocked_by_user, …).
 * They leave this API as the plain HTTP answers every client understands.
 */
const asHttpError = (error) => {
  if (!ApiError.is(error)) return error;
  const detail = error.detail ?? error.message;
  switch (error.code) {
    case 'dm_not_allowed':
    case 'blocked_by_user':
    case 'forbidden':
      return forbidden(detail);
    case 'not_found':
      return notFound(detail);
    case 'validation_failed':
      return badRequest(detail);
    default:
      return error;
  }
};

const mapped = (fn) => async (req, res) => {
  try {
    return await fn(req, res);
  } catch (error) {
    throw asHttpError(error);
  }
};

/* ------------------------------------------------------------------ *
 * Conversations
 * ------------------------------------------------------------------ */

router.get(
  '/conversations',
  validate({ query: pageQuery }),
  route(
    mapped(async (req) =>
      ConversationService.list({
        userId: req.user.id,
        cursor: q(req).cursor ?? null,
        limit: q(req).limit ?? 25,
      }),
    ),
  ),
);

/**
 * Open or create. 201 when it was created, 200 when it already existed.
 * Refused with 403 when the target's DM setting or a block forbids it.
 */
router.post(
  '/conversations/direct',
  rateLimit({ key: 'chat:open-dm', points: 60, durationSec: 300, by: ['user'] }),
  validate({ body: z.object({ userId: z.string().uuid(), roomId: z.string().uuid().nullish() }) }),
  route(
    mapped(async (req, res) => {
      if (req.body.userId === req.user.id) throw badRequest('You cannot message yourself');

      const conversation = await ConversationService.openDirect({
        fromUserId: req.user.id,
        toUserId: req.body.userId,
        tenantId: tenantOf(req),
        roomId: req.body.roomId ?? null,
      });

      res.status(conversation.created ? 201 : 200);
      return conversation;
    }),
  ),
);

/** A small group chat is the same object with more participants. */
router.post(
  '/conversations/group',
  validate({
    body: z.object({
      participantIds: z.array(z.string().uuid()).min(2).max(49).optional(),
      userIds: z.array(z.string().uuid()).min(2).max(49).optional(),
      title: z.string().max(120).optional(),
    }),
  }),
  route(
    mapped(async (req, res) => {
      const participantIds = req.body.participantIds ?? req.body.userIds;
      if (!participantIds) throw badRequest('participantIds is required');
      res.status(201);
      return ConversationService.createGroup({
        tenantId: tenantOf(req),
        createdBy: req.user.id,
        participantIds,
        title: req.body.title ?? null,
      });
    }),
  ),
);

router.get(
  '/conversations/:id',
  validate({ params: idParam }),
  route(mapped(async (req) => ConversationService.getById({ conversationId: req.params.id, viewerId: req.user.id }))),
);

/**
 * The caller's own settings for a conversation.
 *   { muted: true }                         muted until turned back on
 *   { muted: true, mutedUntil: <ISO time> } muted until then
 *   { muted: false }                        unmuted
 * `until` is accepted as a synonym (Chat.MuteTargetSchema).
 */
router.patch(
  '/conversations/:id',
  validate({
    params: idParam,
    body: z.object({
      muted: z.boolean().optional(),
      mutedUntil: isoDateTime.nullish(),
      until: isoDateTime.nullish(),
    }),
  }),
  route(
    mapped(async (req) => {
      const until = req.body.mutedUntil ?? req.body.until ?? null;
      // A body without mute fields (an older client sending `archived`, say)
      // changes nothing; it must never read as "unmute".
      if (req.body.muted === undefined && !until) {
        return ConversationService.getById({ conversationId: req.params.id, viewerId: req.user.id });
      }
      const muted = req.body.muted ?? Boolean(until);
      return ConversationService.setMuted({
        conversationId: req.params.id,
        userId: req.user.id,
        muted,
        until,
      });
    }),
  ),
);

/** Delete for me. The other participants keep the conversation and its history. */
router.delete(
  '/conversations/:id',
  validate({ params: idParam }),
  route(mapped(async (req) => ConversationService.deleteForMe({ conversationId: req.params.id, userId: req.user.id }))),
);

/** Leave a group; for a direct chat this is the same as delete for me. */
router.delete(
  '/conversations/:id/participants/me',
  validate({ params: idParam }),
  route(
    mapped(async (req) => {
      await ConversationService.leave({ conversationId: req.params.id, userId: req.user.id });
      return null;
    }),
  ),
);

/* ------------------------------------------------------------------ *
 * Channels (public, space-bound, course-bound)
 * ------------------------------------------------------------------ */

router.get(
  '/channels',
  validate({ query: z.object({ scope: z.enum(['public', 'space', 'course']).optional() }) }),
  route(async (req) =>
    PublicChatService.list({ tenantId: tenantOf(req), userId: req.user.id, scope: q(req).scope }),
  ),
);

/** The caller's own mute of a channel, e.g. the lesson's default chatroom. */
router.patch(
  '/channels/:id/members/me',
  validate({
    params: idParam,
    body: z.object({ muted: z.boolean().optional(), mutedUntil: isoDateTime.nullish(), until: isoDateTime.nullish() }),
  }),
  route(
    mapped(async (req) => {
      const until = req.body.mutedUntil ?? req.body.until ?? null;
      return PublicChatService.setMuted({
        channelId: req.params.id,
        userId: req.user.id,
        muted: req.body.muted ?? Boolean(until),
        until,
      });
    }),
  ),
);

/* ------------------------------------------------------------------ *
 * Blocking for one lesson
 * ------------------------------------------------------------------ */

/**
 * Only someone who is in the running lesson can block within it. Rooms live
 * in the SFU process; in development that is this process.
 */
const assertInLiveRoom = async (roomId, userId) => {
  const RoomManager = await import('../classroom/RoomManager.js');
  const room = RoomManager.getRoom(roomId);
  if (!room?.findPeerByUser?.(userId)) throw notFound('This lesson is not running, or you are not in it');
};

router.get(
  '/session-blocks',
  validate({ query: z.object({ roomId: z.string().uuid() }) }),
  route(async (req) => {
    const { listFor } = await import('../messaging/SessionBlocks.js');
    return { roomId: q(req).roomId, blockedUserIds: await listFor({ roomId: q(req).roomId, blockerId: req.user.id }) };
  }),
);

router.post(
  '/session-blocks',
  validate({ body: z.object({ roomId: z.string().uuid(), userId: z.string().uuid() }) }),
  route(
    mapped(async (req, res) => {
      if (req.body.userId === req.user.id) throw badRequest('You cannot block yourself');
      await assertInLiveRoom(req.body.roomId, req.user.id);
      const { block } = await import('../messaging/SessionBlocks.js');
      res.status(201);
      return block({ roomId: req.body.roomId, blockerId: req.user.id, blockedId: req.body.userId });
    }),
  ),
);

router.delete(
  '/session-blocks/:roomId/:userId',
  validate({ params: z.object({ roomId: z.string().uuid(), userId: z.string().uuid() }) }),
  route(async (req) => {
    const { unblock } = await import('../messaging/SessionBlocks.js');
    return unblock({ roomId: req.params.roomId, blockerId: req.user.id, blockedId: req.params.userId });
  }),
);

/**
 * Full history is readable by any member, including the part that happened
 * before they arrived — a new joiner should see the room they walked into.
 */
router.get(
  '/channels/:id/messages',
  validate({ params: idParam, query: pageQuery }),
  route(async (req) =>
    DirectMessageService.history({
      target: { kind: 'channel', channelId: req.params.id },
      viewerId: req.user.id,
      ...paging(req, { defaultLimit: 50 }),
    }),
  ),
);

router.post(
  '/channels/:id/messages',
  rateLimit({ key: 'chat:send', points: env.CHAT_RATE_PER_MIN, durationSec: 60, by: ['user'] }),
  validate({
    params: idParam,
    body: z.object({
      body: z.string().max(env.CHAT_MAX_MESSAGE_LEN),
      attachmentIds: z.array(z.string().uuid()).max(10).default([]),
      replyToId: z.string().uuid().nullish(),
      clientId: z.string().max(128),
    }),
  }),
  route(
    mapped(async (req, res) => {
      if (!req.body.body.trim() && req.body.attachmentIds.length === 0) {
        throw badRequest('A message needs text or an attachment');
      }
      const message = await DirectMessageService.send({
        target: { kind: 'channel', channelId: req.params.id },
        authorId: req.user.id,
        tenantId: tenantOf(req),
        body: req.body.body,
        attachmentIds: req.body.attachmentIds,
        replyToId: req.body.replyToId ?? null,
        clientMessageId: req.body.clientId,
      });

      res.status(201);
      return { message, clientId: req.body.clientId, deduped: false };
    }),
  ),
);

router.put(
  '/channels/:id/read',
  validate({ params: idParam, body: z.object({ messageId: z.string().uuid() }) }),
  route(async (req) => {
    const target = { kind: 'channel', channelId: req.params.id };
    await DirectMessageService.authoriseRead({ target, userId: req.user.id });
    await Participant.markChannelRead({
      channelId: req.params.id,
      userId: req.user.id,
      readAt: new Date().toISOString(),
      messageId: req.body.messageId,
    });
    return null;
  }),
);

/* ------------------------------------------------------------------ *
 * Messages
 * ------------------------------------------------------------------ */

router.get(
  '/conversations/:id/messages',
  validate({ params: idParam, query: pageQuery.extend({ around: z.string().uuid().optional() }) }),
  route(
    mapped(async (req) =>
      DirectMessageService.history({
        target: { kind: 'conversation', conversationId: req.params.id },
        viewerId: req.user.id,
        around: q(req).around ?? null,
        ...paging(req, { defaultLimit: 50 }),
      }),
    ),
  ),
);

/** Read up to a message; clears this conversation's unread badge for the caller. */
router.put(
  '/conversations/:id/read',
  validate({ params: idParam, body: z.object({ messageId: z.string().uuid() }) }),
  route(
    mapped(async (req) => {
      const target = { kind: 'conversation', conversationId: req.params.id };
      await DirectMessageService.authoriseRead({ target, userId: req.user.id });
      await Participant.markRead({
        conversationId: req.params.id,
        userId: req.user.id,
        readAt: new Date().toISOString(),
        messageId: req.body.messageId,
      });
      await UnreadService.clear({ userId: req.user.id, target }).catch(() => undefined);
      return null;
    }),
  ),
);

router.post(
  '/conversations/:id/messages',
  rateLimit({ key: 'chat:send', points: env.CHAT_RATE_PER_MIN, durationSec: 60, by: ['user'] }),
  validate({
    params: idParam,
    body: z.object({
      body: z.string().max(env.CHAT_MAX_MESSAGE_LEN),
      attachmentIds: z.array(z.string().uuid()).max(10).default([]),
      replyToId: z.string().uuid().nullish(),
      clientId: z.string().max(128),
    }),
  }),
  route(
    mapped(async (req, res) => {
      if (!req.body.body.trim() && req.body.attachmentIds.length === 0) {
        throw badRequest('A message needs text or an attachment');
      }

      const message = await DirectMessageService.send({
        target: { kind: 'conversation', conversationId: req.params.id },
        authorId: req.user.id,
        tenantId: tenantOf(req),
        body: req.body.body,
        attachmentIds: req.body.attachmentIds,
        replyToId: req.body.replyToId ?? null,
        clientMessageId: req.body.clientId,
      });

      res.status(201);
      return { message, clientId: req.body.clientId, deduped: false };
    }),
  ),
);

router.patch(
  '/messages/:id',
  validate({ params: idParam, body: z.object({ body: z.string().min(1).max(env.CHAT_MAX_MESSAGE_LEN) }) }),
  route(mapped(async (req) => DirectMessageService.edit({ messageId: req.params.id, userId: req.user.id, body: req.body.body }))),
);

router.delete(
  '/messages/:id',
  validate({ params: idParam }),
  route(
    mapped(async (req) => {
      await DirectMessageService.remove({
        messageId: req.params.id,
        userId: req.user.id,
        asModerator: ['owner', 'teacher'].includes(req.user.role),
      });
      return null;
    }),
  ),
);

/* ------------------------------------------------------------------ *
 * Unread counters
 * ------------------------------------------------------------------ */

/** One call for the whole badge state. */
router.get(
  '/unread',
  route(async (req) => UnreadService.summary({ userId: req.user.id })),
);

/* ------------------------------------------------------------------ *
 * Attachments
 * ------------------------------------------------------------------ */

/**
 * Chat attachments have no storage path of their own — this delegates to the
 * media domain, so quota, virus scanning, signed delivery and lifecycle rules
 * apply for free.
 */
router.post(
  '/attachments',
  validate({
    body: z.object({
      conversationId: z.string().uuid().nullish(),
      channelId: z.string().uuid().nullish(),
      filename: z.string().min(1).max(255),
      contentType: z.string().min(1).max(255),
      sizeBytes: z.number().int().min(1),
    }),
  }),
  route(async (req, res) => {
    if (!req.body.conversationId && !req.body.channelId) {
      throw badRequest('An attachment needs a conversationId or a channelId');
    }
    res.status(201);
    return ChatAttachmentService.presign({ userId: req.user.id, tenantId: tenantOf(req), ...req.body });
  }),
);

/* ------------------------------------------------------------------ *
 * Search
 * ------------------------------------------------------------------ */

router.get(
  '/search',
  rateLimit({ key: 'chat:search', points: 60, durationSec: 60, by: ['user'] }),
  validate({
    query: z.object({
      q: z.string().min(2).max(200),
      conversationId: z.string().uuid().optional(),
      channelId: z.string().uuid().optional(),
      from: z.string().uuid().optional(),
      cursor: z.string().optional(),
      limit: z.coerce.number().int().min(1).max(50).optional(),
    }),
  }),
  route(async (req) =>
    ChatSearchService.search({
      userId: req.user.id,
      tenantId: tenantOf(req),
      query: q(req).q,
      conversationId: q(req).conversationId,
      channelId: q(req).channelId,
      senderId: q(req).from,
      ...paging(req, { defaultLimit: 25, maxLimit: 50 }),
    }),
  ),
);

/* ------------------------------------------------------------------ *
 * Moderation
 * ------------------------------------------------------------------ */

router.post(
  '/reports',
  validate({
    body: z.object({
      messageId: z.string().uuid(),
      reason: z.enum(['spam', 'abuse', 'harassment', 'nsfw', 'other']),
      note: z.string().max(2000).optional(),
    }),
  }),
  route(async (req, res) => {
    res.status(202);
    return ChatModerationService.report({
      messageId: req.body.messageId,
      reporterId: req.user.id,
      reason: req.body.reason,
      detail: req.body.note ?? null,
    });
  }),
);

router.post(
  '/channels/:id/slow-mode',
  validate({ params: idParam, body: z.object({ seconds: z.number().int().min(0).max(3600) }) }),
  route(async (req) => {
    if (!['owner', 'teacher'].includes(req.user.role)) throw forbidden('Moderators only');
    return PublicChatService.setSlowMode({
      channelId: req.params.id,
      seconds: req.body.seconds,
      actorId: req.user.id,
    });
  }),
);

router.post(
  '/channels/:id/mutes',
  validate({
    params: idParam,
    body: z.object({ userId: z.string().uuid(), minutes: z.number().int().min(1).max(43_200) }),
  }),
  route(async (req) => {
    if (!['owner', 'teacher'].includes(req.user.role)) throw forbidden('Moderators only');
    return ChatModerationService.mute({
      channelId: req.params.id,
      userId: req.body.userId,
      until: new Date(Date.now() + req.body.minutes * 60_000).toISOString(),
      actorId: req.user.id,
    });
  }),
);

export default router;
__P34_EOF__
echo "wrote server/src/routes/messaging.routes.js"

mkdir -p packages/core-client/src/api
cat > packages/core-client/src/api/chatApi.ts <<'__P34_EOF__'
/**
 * Chat API  (F6)
 *
 * The HTTP half of messaging. Every mutation here has a socket twin in
 * chat.events.ts; the socket is the fast path when a connection is already
 * open, this is the path that still works on a train.
 *
 * Paths are the server's (server/src/routes/messaging.routes.js, mounted under
 * /messaging). Conversation and channel rows are validated with the view
 * schemas below rather than the strict contract schemas: they carry per-viewer
 * fields the list needs (mutedUntil, lastMessagePreview) and accept the
 * server's role and id spellings as they are.
 *
 *   openDirect()          idempotent open-or-create; `roomId` tells the server
 *                         both people are in the same lesson
 *   muteConversation()    { muted, until } — until null means "until I turn it on"
 *   deleteConversation()  for the caller only; the other side keeps everything
 *   blockInSession()      block someone for the running lesson only
 */

import { Chat } from '@classroom/contracts';
import { z } from 'zod';
import type { HttpClient } from '../http/httpClient.js';

type ChatTarget = z.infer<typeof Chat.ChatTargetSchema>;

/** Targets are a union; routes are flat. This is the one mapping between them. */
const targetPath = (target: ChatTarget): string => {
  switch (target.kind) {
    case 'conversation':
      return `/messaging/conversations/${encodeURIComponent(target.conversationId)}`;
    case 'channel':
      return `/messaging/channels/${encodeURIComponent(target.channelId)}`;
    case 'room':
      return `/messaging/rooms/${encodeURIComponent(target.roomId)}`;
  }
};

// ---------------------------------------------------------------------------
// View schemas
// ---------------------------------------------------------------------------

const MessagePreviewSchema = z
  .object({
    messageId: z.string(),
    authorId: z.string(),
    body: z.string(),
    createdAt: z.string(),
  })
  .nullable()
  .default(null);

const ParticipantViewSchema = z
  .object({
    userId: z.string(),
    profile: z
      .object({
        userId: z.string(),
        displayName: z.string().default('Unknown'),
        avatarUrl: z.string().nullable().default(null),
      })
      .passthrough(),
    role: z.string().default('member'),
    lastReadAt: z.string().nullable().default(null),
    muted: z.boolean().default(false),
  })
  .passthrough();

export const ConversationViewSchema = z
  .object({
    conversationId: z.string(),
    kind: z.enum(['direct', 'group']),
    title: z.string().nullable().default(null),
    participants: z.array(ParticipantViewSchema),
    lastMessageAt: z.string().nullable().default(null),
    lastMessagePreview: MessagePreviewSchema,
    unreadCount: z.number().int().nonnegative().default(0),
    muted: z.boolean().default(false),
    mutedUntil: z.string().nullable().default(null),
    created: z.boolean().optional(),
    createdAt: z.string(),
    updatedAt: z.string().nullable().default(null),
  })
  .passthrough();
export type ConversationView = z.infer<typeof ConversationViewSchema>;

const ConversationPageSchema = z.object({
  items: z.array(ConversationViewSchema),
  nextCursor: z.string().nullable().default(null),
  hasMore: z.boolean().default(false),
});

export const ChannelViewSchema = z
  .object({
    channelId: z.string(),
    scope: z.string(),
    name: z.string(),
    unreadCount: z.number().int().nonnegative().default(0),
    muted: z.boolean().default(false),
    mutedUntil: z.string().nullable().default(null),
    lastMessageAt: z.string().nullable().default(null),
  })
  .passthrough();
export type ChannelView = z.infer<typeof ChannelViewSchema>;

const ChannelPageSchema = z.object({
  items: z.array(ChannelViewSchema),
  nextCursor: z.string().nullable().default(null),
  hasMore: z.boolean().default(false),
});

const ChannelMuteSchema = z.object({
  channelId: z.string(),
  muted: z.boolean(),
  mutedUntil: z.string().nullable().default(null),
});

const SessionBlocksSchema = z.object({
  roomId: z.string(),
  blockedUserIds: z.array(z.string()),
});

export interface MuteInput {
  muted: boolean;
  /** ISO time the mute ends; null or absent means "until I turn it back on". */
  until?: string | null;
}

// ---------------------------------------------------------------------------
// Interface
// ---------------------------------------------------------------------------

export interface ChatApi {
  listConversations(
    query?: { cursor?: string; limit?: number },
    signal?: AbortSignal,
  ): Promise<z.infer<typeof ConversationPageSchema>>;
  getConversation(conversationId: string, signal?: AbortSignal): Promise<ConversationView>;
  /** Idempotent: returns the existing conversation or creates one. */
  openDirect(userId: string, options?: { roomId?: string | null }): Promise<ConversationView>;
  createGroup(input: { participantIds: string[]; title?: string }): Promise<ConversationView>;
  muteConversation(conversationId: string, input: MuteInput | boolean): Promise<ConversationView>;
  /** Removes the conversation for the caller only. */
  deleteConversation(conversationId: string): Promise<void>;
  /** Kept for older callers: archiving is now "delete for me". */
  archiveConversation(conversationId: string, archived: boolean): Promise<void>;
  leaveConversation(conversationId: string): Promise<void>;

  listChannels(
    query?: { cursor?: string; limit?: number; scope?: 'public' | 'space' | 'course' },
    signal?: AbortSignal,
  ): Promise<z.infer<typeof ChannelPageSchema>>;
  muteChannel(channelId: string, input: MuteInput | boolean): Promise<z.infer<typeof ChannelMuteSchema>>;

  listSessionBlocks(roomId: string, signal?: AbortSignal): Promise<z.infer<typeof SessionBlocksSchema>>;
  blockInSession(roomId: string, userId: string): Promise<void>;
  unblockInSession(roomId: string, userId: string): Promise<void>;

  listMessages(
    target: ChatTarget,
    query?: z.infer<typeof Chat.ListMessagesQuerySchema>,
    signal?: AbortSignal,
  ): Promise<z.infer<typeof Chat.MessageListSchema>>;
  send(input: z.infer<typeof Chat.SendMessageSchema>): Promise<z.infer<typeof Chat.MessageSchema>>;
  edit(messageId: string, body: string): Promise<z.infer<typeof Chat.MessageSchema>>;
  remove(messageId: string): Promise<void>;
  react(messageId: string, input: z.infer<typeof Chat.ReactToMessageSchema>): Promise<void>;

  markRead(target: ChatTarget, messageId: string): Promise<void>;
  getUnread(signal?: AbortSignal): Promise<z.infer<typeof Chat.UnreadSummarySchema>>;

  requestAttachment(
    input: z.infer<typeof Chat.RequestChatAttachmentSchema>,
  ): Promise<{ assetId: string }>;
  search(
    query: z.infer<typeof Chat.ChatSearchQuerySchema>,
    signal?: AbortSignal,
  ): Promise<z.infer<typeof Chat.ChatSearchResultSchema>>;
  reportMessage(input: z.infer<typeof Chat.ReportMessageSchema>): Promise<void>;
  setSlowMode(channelId: string, seconds: number): Promise<unknown>;
}

const toMuteBody = (input: MuteInput | boolean) =>
  typeof input === 'boolean'
    ? { muted: input }
    : { muted: input.muted, mutedUntil: input.muted ? (input.until ?? null) : null };

const AttachmentTicketSchema = Chat.MessageAttachmentSchema.pick({ assetId: true });

export const createChatApi = (http: HttpClient): ChatApi => ({
  listConversations: (query = {}, signal) =>
    http.get('/messaging/conversations', {
      schema: ConversationPageSchema,
      query: { cursor: query.cursor, limit: query.limit },
      signal,
    }),

  getConversation: (conversationId, signal) =>
    http.get(`/messaging/conversations/${encodeURIComponent(conversationId)}`, {
      schema: ConversationViewSchema,
      signal,
    }),

  /**
   * POST because the server may create. Safe to call twice: the same pair of
   * people always resolves to the same conversation.
   */
  openDirect: (userId, options = {}) =>
    http.post(
      '/messaging/conversations/direct',
      { userId, ...(options.roomId ? { roomId: options.roomId } : {}) },
      { schema: ConversationViewSchema },
    ),

  createGroup: (input) =>
    http.post('/messaging/conversations/group', input, { schema: ConversationViewSchema }),

  muteConversation: (conversationId, input) =>
    http.patch(`/messaging/conversations/${encodeURIComponent(conversationId)}`, toMuteBody(input), {
      schema: ConversationViewSchema,
    }),

  deleteConversation: async (conversationId) => {
    await http.delete(`/messaging/conversations/${encodeURIComponent(conversationId)}`);
  },

  archiveConversation: async (conversationId, archived) => {
    if (archived) await http.delete(`/messaging/conversations/${encodeURIComponent(conversationId)}`);
  },

  leaveConversation: async (conversationId) => {
    await http.delete(
      `/messaging/conversations/${encodeURIComponent(conversationId)}/participants/me`,
    );
  },

  listChannels: (query = {}, signal) =>
    http.get('/messaging/channels', {
      schema: ChannelPageSchema,
      query: { cursor: query.cursor, limit: query.limit, scope: query.scope },
      signal,
    }),

  muteChannel: (channelId, input) =>
    http.patch(`/messaging/channels/${encodeURIComponent(channelId)}/members/me`, toMuteBody(input), {
      schema: ChannelMuteSchema,
    }),

  listSessionBlocks: (roomId, signal) =>
    http.get('/messaging/session-blocks', { schema: SessionBlocksSchema, query: { roomId }, signal }),

  blockInSession: async (roomId, userId) => {
    await http.post('/messaging/session-blocks', { roomId, userId });
  },

  unblockInSession: async (roomId, userId) => {
    await http.delete(
      `/messaging/session-blocks/${encodeURIComponent(roomId)}/${encodeURIComponent(userId)}`,
    );
  },

  /**
   * Keyset paginated. `around` loads the page containing a specific message,
   * which is what a search hit or a reply link needs.
   */
  listMessages: (target, query = { limit: 25, order: 'desc' }, signal) =>
    http.get(`${targetPath(target)}/messages`, {
      schema: Chat.MessageListSchema,
      query: {
        cursor: query.cursor,
        limit: query.limit,
        order: query.order,
        around: query.around,
      },
      signal,
    }),

  /**
   * The idempotency key is the clientMessageId: one id identifies the message
   * in the optimistic bubble, in the retry and in the socket echo.
   */
  send: async (input) => {
    const result = (await http.post(
      `${targetPath(input.target)}/messages`,
      {
        body: input.body,
        attachmentIds: input.attachmentIds,
        replyToId: input.replyToId,
        clientId: input.clientMessageId,
      },
      { idempotencyKey: input.clientMessageId },
    )) as { message: z.infer<typeof Chat.MessageSchema> };

    return result.message;
  },

  edit: (messageId, body) =>
    http.patch(`/messaging/messages/${encodeURIComponent(messageId)}`, { body }, {
      schema: Chat.MessageSchema,
    }),

  remove: async (messageId) => {
    await http.delete(`/messaging/messages/${encodeURIComponent(messageId)}`);
  },

  react: async (messageId, input) => {
    await http.post(`/messaging/messages/${encodeURIComponent(messageId)}/reactions`, input, {
      retry: { attempts: 1 },
    });
  },

  markRead: async (target, messageId) => {
    await http.put(`${targetPath(target)}/read`, { messageId }, { retry: { attempts: 1 } });
  },

  getUnread: (signal) =>
    http.get('/messaging/unread', { schema: Chat.UnreadSummarySchema, signal }),

  requestAttachment: (input) =>
    http.post('/messaging/attachments', input, { schema: AttachmentTicketSchema }),

  search: (query, signal) =>
    http.get('/messaging/search', {
      schema: Chat.ChatSearchResultSchema,
      query: {
        q: query.q,
        cursor: query.cursor,
        limit: query.limit,
        from: query.fromUserId,
      },
      signal,
    }),

  reportMessage: async (input) => {
    await http.post('/messaging/reports', {
      messageId: input.messageId,
      reason: input.reason,
      note: input.detail,
    });
  },

  setSlowMode: (channelId, seconds) =>
    http.post(`/messaging/channels/${encodeURIComponent(channelId)}/slow-mode`, { seconds }),
});
__P34_EOF__
echo "wrote packages/core-client/src/api/chatApi.ts"

mkdir -p packages/core-client/src/api
cat > packages/core-client/src/api/profileApi.ts <<'__P34_EOF__'
/**
 * Profile API  (F6)
 *
 * Paths are the server's (server/src/routes/profile.routes.js, mounted under
 * /profiles). Responses are validated with the view schemas below: they accept
 * the server's role and handle spellings as they are, and keep the per-viewer
 * fields the UI needs (`canMessage`, `cannotMessageReason`).
 *
 * `canMessage` is computed by the server with the same rule the send path
 * enforces, and must be treated as authoritative. Passing `roomId` lets that
 * rule count "we are in the same lesson right now" as shared context.
 *
 * DM setting, in the contract's words:
 *   'anyone' | 'shared-context' | 'nobody'
 * "Receive private messages: off" is 'nobody'; teachers can still write.
 */

import { z } from 'zod';
import type { HttpClient } from '../http/httpClient.js';

export const PublicProfileViewSchema = z
  .object({
    userId: z.string(),
    displayName: z.string(),
    handle: z.string().nullable().default(null),
    avatarUrl: z.string().nullable().default(null),
    role: z.string().nullable().default(null),
    canMessage: z.boolean().default(false),
    cannotMessageReason: z.string().nullable().default(null),
    isBlockedByViewer: z.boolean().default(false),
  })
  .passthrough();
export type PublicProfileView = z.infer<typeof PublicProfileViewSchema>;

export const PrivacyViewSchema = z
  .object({
    dmPolicy: z.enum(['anyone', 'shared-context', 'nobody']).default('shared-context'),
    showPresence: z.boolean().default(true),
    sendReadReceipts: z.boolean().default(true),
  })
  .passthrough();
export type PrivacyView = z.infer<typeof PrivacyViewSchema>;

export const OwnProfileViewSchema = z
  .object({
    userId: z.string(),
    displayName: z.string(),
    email: z.string(),
    role: z.string().nullable().default(null),
    privacy: PrivacyViewSchema,
  })
  .passthrough();
export type OwnProfileView = z.infer<typeof OwnProfileViewSchema>;

export const BlockViewSchema = z
  .object({
    blockedUserId: z.string(),
    blockedAt: z.string().nullable().default(null),
    reason: z.string().nullable().default(null),
    profile: z.object({ userId: z.string(), displayName: z.string(), avatarUrl: z.string().nullable().default(null) }),
  })
  .passthrough();
export type BlockView = z.infer<typeof BlockViewSchema>;

const BlockPageSchema = z.object({
  items: z.array(BlockViewSchema),
  hasMore: z.boolean().default(false),
  nextCursor: z.string().nullable().default(null),
});

const SuggestionListSchema = z.object({
  items: z.array(
    z
      .object({
        userId: z.string(),
        displayName: z.string(),
        handle: z.string().nullable().default(null),
        avatarUrl: z.string().nullable().default(null),
      })
      .passthrough(),
  ),
});

export interface ProfileApi {
  getOwn(signal?: AbortSignal): Promise<OwnProfileView>;
  get(userId: string, options?: { roomId?: string | null; signal?: AbortSignal }): Promise<PublicProfileView>;
  update(input: Record<string, unknown>): Promise<OwnProfileView>;
  getPrivacy(signal?: AbortSignal): Promise<PrivacyView>;
  updatePrivacy(input: Partial<PrivacyView>): Promise<PrivacyView>;
  search(
    query: { q: string; scopeId?: string; limit?: number },
    signal?: AbortSignal,
  ): Promise<z.infer<typeof SuggestionListSchema>>;
  listBlocks(query?: { cursor?: string; limit?: number }, signal?: AbortSignal): Promise<z.infer<typeof BlockPageSchema>>;
  block(input: { userId: string; reason?: string }): Promise<BlockView>;
  unblock(userId: string): Promise<void>;

  // Kept for existing callers. Notification settings have no storage on the
  // server yet; reports and presence are served by other parts of the product.
  getByHandle(handle: string, signal?: AbortSignal): Promise<PublicProfileView>;
  updateNotifications(input: Record<string, unknown>): Promise<unknown>;
  setAvatar(assetId: string): Promise<OwnProfileView>;
  report(input: { userId: string; reason: string; detail?: string }): Promise<unknown>;
}

export const createProfileApi = (http: HttpClient): ProfileApi => ({
  getOwn: (signal) => http.get('/profiles/me', { schema: OwnProfileViewSchema, signal }),

  get: (userId, options = {}) =>
    http.get(`/profiles/${encodeURIComponent(userId)}`, {
      schema: PublicProfileViewSchema,
      query: options.roomId ? { roomId: options.roomId } : undefined,
      signal: options.signal,
    }),

  update: (input) => http.patch('/profiles/me', input, { schema: OwnProfileViewSchema }),

  getPrivacy: (signal) => http.get('/profiles/me/privacy', { schema: PrivacyViewSchema, signal }),

  updatePrivacy: (input) =>
    http.patch('/profiles/me/privacy', input, { schema: PrivacyViewSchema }),

  search: (query, signal) =>
    http.get('/profiles/search', {
      schema: SuggestionListSchema,
      query: { q: query.q, scopeId: query.scopeId, limit: query.limit },
      signal,
      // Typed into a mention box: a stale response is worthless.
      retry: { attempts: 1 },
      timeoutMs: 5_000,
    }),

  listBlocks: (query = {}, signal) =>
    http.get('/profiles/me/blocks', {
      schema: BlockPageSchema,
      query: { cursor: query.cursor, limit: query.limit },
      signal,
    }),

  /** Account-wide. Blocking for one lesson is chatApi.blockInSession(). */
  block: (input) => http.post('/profiles/me/blocks', input, { schema: BlockViewSchema }),

  unblock: async (userId) => {
    await http.delete(`/profiles/me/blocks/${encodeURIComponent(userId)}`);
  },

  getByHandle: (handle, signal) =>
    http.get(`/profiles/by-handle/${encodeURIComponent(handle)}`, { schema: PublicProfileViewSchema, signal }),

  updateNotifications: (input) => http.patch('/profiles/me/notifications', input),

  setAvatar: (assetId) => http.put('/profiles/me/avatar', { assetId }, { schema: OwnProfileViewSchema }),

  report: (input) =>
    http.post(`/profiles/${encodeURIComponent(input.userId)}/report`, {
      reason: input.reason,
      note: input.detail,
    }),
});
__P34_EOF__
echo "wrote packages/core-client/src/api/profileApi.ts"

mkdir -p packages/core-client/src/state
cat > packages/core-client/src/state/useConversations.ts <<'__P34_EOF__'
/**
 * useConversations  (F6)
 *
 * The "Rooms" list: the lesson's default chatroom (the tenant lobby) and every
 * private chat of the signed-in person, newest activity first, each with its
 * own unread count and mute state.
 *
 * Kept live without subscribing to every thread: the server pushes each
 * changed row to the person's own socket room (`chat:conversation.created` /
 * `.updated`, see chatGateway.notifyConversationUpdated), with that person's
 * unread count already in it. A chat someone else opened appears here with its
 * first message; a chat you deleted comes back when someone writes again.
 *
 * The lobby's badge is refreshed on focus and every 30 seconds rather than by
 * subscription: subscriptions belong to the open thread (useChat), and two
 * owners of one subscription would unsubscribe each other.
 *
 * What is open is reported with setOpen(): an open thread counts as read here
 * at once, even before the server's read marker catches up.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { ChatEvents } from '@classroom/contracts';
import type { ChatApi, ChannelView, ConversationView } from '../api/chatApi.js';
import type { SignalingTransport } from '../rtc/SfuClient.js';

const { CHAT_SERVER_EVENTS: SERVER } = ChatEvents;

const REFRESH_MS = 30_000;
const LOBBY = 'lobby';

// ---------------------------------------------------------------------------
// Pure helpers (exported for tests and for components)
// ---------------------------------------------------------------------------

/** A mute whose end time has passed is no longer a mute. */
export const isMutedNow = (
  item: { muted?: boolean; mutedUntil?: string | null } | null | undefined,
  now = Date.now(),
): boolean => Boolean(item?.muted) && (!item?.mutedUntil || Date.parse(item.mutedUntil) > now);

const activityOf = (conversation: ConversationView): number =>
  Date.parse(conversation.lastMessageAt ?? conversation.createdAt) || 0;

export const sortByActivity = (list: ConversationView[]): ConversationView[] =>
  [...list].sort((a, b) => activityOf(b) - activityOf(a));

/** The other person of a direct chat, or null. */
export const otherParticipant = (conversation: ConversationView, selfUserId: string) =>
  conversation.participants.find((participant) => participant.userId !== selfUserId) ?? null;

/** What a chat is called in the list: the other person, or the group title. */
export const titleOf = (conversation: ConversationView, selfUserId: string): string => {
  if (conversation.kind === 'group') return conversation.title ?? 'Group';
  return otherParticipant(conversation, selfUserId)?.profile.displayName ?? 'Private chat';
};

/**
 * Merges one pushed row into the list. Returns the new list and whether the
 * row is news for the person: more unread than before, not written by them,
 * not open, not muted.
 */
export const mergeConversation = (
  current: ConversationView[],
  incoming: ConversationView,
  { openId, selfUserId, now = Date.now() }: { openId: string | null; selfUserId: string; now?: number },
): { list: ConversationView[]; isNews: boolean } => {
  const previous = current.find((c) => c.conversationId === incoming.conversationId);
  const isOpen = openId === incoming.conversationId;
  const next = isOpen ? { ...incoming, unreadCount: 0 } : incoming;

  const isNews =
    !isOpen &&
    incoming.unreadCount > (previous?.unreadCount ?? 0) &&
    incoming.lastMessagePreview?.authorId !== selfUserId &&
    !isMutedNow(incoming, now);

  return {
    list: sortByActivity([next, ...current.filter((c) => c.conversationId !== incoming.conversationId)]),
    isNews,
  };
};

export const unreadTotalOf = (
  lobby: ChannelView | null,
  conversations: ConversationView[],
  now = Date.now(),
): number =>
  conversations.reduce((sum, c) => sum + (isMutedNow(c, now) ? 0 : c.unreadCount), 0) +
  (lobby && !isMutedNow(lobby, now) ? lobby.unreadCount : 0);

// ---------------------------------------------------------------------------
// Hook
// ---------------------------------------------------------------------------

export interface UseConversationsOptions {
  api: ChatApi;
  /** The `/chat` namespace connection. Without it the list refreshes by polling only. */
  socket?: SignalingTransport | null;
  selfUserId: string;
  enabled?: boolean;
  /** A row became news (see mergeConversation). For a toast or a sound. */
  onIncoming?(conversation: ConversationView): void;
}

export interface UseConversationsResult {
  lobby: ChannelView | null;
  conversations: ConversationView[];
  loading: boolean;
  error: unknown;
  /** Unread across the list, muted chats excluded. */
  unreadTotal: number;
  refresh(): Promise<void>;
  /** Opens (or reopens) a private chat and puts it in the list. */
  open(userId: string, options?: { roomId?: string | null }): Promise<ConversationView>;
  /** What is on screen now: a conversationId, 'lobby', or null. */
  setOpen(id: string | null): void;
  mute(conversationId: string, until: string | null): Promise<void>;
  unmute(conversationId: string): Promise<void>;
  remove(conversationId: string): Promise<void>;
  muteLobby(until: string | null): Promise<void>;
  unmuteLobby(): Promise<void>;
}

export const useConversations = (options: UseConversationsOptions): UseConversationsResult => {
  const { api, socket, selfUserId, enabled = true } = options;

  const [lobby, setLobby] = useState<ChannelView | null>(null);
  const [conversations, setConversations] = useState<ConversationView[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<unknown>(null);
  // Re-renders now and then so a mute that has run out shows as off.
  const [clock, setClock] = useState(0);

  const conversationsRef = useRef<ConversationView[]>([]);
  conversationsRef.current = conversations;
  const openRef = useRef<string | null>(null);
  const onIncomingRef = useRef(options.onIncoming);
  onIncomingRef.current = options.onIncoming;

  const refresh = useCallback(async () => {
    try {
      const [channels, page] = await Promise.all([
        api.listChannels({ scope: 'public' }),
        api.listConversations({ limit: 50 }),
      ]);
      const first = channels.items[0] ?? null;
      setLobby(first && openRef.current === LOBBY ? { ...first, unreadCount: 0 } : first);
      setConversations(
        sortByActivity(
          page.items.map((c) => (openRef.current === c.conversationId ? { ...c, unreadCount: 0 } : c)),
        ),
      );
      setError(null);
    } catch (cause) {
      setError(cause);
    } finally {
      setLoading(false);
    }
  }, [api]);

  useEffect(() => {
    if (!enabled) return undefined;
    void refresh();
    const poll = setInterval(() => void refresh(), REFRESH_MS);
    const tick = setInterval(() => setClock((n) => n + 1), 15_000);
    const onFocus = () => void refresh();
    const hasWindow = typeof window !== 'undefined' && typeof window.addEventListener === 'function';
    if (hasWindow) window.addEventListener('focus', onFocus);
    return () => {
      clearInterval(poll);
      clearInterval(tick);
      if (hasWindow) window.removeEventListener('focus', onFocus);
    };
  }, [enabled, refresh]);

  const upsert = useCallback(
    (incoming: ConversationView) => {
      const { list, isNews } = mergeConversation(conversationsRef.current, incoming, {
        openId: openRef.current,
        selfUserId,
      });
      conversationsRef.current = list;
      setConversations(list);
      if (isNews) onIncomingRef.current?.(incoming);
    },
    [selfUserId],
  );

  // Rows pushed to this person's own socket room.
  useEffect(() => {
    if (!socket || !enabled) return undefined;
    const onRow = (payload: { conversation?: ConversationView }) => {
      if (payload?.conversation?.conversationId) upsert(payload.conversation);
    };
    socket.on(SERVER.conversationCreated, onRow as (p: never) => void);
    socket.on(SERVER.conversationUpdated, onRow as (p: never) => void);
    return () => {
      socket.off(SERVER.conversationCreated, onRow as (p: never) => void);
      socket.off(SERVER.conversationUpdated, onRow as (p: never) => void);
    };
  }, [socket, enabled, upsert]);

  const setOpen = useCallback((id: string | null) => {
    openRef.current = id;
    if (!id) return;
    if (id === LOBBY) {
      setLobby((current) => (current ? { ...current, unreadCount: 0 } : current));
      return;
    }
    setConversations((current) =>
      current.map((c) => (c.conversationId === id ? { ...c, unreadCount: 0 } : c)),
    );
  }, []);

  const open = useCallback(
    async (userId: string, openOptions: { roomId?: string | null } = {}) => {
      const conversation = await api.openDirect(userId, openOptions);
      upsert(conversation);
      return conversation;
    },
    [api, upsert],
  );

  const mute = useCallback(
    async (conversationId: string, until: string | null) => {
      upsert(await api.muteConversation(conversationId, { muted: true, until }));
    },
    [api, upsert],
  );

  const unmute = useCallback(
    async (conversationId: string) => {
      upsert(await api.muteConversation(conversationId, { muted: false }));
    },
    [api, upsert],
  );

  const remove = useCallback(
    async (conversationId: string) => {
      await api.deleteConversation(conversationId);
      if (openRef.current === conversationId) openRef.current = null;
      setConversations((current) => current.filter((c) => c.conversationId !== conversationId));
    },
    [api],
  );

  const muteLobby = useCallback(
    async (until: string | null) => {
      if (!lobby) return;
      const result = await api.muteChannel(lobby.channelId, { muted: true, until });
      setLobby((current) => (current ? { ...current, muted: result.muted, mutedUntil: result.mutedUntil } : current));
    },
    [api, lobby],
  );

  const unmuteLobby = useCallback(async () => {
    if (!lobby) return;
    await api.muteChannel(lobby.channelId, { muted: false });
    setLobby((current) => (current ? { ...current, muted: false, mutedUntil: null } : current));
  }, [api, lobby]);

  // `clock` is a dependency on purpose: a mute that ran out changes the total.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const unreadTotal = useMemo(() => unreadTotalOf(lobby, conversations), [lobby, conversations, clock]);

  return {
    lobby,
    conversations,
    loading,
    error,
    unreadTotal,
    refresh,
    open,
    setOpen,
    mute,
    unmute,
    remove,
    muteLobby,
    unmuteLobby,
  };
};
__P34_EOF__
echo "wrote packages/core-client/src/state/useConversations.ts"

mkdir -p apps/web/src/components/Chat
cat > apps/web/src/components/Chat/ChatRooms.jsx <<'__P34_EOF__'
import { useCallback, useEffect, useRef, useState } from 'react';
import { isMutedNow, otherParticipant, titleOf, useChat } from '@classroom/core-client';
import './chatRooms.css';

/**
 * "Rooms": the default chatroom and every private chat, one under the other,
 * like a messenger. Used inside a lesson (ClassroomChatPanel) and on the
 * Messages page, so both behave the same.
 *
 *   list        the default chatroom first, then private chats by activity,
 *               each with its unread badge and a muted mark
 *   a chat      opened by clicking its row — and only then; a back arrow
 *               returns to the list. The ⋯ menu mutes (1 hour, 8 hours,
 *               1 day, until turned back on), deletes the chat for you (not the
 *               default chatroom), and inside a lesson blocks the other person
 *               for this lesson.
 *
 * The component is controlled: the caller owns `view` so it can open a chat it
 * just created (after the "Send a private message?" confirmation) and owns
 * the useConversations state so the tab badge can show the total.
 */

const time = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit' });
const day = new Intl.DateTimeFormat(undefined, { day: 'numeric', month: 'short' });

const HOUR = 60 * 60 * 1000;
export const MUTE_CHOICES = [
  { id: '1h', label: 'Mute for 1 hour', ms: HOUR },
  { id: '8h', label: 'Mute for 8 hours', ms: 8 * HOUR },
  { id: '1d', label: 'Mute for 1 day', ms: 24 * HOUR },
  { id: 'on', label: 'Mute until I turn it back on', ms: null },
];

const untilFor = (choice) => (choice.ms ? new Date(Date.now() + choice.ms).toISOString() : null);

function shortTime(iso) {
  if (!iso) return '';
  const date = new Date(iso);
  return date.toDateString() === new Date().toDateString() ? time.format(date) : day.format(date);
}

function mutedLabel(item) {
  if (!isMutedNow(item)) return null;
  return item.mutedUntil ? `Muted until ${shortTime(item.mutedUntil)}` : 'Muted';
}

/* ------------------------------------------------------------------ *
 * Lesson blocks
 * ------------------------------------------------------------------ */

/** Whom I have blocked in this lesson. Nothing without a roomId. */
export function useSessionBlocks({ api, roomId }) {
  const [blocked, setBlocked] = useState(() => new Set());

  useEffect(() => {
    if (!roomId) return undefined;
    let cancelled = false;
    api
      .listSessionBlocks(roomId)
      .then((result) => !cancelled && setBlocked(new Set(result.blockedUserIds)))
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, [api, roomId]);

  const block = useCallback(
    async (userId) => {
      await api.blockInSession(roomId, userId);
      setBlocked((current) => new Set(current).add(userId));
    },
    [api, roomId],
  );

  const unblock = useCallback(
    async (userId) => {
      await api.unblockInSession(roomId, userId);
      setBlocked((current) => {
        const next = new Set(current);
        next.delete(userId);
        return next;
      });
    },
    [api, roomId],
  );

  return { enabled: Boolean(roomId), blocked, block, unblock };
}

/* ------------------------------------------------------------------ *
 * The ⋯ menu
 * ------------------------------------------------------------------ */

function ChatMenu({ items }) {
  const [open, setOpen] = useState(false);
  const wrapRef = useRef(null);

  useEffect(() => {
    if (!open) return undefined;
    const close = (event) => {
      if (!wrapRef.current?.contains(event.target)) setOpen(false);
    };
    const onKey = (event) => event.key === 'Escape' && setOpen(false);
    document.addEventListener('pointerdown', close);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('pointerdown', close);
      document.removeEventListener('keydown', onKey);
    };
  }, [open]);

  return (
    <span className="rooms-menu" ref={wrapRef}>
      <button
        type="button"
        className="btn btn--tiny"
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label="Chat options"
        onClick={() => setOpen((value) => !value)}
      >
        ⋯
      </button>
      {open ? (
        <div className="rooms-menu__items" role="menu">
          {items.map((item) =>
            item.separator ? (
              <hr key={item.id} className="rooms-menu__sep" />
            ) : (
              <button
                key={item.id}
                type="button"
                role="menuitem"
                className={`rooms-menu__item${item.danger ? ' rooms-menu__item--danger' : ''}`}
                onClick={() => {
                  setOpen(false);
                  item.run();
                }}
              >
                {item.label}
              </button>
            ),
          )}
        </div>
      ) : null}
    </span>
  );
}

/* ------------------------------------------------------------------ *
 * One thread
 * ------------------------------------------------------------------ */

/**
 * One thread, whichever target it is pointed at. A private chat and the
 * default chatroom differ only in `target`.
 */
export function ChatThread({ api, socket, self, target, placeholder, emptyText, disabledReason = '' }) {
  const [draft, setDraft] = useState('');
  const bottomRef = useRef(null);

  const { messages, loading, hasMore, loadOlder, typingUserIds, throttledUntil, send, retry, setTyping } =
    useChat({ api, socket: socket ?? undefined, target, self });

  const throttled = throttledUntil !== null && throttledUntil > Date.now();
  const disabled = throttled || Boolean(disabledReason);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ block: 'end' });
  }, [messages.length]);

  const submit = async (event) => {
    event.preventDefault();
    const body = draft.trim();
    if (!body || disabled) return;
    setDraft('');
    setTyping(false);
    await send({ body });
  };

  return (
    <div className="thread">
      <div className="thread__messages">
        {hasMore && (
          <button type="button" className="btn btn--tiny" onClick={() => loadOlder()}>
            Load earlier messages
          </button>
        )}

        {loading && <p className="thread__empty">Loading…</p>}
        {!loading && messages.length === 0 && <p className="thread__empty">{emptyText}</p>}

        {messages.map((message) => (
          <div
            key={message.clientMessageId ?? message.messageId}
            className={[
              'bubble',
              message.author?.userId === self.userId ? 'bubble--mine' : '',
              message.delivery === 'failed' ? 'bubble--failed' : '',
              message.delivery === 'sending' ? 'bubble--pending' : '',
            ]
              .filter(Boolean)
              .join(' ')}
          >
            {message.author?.userId !== self.userId && (
              <span className="bubble__author">{message.author?.displayName}</span>
            )}
            <span className="bubble__body">{message.deletedAt ? <em>Message deleted</em> : message.body}</span>
            {message.delivery === 'failed' && (
              <button type="button" className="bubble__retry" onClick={() => retry(message.clientMessageId)}>
                Not sent — retry
              </button>
            )}
          </div>
        ))}
        <div ref={bottomRef} />
      </div>

      {typingUserIds.length > 0 && (
        <p className="thread__typing">
          {typingUserIds.length === 1 ? 'Someone is typing…' : `${typingUserIds.length} people are typing…`}
        </p>
      )}

      {disabledReason ? <p className="rooms-notice">{disabledReason}</p> : null}

      <form className="thread__composer" onSubmit={submit}>
        <input
          value={draft}
          onChange={(event) => {
            setDraft(event.target.value);
            setTyping(event.target.value.length > 0);
          }}
          placeholder={throttled ? 'Slow mode — wait a moment' : placeholder}
          disabled={disabled}
          aria-label={placeholder}
        />
        <button type="submit" className="btn btn--tiny" disabled={!draft.trim() || disabled}>
          Send
        </button>
      </form>
    </div>
  );
}

/* ------------------------------------------------------------------ *
 * The list and the open chat
 * ------------------------------------------------------------------ */

export default function ChatRooms({ rooms, view, onViewChange, api, socket, self, roomId = null, sessionBlocks = null }) {
  const [status, setStatus] = useState(null);

  const openId = view.type === 'lobby' ? 'lobby' : view.type === 'conversation' ? view.id : null;
  const { setOpen } = rooms;
  useEffect(() => {
    setOpen(openId);
    return () => setOpen(null);
  }, [openId, setOpen]);

  const run = async (fn, doneText) => {
    setStatus(null);
    try {
      await fn();
      if (doneText) setStatus({ text: doneText });
    } catch (cause) {
      setStatus({ error: true, text: cause?.detail ?? cause?.message ?? 'That did not work. Try again.' });
    }
  };

  const muteItems = (item, onMute, onUnmute) =>
    isMutedNow(item)
      ? [{ id: 'unmute', label: 'Turn notifications back on', run: () => run(onUnmute, 'Notifications are on again.') }]
      : MUTE_CHOICES.map((choice) => ({
          id: choice.id,
          label: choice.label,
          run: () => run(() => onMute(untilFor(choice)), 'Muted.'),
        }));

  /* ---- an open chat ---- */

  if (view.type === 'lobby' && rooms.lobby) {
    const lobby = rooms.lobby;
    return (
      <div className="rooms">
        <header className="rooms-head">
          <button type="button" className="btn btn--tiny" onClick={() => onViewChange({ type: 'list' })} aria-label="Back to Rooms">
            ←
          </button>
          <p className="rooms-head__title">
            # {lobby.name}
            {mutedLabel(lobby) ? <span className="rooms-head__sub">{mutedLabel(lobby)}</span> : null}
          </p>
          <ChatMenu items={muteItems(lobby, (until) => rooms.muteLobby(until), () => rooms.unmuteLobby())} />
        </header>
        {status ? <p className={`rooms-status${status.error ? ' rooms-status--error' : ''}`}>{status.text}</p> : null}
        <ChatThread
          key={`ch:${lobby.channelId}`}
          api={api}
          socket={socket}
          self={self}
          target={{ kind: 'channel', channelId: lobby.channelId }}
          placeholder="Message everyone"
          emptyText="Nothing here yet. Say hello."
        />
      </div>
    );
  }

  if (view.type === 'conversation') {
    const conversation = rooms.conversations.find((c) => c.conversationId === view.id);
    if (!conversation) {
      return (
        <div className="rooms">
          <p className="rooms-notice">This chat is no longer in your list.</p>
          <button type="button" className="btn btn--tiny" onClick={() => onViewChange({ type: 'list' })}>
            Back to Rooms
          </button>
        </div>
      );
    }

    const title = titleOf(conversation, self.userId);
    const other = conversation.kind === 'direct' ? otherParticipant(conversation, self.userId) : null;
    const blockedHere = Boolean(other && sessionBlocks?.enabled && sessionBlocks.blocked.has(other.userId));

    const items = [
      ...muteItems(
        conversation,
        (until) => rooms.mute(conversation.conversationId, until),
        () => rooms.unmute(conversation.conversationId),
      ),
      { id: 'sep-1', separator: true },
      ...(other && sessionBlocks?.enabled
        ? [
            blockedHere
              ? { id: 'unblock', label: `Unblock ${title} for this lesson`, run: () => run(() => sessionBlocks.unblock(other.userId), `${title} can write to you again.`) }
              : { id: 'block', label: `Block ${title} for this lesson`, danger: true, run: () => run(() => sessionBlocks.block(other.userId), `${title} cannot write to you during this lesson.`) },
          ]
        : []),
      {
        id: 'delete',
        label: 'Delete chat for me',
        danger: true,
        run: () => {
          const sure = window.confirm(
            `Delete the chat with ${title}? It disappears for you only — ${title} keeps it. If they write again, it comes back without the old messages.`,
          );
          if (!sure) return;
          run(async () => {
            await rooms.remove(conversation.conversationId);
            onViewChange({ type: 'list' });
          });
        },
      },
    ];

    return (
      <div className="rooms">
        <header className="rooms-head">
          <button type="button" className="btn btn--tiny" onClick={() => onViewChange({ type: 'list' })} aria-label="Back to Rooms">
            ←
          </button>
          <p className="rooms-head__title">
            {title}
            {mutedLabel(conversation) ? <span className="rooms-head__sub">{mutedLabel(conversation)}</span> : null}
          </p>
          <ChatMenu items={items} />
        </header>
        {status ? <p className={`rooms-status${status.error ? ' rooms-status--error' : ''}`}>{status.text}</p> : null}
        <ChatThread
          key={`dm:${conversation.conversationId}`}
          api={api}
          socket={socket}
          self={self}
          target={{ kind: 'conversation', conversationId: conversation.conversationId }}
          placeholder={`Message ${title}`}
          emptyText={`This is the start of your conversation with ${title}.`}
          disabledReason={blockedHere ? `You blocked ${title} for this lesson. Unblock them in the ⋯ menu to write again.` : ''}
        />
      </div>
    );
  }

  /* ---- the list ---- */

  return (
    <div className="rooms">
      {rooms.error && !rooms.lobby && rooms.conversations.length === 0 ? (
        <div className="rooms-notice">
          <p>The chats could not be loaded.</p>
          <button type="button" className="btn btn--tiny" onClick={() => rooms.refresh()}>
            Try again
          </button>
        </div>
      ) : null}

      {rooms.loading && !rooms.lobby ? <p className="rooms-notice">Loading…</p> : null}

      <div className="rooms-list" role="list">
        {rooms.lobby ? (
          <button
            type="button"
            role="listitem"
            className={`rooms-row${rooms.lobby.unreadCount ? ' rooms-row--unread' : ''}`}
            onClick={() => onViewChange({ type: 'lobby' })}
          >
            <span className="rooms-row__avatar" aria-hidden="true">#</span>
            <span className="rooms-row__main">
              <span className="rooms-row__name">{rooms.lobby.name}</span>
              <span className="rooms-row__preview">{mutedLabel(rooms.lobby) ?? 'Default chatroom · everyone'}</span>
            </span>
            <span className="rooms-row__time">{shortTime(rooms.lobby.lastMessageAt)}</span>
            {rooms.lobby.unreadCount ? (
              <span className={`rooms-badge${isMutedNow(rooms.lobby) ? ' rooms-badge--muted' : ''}`}>
                {rooms.lobby.unreadCount > 99 ? '99+' : rooms.lobby.unreadCount}
              </span>
            ) : null}
          </button>
        ) : null}

        <p className="rooms-list__group">Private chats</p>

        {rooms.conversations.length === 0 && !rooms.loading ? (
          <p className="rooms-notice">
            {roomId
              ? 'No private chats yet. Click a person under People to start one.'
              : 'No private chats yet. Open a lesson and click a person to start one.'}
          </p>
        ) : null}

        {rooms.conversations.map((conversation) => {
          const title = titleOf(conversation, self.userId);
          const preview = conversation.lastMessagePreview;
          const muted = isMutedNow(conversation);
          return (
            <button
              key={conversation.conversationId}
              type="button"
              role="listitem"
              className={`rooms-row${conversation.unreadCount ? ' rooms-row--unread' : ''}`}
              onClick={() => onViewChange({ type: 'conversation', id: conversation.conversationId })}
            >
              <span className="rooms-row__avatar" aria-hidden="true">{title.charAt(0).toUpperCase()}</span>
              <span className="rooms-row__main">
                <span className="rooms-row__name">
                  {title}
                  {muted ? <span className="rooms-row__muted" title={mutedLabel(conversation)}> 🔕</span> : null}
                </span>
                <span className="rooms-row__preview">
                  {preview ? `${preview.authorId === self.userId ? 'You: ' : ''}${preview.body}` : 'No messages yet'}
                </span>
              </span>
              <span className="rooms-row__time">{shortTime(conversation.lastMessageAt ?? conversation.createdAt)}</span>
              {conversation.unreadCount ? (
                <span className={`rooms-badge${muted ? ' rooms-badge--muted' : ''}`}>
                  {conversation.unreadCount > 99 ? '99+' : conversation.unreadCount}
                </span>
              ) : null}
            </button>
          );
        })}
      </div>

      {status ? <p className={`rooms-status${status.error ? ' rooms-status--error' : ''}`}>{status.text}</p> : null}
    </div>
  );
}
__P34_EOF__
echo "wrote apps/web/src/components/Chat/ChatRooms.jsx"

mkdir -p apps/web/src/components/Chat
cat > apps/web/src/components/Chat/chatRooms.css <<'__P34_EOF__'
/* Rooms list, open chat, person dialog, toast and settings — see ChatRooms.jsx. */

.rooms { display: flex; flex-direction: column; min-height: 0; flex: 1 1 auto; gap: 6px; }

.rooms-list { display: flex; flex-direction: column; gap: 2px; overflow-y: auto; }
.rooms-list__group { margin: 10px 4px 2px; font-size: 12px; text-transform: uppercase; letter-spacing: .04em; opacity: .65; }

.rooms-row {
  display: grid; grid-template-columns: 32px 1fr auto auto; align-items: center; gap: 8px;
  width: 100%; padding: 8px; border: 0; border-radius: 8px; background: transparent;
  color: inherit; font: inherit; text-align: start; cursor: pointer;
}
.rooms-row:hover, .rooms-row:focus-visible { background: rgba(127, 127, 127, .12); }
.rooms-row--unread .rooms-row__name { font-weight: 700; }
.rooms-row__avatar {
  width: 32px; height: 32px; border-radius: 50%; display: grid; place-items: center;
  background: rgba(127, 127, 127, .22); font-weight: 700;
}
.rooms-row__main { display: flex; flex-direction: column; min-width: 0; }
.rooms-row__name { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.rooms-row__preview { font-size: 12px; opacity: .7; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.rooms-row__time { font-size: 11px; opacity: .6; }
.rooms-row__muted { font-size: 11px; }

.rooms-badge {
  min-width: 20px; height: 20px; padding: 0 6px; border-radius: 10px; display: inline-grid; place-items: center;
  background: #2563eb; color: #fff; font-size: 11px; font-weight: 700;
}
.rooms-badge--muted { background: rgba(127, 127, 127, .55); }
.panel__tab .rooms-badge { margin-inline-start: 6px; }

.rooms-head { display: flex; align-items: center; gap: 8px; }
.rooms-head__title { flex: 1 1 auto; margin: 0; font-weight: 700; display: flex; flex-direction: column; min-width: 0; }
.rooms-head__sub { font-weight: 400; font-size: 12px; opacity: .7; }

.rooms-menu { position: relative; }
.rooms-menu__items {
  position: absolute; inset-inline-end: 0; top: calc(100% + 4px); z-index: 20; min-width: 240px;
  display: flex; flex-direction: column; padding: 4px; border-radius: 8px;
  background: var(--color-surface, #fff); color: var(--color-text, #111);
  box-shadow: 0 8px 24px rgba(0, 0, 0, .18);
}
.rooms-menu__item { padding: 8px 10px; border: 0; background: transparent; color: inherit; font: inherit; text-align: start; border-radius: 6px; cursor: pointer; }
.rooms-menu__item:hover, .rooms-menu__item:focus-visible { background: rgba(127, 127, 127, .14); }
.rooms-menu__item--danger { color: #b91c1c; }
.rooms-menu__sep { border: 0; border-top: 1px solid rgba(127, 127, 127, .25); margin: 4px 0; }

.rooms-notice { margin: 4px; font-size: 13px; opacity: .8; }
.rooms-status { margin: 0 4px; font-size: 12px; opacity: .8; }
.rooms-status--error { color: #b91c1c; opacity: 1; }

.rooms-toast {
  display: flex; align-items: center; gap: 8px; width: 100%; margin-bottom: 6px; padding: 8px 10px;
  border: 0; border-radius: 8px; background: #2563eb; color: #fff; font: inherit; text-align: start; cursor: pointer;
}
.rooms-toast__text { flex: 1 1 auto; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

.person-dialog { border: 0; border-radius: 12px; padding: 0; width: min(360px, 92vw); box-shadow: 0 16px 48px rgba(0, 0, 0, .25); }
.person-dialog::backdrop { background: rgba(0, 0, 0, .35); }
.person-dialog__body { padding: 16px; display: flex; flex-direction: column; gap: 10px; }
.person-dialog__title { margin: 0; font-size: 18px; }
.person-dialog__hint { margin: 0; font-size: 13px; opacity: .75; }
.person-dialog__actions { display: flex; flex-direction: column; gap: 8px; }
.person-dialog__actions .btn { width: 100%; }

.settings { display: grid; gap: 22px; max-width: 640px; }
.settings__section { display: grid; gap: 8px; }
.settings__switch { display: flex; gap: 10px; align-items: flex-start; }
.settings__hint { margin: 0; font-size: 13px; opacity: .75; }
.settings__row { display: flex; align-items: center; gap: 10px; }
.settings__row span { flex: 1 1 auto; }

.messages-page { display: flex; flex-direction: column; gap: 12px; max-width: 720px; min-height: 60vh; }
__P34_EOF__
echo "wrote apps/web/src/components/Chat/chatRooms.css"

mkdir -p apps/web/src/components/Classroom
cat > apps/web/src/components/Classroom/ClassroomChatPanel.jsx <<'__P34_EOF__'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  createChatApi,
  createProfileApi,
  titleOf,
  useConversations,
  useCore,
} from '@classroom/core-client';

import ParticipantList from './ParticipantList.jsx';
import ChatRooms, { useSessionBlocks } from '../Chat/ChatRooms.jsx';
import '../Chat/chatRooms.css';

/**
 * The sidebar of a lesson  (F1, F6)
 *
 * Two tabs, and only two:
 *
 *   People   who is here. Clicking a person opens a small dialog —
 *            "Send a private message?" and "Block for this lesson" — instead
 *            of opening a chat straight away.
 *   Rooms    the default chatroom and every private chat, one under the other
 *            (ChatRooms). A chat opens when its row is clicked, nowhere else.
 *
 * A private chat is created only after the confirmation in the dialog, and
 * appears in Rooms under the default chatroom. The other person sees it once
 * the first message arrives — with a badge on the Rooms tab and a short notice
 * at the top, so nobody has to click the sender to find out they were written
 * to. Muted chats count neither in the badge nor in the notice.
 */
export default function ClassroomChatPanel({ roomId, peers, selfPeerId, canModerate, onHostAction }) {
  const { http, chatSocket, session } = useCore();

  // One instance each for the life of the panel.
  const api = useMemo(() => createChatApi(http), [http]);
  const profiles = useMemo(() => createProfileApi(http), [http]);

  const self = useMemo(
    () => ({
      userId: session?.userId ?? '',
      displayName: session?.displayName ?? 'You',
      avatarUrl: session?.avatarUrl ?? null,
    }),
    [session],
  );

  const [tab, setTab] = useState('people');
  const [view, setView] = useState({ type: 'list' });
  const [person, setPerson] = useState(null);
  const [toast, setToast] = useState(null);
  const toastTimer = useRef(null);

  const onIncoming = useCallback(
    (conversation) => {
      setToast({ conversationId: conversation.conversationId, title: titleOf(conversation, self.userId) });
      window.clearTimeout(toastTimer.current);
      toastTimer.current = window.setTimeout(() => setToast(null), 8_000);
    },
    [self.userId],
  );
  useEffect(() => () => window.clearTimeout(toastTimer.current), []);

  const rooms = useConversations({
    api,
    socket: chatSocket ?? undefined,
    selfUserId: self.userId,
    enabled: Boolean(self.userId),
    onIncoming,
  });
  const sessionBlocks = useSessionBlocks({ api, roomId });

  const showConversation = useCallback((conversationId) => {
    setTab('rooms');
    setView({ type: 'conversation', id: conversationId });
    setToast(null);
  }, []);

  return (
    <aside className="panel">
      <nav className="panel__tabs" role="tablist">
        <button
          type="button"
          role="tab"
          aria-selected={tab === 'people'}
          className={tab === 'people' ? 'panel__tab is-active' : 'panel__tab'}
          onClick={() => setTab('people')}
        >
          People <span className="panel__count">{peers.length}</span>
        </button>

        <button
          type="button"
          role="tab"
          aria-selected={tab === 'rooms'}
          className={tab === 'rooms' ? 'panel__tab is-active' : 'panel__tab'}
          onClick={() => setTab('rooms')}
        >
          Rooms
          {rooms.unreadTotal > 0 ? (
            <span className="rooms-badge" aria-label={`${rooms.unreadTotal} unread`}>
              {rooms.unreadTotal > 99 ? '99+' : rooms.unreadTotal}
            </span>
          ) : null}
        </button>
      </nav>

      {toast && !(tab === 'rooms' && view.type === 'conversation' && view.id === toast.conversationId) ? (
        <button type="button" className="rooms-toast" onClick={() => showConversation(toast.conversationId)}>
          <span className="rooms-toast__text">New message from {toast.title}</span>
          <span aria-hidden="true">Open</span>
        </button>
      ) : null}

      {tab === 'people' && (
        <ParticipantList
          peers={peers}
          selfPeerId={selfPeerId}
          canModerate={canModerate}
          onHostAction={onHostAction}
          onMessage={(peer) => setPerson(peer)}
        />
      )}

      {tab === 'rooms' && (
        <ChatRooms
          rooms={rooms}
          view={view}
          onViewChange={setView}
          api={api}
          socket={chatSocket}
          self={self}
          roomId={roomId}
          sessionBlocks={sessionBlocks}
        />
      )}

      {person ? (
        <PersonDialog
          peer={person}
          roomId={roomId}
          profiles={profiles}
          rooms={rooms}
          sessionBlocks={sessionBlocks}
          onClose={() => setPerson(null)}
          onOpened={(conversation) => {
            setPerson(null);
            showConversation(conversation.conversationId);
          }}
        />
      ) : null}
    </aside>
  );
}

/**
 * What clicking a person offers. Nothing is created until the person confirms:
 * "Send a private message" opens (or reopens) the chat and shows it in Rooms.
 * Whether writing is allowed comes from the server, with the same rule the send
 * path enforces, so a button that is on here does not fail afterwards.
 */
function PersonDialog({ peer, roomId, profiles, rooms, sessionBlocks, onClose, onOpened }) {
  const dialogRef = useRef(null);
  const name = peer.user?.displayName ?? 'this person';
  const userId = peer.user?.userId;

  const [profile, setProfile] = useState(null);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState(null);

  const blockedHere = sessionBlocks.enabled && sessionBlocks.blocked.has(userId);

  useEffect(() => {
    const el = dialogRef.current;
    if (el && !el.open) el.showModal();
  }, []);

  useEffect(() => {
    let cancelled = false;
    profiles
      .get(userId, { roomId })
      .then((result) => !cancelled && setProfile(result))
      .catch(() => !cancelled && setProfile({ canMessage: true, cannotMessageReason: null }));
    return () => {
      cancelled = true;
    };
  }, [profiles, userId, roomId, blockedHere]);

  const act = async (fn) => {
    setBusy(true);
    setMessage(null);
    try {
      await fn();
    } catch (cause) {
      setMessage(cause?.detail ?? cause?.message ?? 'That did not work. Try again.');
    } finally {
      setBusy(false);
    }
  };

  const openChat = () =>
    act(async () => {
      const conversation = await rooms.open(userId, { roomId });
      onOpened(conversation);
    });

  const canMessage = profile ? profile.canMessage && !blockedHere : false;

  return (
    <dialog
      ref={dialogRef}
      className="person-dialog"
      aria-label={name}
      onCancel={(event) => {
        event.preventDefault();
        onClose();
      }}
    >
      <div className="person-dialog__body">
        <h2 className="person-dialog__title">{name}</h2>

        {!profile ? <p className="person-dialog__hint">Checking…</p> : null}

        {profile ? (
          <p className="person-dialog__hint">
            {blockedHere
              ? `You blocked ${name} for this lesson.`
              : canMessage
                ? `Send ${name} a private message? The chat appears under Rooms.`
                : (profile.cannotMessageReason ?? `${name} is not accepting private messages.`)}
          </p>
        ) : null}

        {message ? <p className="person-dialog__hint rooms-status--error">{message}</p> : null}

        <div className="person-dialog__actions">
          <button type="button" className="btn" disabled={busy || !canMessage} onClick={openChat}>
            {busy ? 'Opening…' : 'Send a private message'}
          </button>

          {sessionBlocks.enabled ? (
            blockedHere ? (
              <button type="button" className="btn" disabled={busy} onClick={() => act(() => sessionBlocks.unblock(userId))}>
                Unblock for this lesson
              </button>
            ) : (
              <button
                type="button"
                className="btn btn--danger"
                disabled={busy}
                onClick={() =>
                  act(async () => {
                    await sessionBlocks.block(userId);
                    setMessage(`${name} cannot write to you privately until this lesson ends.`);
                  })
                }
              >
                Block for this lesson
              </button>
            )
          ) : null}

          <button type="button" className="btn btn--tiny" onClick={onClose}>
            Cancel
          </button>
        </div>
      </div>
    </dialog>
  );
}
__P34_EOF__
echo "wrote apps/web/src/components/Classroom/ClassroomChatPanel.jsx"

mkdir -p apps/web/src/components/Classroom
cat > apps/web/src/components/Classroom/ParticipantList.jsx <<'__P34_EOF__'
/**
 * Participant list  (F1, F6)
 *
 * Clicking a person opens the person dialog in ClassroomChatPanel: "Send a
 * private message?" and "Block for this lesson". Nothing is opened or created
 * by the click itself.
 */
export default function ParticipantList({ peers, selfPeerId, canModerate, onHostAction, onMessage }) {
  const sorted = [...peers].sort((a, b) => {
    // Raised hands to the top, in the order they went up; hosts next.
    if (a.handRaised !== b.handRaised) return a.handRaised ? -1 : 1;
    const rank = { host: 0, cohost: 1, learner: 2 };
    if (rank[a.role] !== rank[b.role]) return rank[a.role] - rank[b.role];
    return (a.user?.displayName ?? 'Participant').localeCompare(b.user?.displayName ?? 'Participant');
  });

  return (
    <aside className="participants">
      <h2 className="participants__title">In this room ({peers.length})</h2>

      <ul className="participants__list">
        {sorted.map((peer) => {
          const displayName = peer.user?.displayName || 'Participant';
          const isSelf = peer.peerId === selfPeerId;
          const muted = !peer.producers.some((producer) => producer.source === 'microphone' && !producer.paused);
          const sharing = peer.producers.some((producer) => producer.source === 'screen');

          return (
            <li key={peer.peerId} className="participants__row">
              <button
                type="button"
                className="participants__person"
                onClick={() => onMessage?.(peer)}
                title={isSelf ? undefined : `Options for ${displayName}`}
                aria-label={isSelf ? `${displayName} (you)` : `Options for ${displayName}`}
                disabled={!onMessage || isSelf}
              >
                {peer.user?.avatarUrl ? (
                  <img src={peer.user.avatarUrl} alt="" className="participants__avatar" />
                ) : (
                  <span className="participants__avatar participants__avatar--initial">
                    {displayName.charAt(0).toUpperCase()}
                  </span>
                )}

                <span className="participants__name">
                  {displayName}
                  {isSelf && ' (you)'}
                </span>

                {peer.role !== 'learner' && <span className="participants__role">{peer.role}</span>}
              </button>

              <span className="participants__status" aria-hidden="true">
                {peer.handRaised && '✋'}
                {sharing && '🖥'}
                {muted && '🔇'}
              </span>

              {canModerate && !isSelf && (
                <span className="participants__actions">
                  <button
                    type="button"
                    className="btn btn--tiny"
                    onClick={() => onHostAction({ targetPeerId: peer.peerId, action: 'mute' })}
                  >
                    Mute
                  </button>
                  <button
                    type="button"
                    className="btn btn--tiny btn--danger"
                    onClick={() => onHostAction({ targetPeerId: peer.peerId, action: 'remove' })}
                  >
                    Remove
                  </button>
                </span>
              )}
            </li>
          );
        })}
      </ul>
    </aside>
  );
}
__P34_EOF__
echo "wrote apps/web/src/components/Classroom/ParticipantList.jsx"

mkdir -p apps/web/src/pages
cat > apps/web/src/pages/SettingsPage.jsx <<'__P34_EOF__'
import { useEffect, useMemo, useState } from 'react';
import { createProfileApi, useCore } from '@classroom/core-client';
import '../components/Chat/chatRooms.css';

/**
 * Settings  (F6)
 *
 * Private messages
 *   One switch. Off means nobody can start a private chat with you — with one
 *   exception, by design: teachers can still reach you, so a course can always
 *   contact its participants. Chats you already have keep working.
 *   On restores the default: people you share a course, a space or a running
 *   lesson with may write to you.
 *
 * Blocked people
 *   Account-wide blocks, with a way to undo each one. Blocking someone only for
 *   a lesson happens inside that lesson and ends with it; it is not listed here.
 *
 * Every change is saved immediately and confirmed; a change the server refused
 * is put back, so the switch never shows something that is not true.
 */
export default function SettingsPage() {
  const { http } = useCore();
  const profiles = useMemo(() => createProfileApi(http), [http]);

  const [privacy, setPrivacy] = useState(null);
  const [blocks, setBlocks] = useState([]);
  const [status, setStatus] = useState(null);
  const [pending, setPending] = useState(null);

  useEffect(() => {
    let cancelled = false;
    Promise.all([profiles.getPrivacy(), profiles.listBlocks({ limit: 100 })])
      .then(([p, b]) => {
        if (cancelled) return;
        setPrivacy(p);
        setBlocks(b.items);
      })
      .catch(() => !cancelled && setStatus({ error: true, text: 'Your settings could not be loaded.' }));
    return () => {
      cancelled = true;
    };
  }, [profiles]);

  const receivesMessages = privacy ? privacy.dmPolicy !== 'nobody' : true;

  const setReceivesMessages = async (on) => {
    const previous = privacy;
    setPrivacy({ ...privacy, dmPolicy: on ? 'shared-context' : 'nobody' });
    setPending('dm');
    setStatus(null);
    try {
      setPrivacy(await profiles.updatePrivacy({ dmPolicy: on ? 'shared-context' : 'nobody' }));
      setStatus({ text: on ? 'Private messages are on.' : 'Private messages are off.' });
    } catch {
      setPrivacy(previous);
      setStatus({ error: true, text: 'That change was not saved. Try again.' });
    } finally {
      setPending(null);
    }
  };

  const unblock = async (block) => {
    setPending(block.blockedUserId);
    setStatus(null);
    try {
      await profiles.unblock(block.blockedUserId);
      setBlocks((current) => current.filter((b) => b.blockedUserId !== block.blockedUserId));
      setStatus({ text: `${block.profile.displayName} is no longer blocked.` });
    } catch {
      setStatus({ error: true, text: 'That person could not be unblocked. Try again.' });
    } finally {
      setPending(null);
    }
  };

  return (
    <section className="page settings">
      <h1>Settings</h1>

      {!privacy && !status ? <p className="muted">Loading your settings…</p> : null}

      {privacy ? (
        <div className="settings__section">
          <h2>Private messages</h2>
          <label className="settings__switch">
            <input
              type="checkbox"
              checked={receivesMessages}
              disabled={pending === 'dm'}
              onChange={(event) => setReceivesMessages(event.target.checked)}
            />
            <span>
              <strong>Receive private messages</strong>
              <p className="settings__hint">
                {receivesMessages
                  ? 'On: people you share a course, a space or a running lesson with can start a private chat with you.'
                  : 'Off: nobody can start a new private chat with you. Teachers can still reach you, so a course can always contact its participants. Chats you already have keep working.'}
              </p>
            </span>
          </label>
        </div>
      ) : null}

      {privacy ? (
        <div className="settings__section">
          <h2>Blocked people</h2>
          <p className="settings__hint">
            Blocked people cannot write to you and you cannot write to them. Blocks made only for one lesson end with
            that lesson and are not listed here.
          </p>
          {blocks.length === 0 ? <p className="muted">You have not blocked anyone.</p> : null}
          {blocks.map((block) => (
            <div key={block.blockedUserId} className="settings__row">
              <span>{block.profile.displayName}</span>
              <button
                type="button"
                className="btn btn--tiny"
                disabled={pending === block.blockedUserId}
                onClick={() => unblock(block)}
              >
                Unblock
              </button>
            </div>
          ))}
        </div>
      ) : null}

      {status ? (
        <p className={status.error ? 'rooms-status rooms-status--error' : 'rooms-status'} aria-live="polite">
          {status.text}
        </p>
      ) : null}
    </section>
  );
}
__P34_EOF__
echo "wrote apps/web/src/pages/SettingsPage.jsx"

mkdir -p apps/web/src/pages
cat > apps/web/src/pages/MessagesPage.jsx <<'__P34_EOF__'
import { useEffect, useMemo, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { createChatApi, useConversations, useCore } from '@classroom/core-client';
import ChatRooms from '../components/Chat/ChatRooms.jsx';
import '../components/Chat/chatRooms.css';

/**
 * Messages  (F6)
 *
 * The same Rooms list as inside a lesson — the default chatroom and every
 * private chat — for reading and answering outside a lesson. /messages/:id
 * opens one chat directly, so a link to a conversation works.
 *
 * Blocking for a lesson is not offered here: it belongs to a running lesson.
 * New private chats start from a person in a lesson.
 */
export default function MessagesPage() {
  const { http, chatSocket, session } = useCore();
  const { conversationId } = useParams();
  const navigate = useNavigate();

  const api = useMemo(() => createChatApi(http), [http]);
  const self = useMemo(
    () => ({
      userId: session?.userId ?? '',
      displayName: session?.displayName ?? 'You',
      avatarUrl: session?.avatarUrl ?? null,
    }),
    [session],
  );

  const rooms = useConversations({
    api,
    socket: chatSocket ?? undefined,
    selfUserId: self.userId,
    enabled: Boolean(self.userId),
  });

  const [view, setView] = useState(conversationId ? { type: 'conversation', id: conversationId } : { type: 'list' });

  useEffect(() => {
    setView(conversationId ? { type: 'conversation', id: conversationId } : { type: 'list' });
  }, [conversationId]);

  const onViewChange = (next) => {
    setView(next);
    if (next.type === 'conversation') navigate(`/messages/${next.id}`);
    else if (conversationId) navigate('/messages');
  };

  return (
    <section className="page messages-page">
      <h1>Messages {rooms.unreadTotal > 0 ? <span className="rooms-badge">{rooms.unreadTotal}</span> : null}</h1>
      <ChatRooms rooms={rooms} view={view} onViewChange={onViewChange} api={api} socket={chatSocket} self={self} />
    </section>
  );
}
__P34_EOF__
echo "wrote apps/web/src/pages/MessagesPage.jsx"

cat > .part34-patch.mjs <<'__P34_EOF__'
import { readFileSync, writeFileSync } from 'node:fs';

const plan = [
  {
    file: 'server/src/messaging/DirectMessageService.js',
    marker: 'blockedInSessionCheck',
    edits: [
      {
        name: 'a lesson block also stops messages in an existing private chat',
        find:
          '      for (const other of others) {\n' +
          '        const { blocked } = await Block.areBlocked(userId, other.user_id);\n' +
          '        if (blocked) {\n',
        replace:
          '      // A block made in a running lesson counts the same as an account block.\n' +
          "      const { isBlockedEitherWay: blockedInSessionCheck } = await import('./SessionBlocks.js');\n" +
          '      for (const other of others) {\n' +
          '        const { blocked } = await Block.areBlocked(userId, other.user_id);\n' +
          '        if (blocked || (await blockedInSessionCheck(userId, other.user_id))) {\n',
      },
    ],
  },
  {
    file: 'server/src/classroom/RoomManager.js',
    marker: 'SessionBlocks.js',
    edits: [
      {
        name: 'a lesson that ends takes its lesson blocks with it',
        find: '  room.close(reason);\n  rooms.delete(roomId);\n',
        replace:
          '  room.close(reason);\n' +
          '  rooms.delete(roomId);\n' +
          '\n' +
          '  // Blocks made "for this lesson" end with the lesson.\n' +
          "  const { clearRoom } = await import('../messaging/SessionBlocks.js');\n" +
          '  await clearRoom(roomId).catch(() => undefined);\n',
      },
    ],
  },
  {
    file: 'packages/core-client/src/index.ts',
    marker: 'useConversations',
    edits: [
      {
        name: 'export useConversations',
        find: "export * from './state/useChat.js';\n",
        replace: "export * from './state/useChat.js';\nexport * from './state/useConversations.js';\n",
      },
    ],
  },
];

const results = [];
for (const entry of plan) {
  let src = readFileSync(entry.file, 'utf8');
  if (src.includes(entry.marker)) {
    console.log(`${entry.file}: already patched, nothing to do`);
    continue;
  }
  for (const edit of entry.edits) {
    const count = src.split(edit.find).length - 1;
    if (count !== 1) {
      console.error(`${entry.file}: "${edit.name}": expected the anchor exactly once, found ${count}. Nothing was changed in any patched file.`);
      process.exit(1);
    }
  }
  for (const edit of entry.edits) src = src.replace(edit.find, edit.replace);
  results.push({ ...entry, src });
}
for (const entry of results) {
  writeFileSync(entry.file, entry.src);
  console.log('patched', entry.file);
  for (const edit of entry.edits) console.log('  -', edit.name);
}
__P34_EOF__
node .part34-patch.mjs
rm -f .part34-patch.mjs

echo "--- checks"
ESBUILD=""
[ -x node_modules/.bin/esbuild ] && ESBUILD=node_modules/.bin/esbuild
for f in "${TOUCHED[@]}"; do
  case "$f" in
    *.js) node --check "$f" && echo "ok  $f" ;;
    *.ts) if [ -n "$ESBUILD" ]; then "$ESBUILD" "$f" --loader:.ts=ts --log-level=error >/dev/null && echo "ok  $f"; else echo "--  $f (no esbuild to check)"; fi ;;
    *.jsx) if [ -n "$ESBUILD" ]; then "$ESBUILD" "$f" --loader:.jsx=jsx --jsx=automatic --log-level=error >/dev/null && echo "ok  $f"; else echo "--  $f (no esbuild to check)"; fi ;;
    *) [ -f "$f" ] && echo "ok  $f" ;;
  esac
done
echo
echo "Parts 3 and 4 installed. The API and Vite pick the changes up on their own;"
echo "reload the browser tabs with Ctrl+Shift+R."