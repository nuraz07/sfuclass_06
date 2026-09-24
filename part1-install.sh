#!/usr/bin/env bash
# part1-install.sh — Part 1 of the chat rework (backend foundation).
#
# Run from the project folder (the one containing server/ and apps/):
#   bash part1-install.sh
#
# Writes 7 files, patches 2 more, keeps a backup of every file it touches in
# .part1-backup/<timestamp>/ and checks the syntax of all of them at the end.
# Undo: bash part1-install.sh --restore
set -euo pipefail

if [ ! -d server/src/messaging ] || [ ! -d server/src/db/migrations ]; then
  echo "Run this from the project folder (the one that contains server/ and apps/)." >&2
  exit 1
fi

TOUCHED=(
  server/src/db/migrations/020_conversation_participant_state.sql
  server/src/messaging/models/Conversation.js
  server/src/messaging/models/Participant.js
  server/src/messaging/ConversationService.js
  server/src/routes/messaging.routes.js
  server/src/identity/Profile.js
  server/src/routes/profile.routes.js
  server/src/messaging/chatGateway.js
  server/src/messaging/DirectMessageService.js
)

if [ "${1:-}" = "--restore" ]; then
  # The oldest backup is the state before Part 1 was first installed.
  LAST=$(ls -1d .part1-backup/* 2>/dev/null | head -1 || true)
  [ -n "$LAST" ] || { echo "No backup found." >&2; exit 1; }
  for f in "${TOUCHED[@]}"; do
    if [ -f "$LAST/$f" ]; then mkdir -p "$(dirname "$f")"; cp "$LAST/$f" "$f"; echo "restored $f";
    elif [ -f "$f" ] && [ "$f" = "server/src/db/migrations/020_conversation_participant_state.sql" ]; then rm "$f"; echo "removed $f"; fi
  done
  echo "Restored from $LAST. (A migration already applied to the database stays applied; it only adds columns.)"
  exit 0
fi

BACKUP=".part1-backup/$(date +%Y%m%d-%H%M%S)"
for f in "${TOUCHED[@]}"; do
  if [ -f "$f" ]; then mkdir -p "$BACKUP/$(dirname "$f")"; cp "$f" "$BACKUP/$f"; fi
done
echo "backup: $BACKUP"

cat > server/src/db/migrations/020_conversation_participant_state.sql <<'__P1_EOF__'
-- 020_conversation_participant_state.sql
--
-- Per-person state of a conversation, and the duplicate guard for direct
-- messages. Additive only: no existing row changes meaning.
--
--   muted_until   a mute that ends by itself (1 h, 8 h, 1 day). `muted` stays the
--                 switch; a mute with muted_until in the past counts as off.
--   hidden_at     "deleted for me": the conversation is gone from this person's
--                 list. A new message in it clears the marker, so it comes back.
--   cleared_at    where this person's history starts after a delete. Messages
--                 at or before it stay hidden from them, also after it comes
--                 back; the other side keeps everything.
--
-- conversations.updated_at is read by the conversation model and by the
-- contract's timestamps; it did not exist.
--
-- participant_key: the unique index (tenant_id, participant_key) was already
-- there to guarantee one direct conversation per pair of people, but nothing
-- ever filled the key in. Existing direct conversations get it here — the
-- oldest one per pair only, so a pair that already has duplicates cannot make
-- this migration fail; the newer duplicates simply stay unkeyed.

alter table conversation_participants add column if not exists muted_until timestamptz;
alter table conversation_participants add column if not exists hidden_at   timestamptz;
alter table conversation_participants add column if not exists cleared_at  timestamptz;

alter table conversations add column if not exists updated_at timestamptz not null default now();

with pairs as (
  select cp.conversation_id,
         string_agg(cp.user_id::text, ':' order by cp.user_id) as pair_key,
         count(*) as members
    from conversation_participants cp
    join conversations c on c.id = cp.conversation_id
   where c.kind = 'direct'
     and c.participant_key is null
   group by cp.conversation_id
),
ranked as (
  select p.conversation_id,
         p.pair_key,
         c.tenant_id,
         row_number() over (partition by c.tenant_id, p.pair_key order by c.created_at, c.id) as rn
    from pairs p
    join conversations c on c.id = p.conversation_id
   where p.members = 2
)
update conversations c
   set participant_key = r.pair_key
  from ranked r
 where c.id = r.conversation_id
   and r.rn = 1
   and not exists (
         select 1 from conversations x
          where x.tenant_id = r.tenant_id and x.participant_key = r.pair_key
       );

-- The conversation list: someone's visible threads.
create index if not exists conversation_participants_visible_idx
    on conversation_participants (user_id)
 where left_at is null and hidden_at is null;
__P1_EOF__
echo "wrote server/src/db/migrations/020_conversation_participant_state.sql"

cat > server/src/messaging/models/Conversation.js <<'__P1_EOF__'
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
__P1_EOF__
echo "wrote server/src/messaging/models/Conversation.js"

cat > server/src/messaging/models/Participant.js <<'__P1_EOF__'
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

export const setChannelMuted = async ({ channelId, userId, muted }) => {
  await pool.query(
    `INSERT INTO channel_members (channel_id, user_id, muted)
     VALUES ($1, $2, $3)
     ON CONFLICT (channel_id, user_id) DO UPDATE SET muted = EXCLUDED.muted`,
    [channelId, userId, muted],
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
__P1_EOF__
echo "wrote server/src/messaging/models/Participant.js"

cat > server/src/messaging/ConversationService.js <<'__P1_EOF__'
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
__P1_EOF__
echo "wrote server/src/messaging/ConversationService.js"

cat > server/src/routes/messaging.routes.js <<'__P1_EOF__'
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
__P1_EOF__
echo "wrote server/src/routes/messaging.routes.js"

cat > server/src/identity/Profile.js <<'__P1_EOF__'
// classroom-app/server/src/identity/Profile.js
/**
 * Profiles  (F6)
 *
 * What a person shows to other people, and who is allowed to contact them.
 *
 * Separate from User.js because the two are read by different things at
 * different rates: the account is read by the auth path, the profile every time
 * anybody renders an avatar.
 *
 * Storage (009_profiles.sql): privacy lives in named columns, not in a jsonb
 * blob, because visibility and dm_policy carry check constraints —
 *
 *   dm_policy            anyone | shared-only | nobody
 *   visibility           tenant | shared-only | private
 *   show_presence        boolean
 *   show_read_receipts   boolean
 *
 * The contract spells the middle DM setting 'shared-context'; it is mapped at
 * this boundary in both directions. Display name and email live on `users`,
 * the avatar is `profiles.avatar_asset_id`. Blocks are `blocks(user_id,
 * blocked_id)`.
 *
 * Whether someone may message someone else is decided in exactly one place,
 * messaging/ConversationService.canMessage. profile.routes asks it and puts the
 * answer on the public profile, so the button and the send always agree.
 */

import { pool } from '../db/pool.js';
import { logger } from '../observability/logger.js';

const log = logger.child({ component: 'profiles' });

export const DM_POLICIES = ['anyone', 'shared-context', 'nobody'];

const TO_CONTRACT = { anyone: 'anyone', 'shared-only': 'shared-context', nobody: 'nobody' };
const TO_DB = { anyone: 'anyone', 'shared-context': 'shared-only', shared: 'shared-only', 'shared-only': 'shared-only', nobody: 'nobody' };

/** Privacy fields the contract has that the table does not store: fixed values. */
const FIXED_PRIVACY = { showEmail: 'nobody', showCourses: 'members', discoverable: true };

const DEFAULT_NOTIFICATIONS = {
  dmPush: true,
  dmEmail: false,
  mentionPush: true,
  communityDigest: true,
  lessonReminders: true,
  quietHours: null,
};

const iso = (value) => (value ? new Date(value).toISOString() : null);

// ---------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------

const privacyOf = (row) => ({
  ...FIXED_PRIVACY,
  dmPolicy: TO_CONTRACT[row.dm_policy] ?? 'shared-context',
  showPresence: row.show_presence !== false,
  sendReadReceipts: row.show_read_receipts !== false,
  visibility: row.visibility ?? 'tenant',
});

const rowToPublic = (row) => ({
  userId: row.user_id,
  displayName: row.display_name,
  handle: row.handle,
  avatarUrl: null,
  headline: row.headline ?? null,
  bio: row.bio ?? null,
  links: row.links ?? [],
  role: row.role,
  presence: 'offline', // filled in from Redis by the caller
  lastSeenAt: iso(row.last_seen_at),
  canMessage: false, // computed per viewer by profile.routes
  isBlockedByViewer: false,
  sharedSpaceCount: 0,
  joinedAt: iso(row.created_at),
});

const rowToOwn = (row) => ({
  ...rowToPublic(row),
  canMessage: undefined,
  isBlockedByViewer: undefined,
  sharedSpaceCount: undefined,
  email: row.email,
  emailVerified: Boolean(row.email_verified),
  locale: row.locale,
  timeZone: row.time_zone,
  privacy: privacyOf(row),
  notifications: { ...DEFAULT_NOTIFICATIONS },
  createdAt: iso(row.created_at),
  updatedAt: iso(row.updated_at ?? row.created_at),
});

const SELECT = `
  SELECT p.*, u.email, (u.email_verified_at IS NOT NULL) AS email_verified, u.display_name,
         u.role, u.locale, u.time_zone, u.created_at, u.last_seen_at
    FROM profiles p JOIN users u ON u.id = p.user_id
`;

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

export const getOwn = async (userId) => {
  const { rows } = await pool.query(`${SELECT} WHERE p.user_id = $1`, [userId]);
  return rows[0] ? rowToOwn(rows[0]) : null;
};

/**
 * The public view for one viewer: block state and shared spaces in one query.
 * `canMessage` is left false here; profile.routes fills it from
 * ConversationService.canMessage.
 */
export const getPublic = async ({ userId, viewerId }) => {
  const { rows } = await pool.query(
    `${SELECT}
      WHERE p.user_id = $1 AND u.deleted_at IS NULL`,
    [userId],
  );
  const row = rows[0];
  if (!row) return null;

  const { rows: ctx } = await pool.query(
    `SELECT EXISTS (SELECT 1 FROM blocks b WHERE b.user_id = $2 AND b.blocked_id = $1) AS blocked_by_viewer`,
    [userId, viewerId],
  );

  let sharedSpaces = 0;
  try {
    const { rows: shared } = await pool.query(
      `SELECT count(*)::int AS n
         FROM space_memberships a
         JOIN space_memberships b ON b.space_id = a.space_id
        WHERE a.user_id = $1 AND b.user_id = $2`,
      [viewerId, userId],
    );
    sharedSpaces = shared[0]?.n ?? 0;
  } catch (cause) {
    log.warn({ err: cause }, 'shared space count unavailable');
  }

  return {
    ...rowToPublic(row),
    isBlockedByViewer: Boolean(ctx[0]?.blocked_by_viewer),
    sharedSpaceCount: sharedSpaces,
    // Presence is hidden when they have switched it off, never inflated.
    presence: 'offline',
  };
};

export const getByHandle = async ({ handle, viewerId }) => {
  const { rows } = await pool.query(`SELECT user_id FROM profiles WHERE handle = lower($1)`, [handle]);
  return rows[0] ? getPublic({ userId: rows[0].user_id, viewerId }) : null;
};

/**
 * Mention autocomplete. Never returns someone the viewer is blocked with in
 * either direction.
 */
export const search = async ({ q, viewerId, scopeId = null, limit = 10 }) => {
  const { rows } = await pool.query(
    `SELECT p.user_id, p.handle, u.display_name
       FROM profiles p JOIN users u ON u.id = p.user_id
      WHERE u.status = 'active'
        AND u.deleted_at IS NULL
        AND p.user_id <> $2
        AND u.tenant_id = (SELECT tenant_id FROM users WHERE id = $2)
        AND (p.handle ILIKE $1 || '%' OR u.display_name ILIKE '%' || $1 || '%')
        AND NOT EXISTS (SELECT 1 FROM blocks b
                         WHERE (b.user_id = $2 AND b.blocked_id = p.user_id)
                            OR (b.user_id = p.user_id AND b.blocked_id = $2))
        AND ($3::uuid IS NULL OR EXISTS (
              SELECT 1 FROM space_memberships m
               WHERE m.space_id = $3 AND m.user_id = p.user_id))
      ORDER BY (p.handle ILIKE $1 || '%') DESC, u.display_name ASC
      LIMIT $4`,
    [q, viewerId, scopeId, limit],
  );

  return {
    items: rows.map((row) => ({
      userId: row.user_id,
      handle: row.handle,
      displayName: row.display_name,
      avatarUrl: null,
      presence: 'offline',
    })),
  };
};

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

export const createForUser = async ({ userId, displayName }) => {
  const handle = await uniqueHandle(displayName);
  await pool.query(
    `INSERT INTO profiles (user_id, handle) VALUES ($1, $2) ON CONFLICT (user_id) DO NOTHING`,
    [userId, handle],
  );
  return getOwn(userId);
};

const slugifyHandle = (name) =>
  String(name ?? '')
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[^a-z0-9_]/g, '')
    .slice(0, 24) || 'user';

const uniqueHandle = async (displayName) => {
  const base = slugifyHandle(displayName);
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const candidate = attempt === 0 ? base : `${base}${Math.floor(Math.random() * 9_000) + 1_000}`;
    const { rows } = await pool.query(`SELECT 1 FROM profiles WHERE handle = $1`, [candidate]);
    if (rows.length === 0) return candidate;
  }
  return `${base}${Date.now().toString(36)}`;
};

export const update = async ({ userId, patch }) => {
  // display_name lives on the user row; the rest on the profile.
  if (patch.displayName !== undefined) {
    const Users = await import('./User.js');
    await Users.update({ userId, patch: { displayName: patch.displayName } });
  }

  const columns = { handle: 'handle', headline: 'headline', bio: 'bio', links: 'links' };
  const sets = [];
  const params = [];

  for (const [key, column] of Object.entries(columns)) {
    if (patch[key] === undefined) continue;
    params.push(key === 'links' ? JSON.stringify(patch[key]) : patch[key]);
    sets.push(`${column} = $${params.length}${key === 'links' ? '::jsonb' : ''}`);
  }

  if (patch.handle !== undefined) {
    const { rows } = await pool.query(
      `SELECT 1 FROM profiles WHERE handle = lower($1) AND user_id <> $2`,
      [patch.handle, userId],
    );
    if (rows.length > 0) throw Object.assign(new Error('that handle is taken'), { code: 'conflict' });
  }

  if (sets.length > 0) {
    params.push(userId);
    await pool.query(
      `UPDATE profiles SET ${sets.join(', ')}, updated_at = now() WHERE user_id = $${params.length}`,
      params,
    );
  }

  return getOwn(userId);
};

/**
 * Writes the privacy columns. Accepts the contract's names (dmPolicy,
 * showPresence, sendReadReceipts, visibility) and returns the full privacy
 * block. "Receive private messages: off" is dmPolicy 'nobody'.
 */
export const updatePrivacy = async ({ userId, patch }) => {
  const sets = [];
  const params = [];
  const set = (column, value) => {
    params.push(value);
    sets.push(`${column} = $${params.length}`);
  };

  if (patch.dmPolicy !== undefined) {
    const policy = TO_DB[patch.dmPolicy];
    if (!policy) throw Object.assign(new Error('unknown DM setting'), { code: 'validation_failed' });
    set('dm_policy', policy);
  }
  if (patch.visibility !== undefined) set('visibility', patch.visibility === 'shared' ? 'shared-only' : patch.visibility);
  if (patch.showPresence !== undefined) set('show_presence', Boolean(patch.showPresence));
  if (patch.sendReadReceipts !== undefined) set('show_read_receipts', Boolean(patch.sendReadReceipts));
  if (patch.readReceipts !== undefined) set('show_read_receipts', Boolean(patch.readReceipts));

  if (sets.length > 0) {
    params.push(userId);
    await pool.query(
      `UPDATE profiles SET ${sets.join(', ')}, updated_at = now() WHERE user_id = $${params.length}`,
      params,
    );
  }

  const own = await getOwn(userId);
  return own?.privacy ?? null;
};

/** Notification preferences have no storage yet; the defaults are returned unchanged. */
export const updateNotifications = async () => ({ ...DEFAULT_NOTIFICATIONS });

export const setAvatar = async ({ userId, assetId }) => {
  const { getAssetsForOwner } = await import('../media/UploadService.js');
  const [asset] = await getAssetsForOwner({ assetIds: [assetId], userId });

  if (!asset) throw Object.assign(new Error('unknown image'), { code: 'not_found' });
  if (asset.status !== 'ready') {
    throw Object.assign(new Error('that image is still processing'), { code: 'asset_not_ready' });
  }

  await pool.query(`UPDATE profiles SET avatar_asset_id = $2, updated_at = now() WHERE user_id = $1`, [userId, assetId]);
  return getOwn(userId);
};

// ---------------------------------------------------------------------------
// Blocking (account-wide; the per-lesson block lives with the room)
// ---------------------------------------------------------------------------

/**
 * Mutual in effect: neither can message the other afterwards. Only the blocker
 * sees it in a list — telling somebody they have been blocked is how a block
 * becomes an escalation.
 */
export const block = async ({ userId, blockedUserId, reason = null }) => {
  if (userId === blockedUserId) {
    throw Object.assign(new Error('you cannot block yourself'), { code: 'validation_failed' });
  }

  await pool.query(
    `INSERT INTO blocks (user_id, blocked_id, reason)
     VALUES ($1, $2, $3) ON CONFLICT (user_id, blocked_id) DO NOTHING`,
    [userId, blockedUserId, reason],
  );

  log.info({ userId, blockedUserId }, 'user blocked');
  const { rows } = await pool.query(
    `SELECT b.blocked_id, b.reason, b.created_at, u.display_name
       FROM blocks b JOIN users u ON u.id = b.blocked_id
      WHERE b.user_id = $1 AND b.blocked_id = $2`,
    [userId, blockedUserId],
  );
  return toBlock(rows[0]);
};

export const unblock = async ({ userId, blockedUserId }) => {
  const { rowCount } = await pool.query(
    `DELETE FROM blocks WHERE user_id = $1 AND blocked_id = $2`,
    [userId, blockedUserId],
  );
  return rowCount > 0;
};

const toBlock = (row) => ({
  blockedUserId: row.blocked_id,
  blockedAt: iso(row.created_at),
  reason: row.reason ?? null,
  profile: { userId: row.blocked_id, displayName: row.display_name, avatarUrl: null },
});

export const listBlocks = async ({ userId, cursor = null, limit = 25 }) => {
  const params = [userId];
  let where = 'b.user_id = $1';

  if (cursor) {
    const [at, id] = Buffer.from(cursor, 'base64url').toString().split('|');
    params.push(at, id);
    where += ` AND (b.created_at, b.blocked_id) < ($2::timestamptz, $3::uuid)`;
  }
  params.push(limit + 1);

  const { rows } = await pool.query(
    `SELECT b.blocked_id, b.reason, b.created_at, u.display_name
       FROM blocks b JOIN users u ON u.id = b.blocked_id
      WHERE ${where} ORDER BY b.created_at DESC, b.blocked_id DESC LIMIT $${params.length}`,
    params,
  );

  const hasMore = rows.length > limit;
  const page = rows.slice(0, limit);
  const last = page.at(-1);

  return {
    items: page.map(toBlock),
    hasMore,
    nextCursor:
      hasMore && last
        ? Buffer.from(`${new Date(last.created_at).toISOString()}|${last.blocked_id}`).toString('base64url')
        : null,
  };
};

/** The check a send path can call. One query, either direction. */
export const isBlockedEitherWay = async ({ a, b }) => {
  const { rows } = await pool.query(
    `SELECT 1 FROM blocks
      WHERE (user_id = $1 AND blocked_id = $2)
         OR (user_id = $2 AND blocked_id = $1) LIMIT 1`,
    [a, b],
  );
  return rows.length > 0;
};

/**
 * The v6 pure rule, kept for callers that still import it. The rule that is
 * actually enforced is ConversationService.canMessage.
 */
export const canMessage = ({
  viewerId,
  targetId,
  dmPolicy = 'shared-context',
  blockedEitherWay = false,
  sharedContext = false,
  viewerIsModerator = false,
}) => {
  if (viewerId === targetId) return { allowed: false, reason: 'self' };
  if (blockedEitherWay) return { allowed: false, reason: 'blocked' };
  if (viewerIsModerator) return { allowed: true, reason: 'moderator' };
  if (dmPolicy === 'nobody') return { allowed: false, reason: 'dm_not_allowed' };
  if (dmPolicy === 'anyone') return { allowed: true };
  return sharedContext ? { allowed: true } : { allowed: false, reason: 'no_shared_context' };
};

export default {
  canMessage, getOwn, getPublic, getByHandle, search, createForUser, update,
  updatePrivacy, updateNotifications, setAvatar, block, unblock,
  listBlocks, isBlockedEitherWay,
};
__P1_EOF__
echo "wrote server/src/identity/Profile.js"

cat > server/src/routes/profile.routes.js <<'__P1_EOF__'
/**
 * profile.routes — own profile · privacy · other people · blocking (F6)
 *
 * Mounted under /profiles (app.js), so every path here is relative to it:
 * '/me' is GET /profiles/me. (The previous version repeated the prefix, which
 * made every route answer at /profiles/profiles/… and the client's calls 404.)
 *
 * A profile read is filtered by the viewer, and `canMessage` comes back
 * computed by ConversationService.canMessage — the same rule the send path
 * enforces — so the Message button and the send always agree. `roomId` in the
 * query lets that rule count a shared live lesson as shared context.
 *
 * Both the contract's paths (profileApi: PATCH /me/privacy, POST /me/blocks,
 * DELETE /me/blocks/:userId) and the older ones (PUT /me/privacy,
 * PUT|DELETE /:userId/block) are served, so no client breaks while it moves.
 */

import { Router } from 'express';
import { z } from 'zod';

import * as Profile from '../identity/Profile.js';
import * as ConversationService from '../messaging/ConversationService.js';
import * as ChatModerationService from '../messaging/ChatModerationService.js';
import * as UploadService from '../media/UploadService.js';
import { rateLimit } from '../middleware/rateLimit.js';
import { route, validate, requireAuth, tenantOf, q, notFound, badRequest } from './_helpers.js';

const router = Router();
router.use(requireAuth);

const userIdParam = z.object({ userId: z.string().uuid() });

/* ------------------------------------------------------------------ *
 * Own profile
 * ------------------------------------------------------------------ */

router.get(
  '/me',
  route(async (req) => {
    const own = await Profile.getOwn(req.user.id);
    if (!own) throw notFound('No profile for this account');
    return own;
  }),
);

router.patch(
  '/me',
  validate({
    body: z.object({
      displayName: z.string().min(1).max(80).optional(),
      handle: z.string().min(3).max(32).optional(),
      bio: z.string().max(2000).nullish(),
      headline: z.string().max(140).nullish(),
      avatarAssetId: z.string().uuid().nullish(),
      links: z.array(z.object({ label: z.string().max(40), url: z.string().url() })).max(5).optional(),
    }),
  }),
  route(async (req) => {
    const { avatarAssetId, ...patch } = req.body;
    if (avatarAssetId) await Profile.setAvatar({ userId: req.user.id, assetId: avatarAssetId });
    return Profile.update({ userId: req.user.id, patch });
  }),
);

/**
 * Who may message me, and what others see. "Receive private messages: off" is
 * dmPolicy 'nobody'; teachers of the tenant can still reach the person.
 */
const privacyBody = z.object({
  dmPolicy: z.enum(['anyone', 'shared-context', 'shared-only', 'shared', 'nobody']).optional(),
  visibility: z.enum(['tenant', 'shared-only', 'shared', 'private']).optional(),
  showPresence: z.boolean().optional(),
  sendReadReceipts: z.boolean().optional(),
  readReceipts: z.boolean().optional(),
});

const updatePrivacy = route(async (req) => Profile.updatePrivacy({ userId: req.user.id, patch: req.body }));
router.patch('/me/privacy', validate({ body: privacyBody }), updatePrivacy);
router.put('/me/privacy', validate({ body: privacyBody }), updatePrivacy);

router.get(
  '/me/privacy',
  route(async (req) => (await Profile.getOwn(req.user.id))?.privacy ?? null),
);

/** Avatar upload goes through the media presign flow like any other asset. */
router.post(
  '/me/avatar',
  validate({
    body: z.object({
      filename: z.string().min(1).max(255),
      contentType: z.enum(['image/jpeg', 'image/png', 'image/webp']),
      sizeBytes: z.number().int().min(1).max(10 * 1024 * 1024),
    }),
  }),
  route(async (req, res) => {
    res.status(201);
    return UploadService.createUpload({
      ownerId: req.user.id,
      purpose: 'avatar',
      fileName: req.body.filename,
      contentType: req.body.contentType,
      sizeBytes: req.body.sizeBytes,
    });
  }),
);

router.put(
  '/me/avatar',
  validate({ body: z.object({ assetId: z.string().uuid() }) }),
  route(async (req) => Profile.setAvatar({ userId: req.user.id, assetId: req.body.assetId })),
);

/* ------------------------------------------------------------------ *
 * Blocking (account-wide)
 * ------------------------------------------------------------------ */

router.get(
  '/me/blocks',
  validate({ query: z.object({ cursor: z.string().optional(), limit: z.coerce.number().int().min(1).max(100).optional() }) }),
  route(async (req) =>
    Profile.listBlocks({ userId: req.user.id, cursor: q(req).cursor ?? null, limit: q(req).limit ?? 25 }),
  ),
);

const block = async (req, blockedUserId, reason) => {
  if (blockedUserId === req.user.id) throw badRequest('You cannot block yourself');
  // Mutual in effect: neither side can message the other afterwards.
  return Profile.block({ userId: req.user.id, blockedUserId, reason: reason ?? null });
};

router.post(
  '/me/blocks',
  validate({ body: z.object({ userId: z.string().uuid(), reason: z.string().max(500).optional() }).passthrough() }),
  route(async (req, res) => {
    res.status(201);
    return block(req, req.body.userId, req.body.reason);
  }),
);

router.delete(
  '/me/blocks/:userId',
  validate({ params: userIdParam }),
  route(async (req) => {
    await Profile.unblock({ userId: req.user.id, blockedUserId: req.params.userId });
    return null;
  }),
);

router.put(
  '/:userId/block',
  validate({ params: userIdParam, body: z.object({ reason: z.string().max(500).optional() }).default({}) }),
  route(async (req) => block(req, req.params.userId, req.body?.reason)),
);

router.delete(
  '/:userId/block',
  validate({ params: userIdParam }),
  route(async (req) => {
    await Profile.unblock({ userId: req.user.id, blockedUserId: req.params.userId });
    return null;
  }),
);

/* ------------------------------------------------------------------ *
 * Other people
 * ------------------------------------------------------------------ */

/** Mention autocomplete and people search. */
const searchQuery = z.object({
  q: z.string().min(2).max(80),
  scopeId: z.string().uuid().optional(),
  spaceId: z.string().uuid().optional(),
  limit: z.coerce.number().int().min(1).max(25).optional(),
});

const search = route(async (req) =>
  Profile.search({
    q: q(req).q,
    viewerId: req.user.id,
    scopeId: q(req).scopeId ?? q(req).spaceId ?? null,
    limit: q(req).limit ?? 10,
  }),
);

router.get('/search', rateLimit({ key: 'profile:search', points: 60, durationSec: 60, by: ['user'] }), validate({ query: searchQuery }), search);
router.get('/', rateLimit({ key: 'profile:search', points: 60, durationSec: 60, by: ['user'] }), validate({ query: searchQuery }), search);

/**
 * Someone else's profile, as this viewer may see it. `canMessage` and the
 * reason are computed by the same rule the send path enforces.
 */
router.get(
  '/:userId',
  rateLimit({ key: 'profile:read', points: 300, durationSec: 300, by: ['user'] }),
  validate({ params: userIdParam, query: z.object({ roomId: z.string().uuid().optional() }).passthrough() }),
  route(async (req) => {
    const profile = await Profile.getPublic({ userId: req.params.userId, viewerId: req.user.id });
    if (!profile) throw notFound('No such profile');

    const messaging = await ConversationService.canMessage({
      fromUserId: req.user.id,
      toUserId: req.params.userId,
      roomId: q(req).roomId ?? null,
    });

    return {
      ...profile,
      canMessage: messaging.allowed,
      cannotMessageReason: messaging.allowed ? null : messaging.reason ?? null,
    };
  }),
);

/* ------------------------------------------------------------------ *
 * Reporting
 * ------------------------------------------------------------------ */

router.post(
  '/:userId/report',
  rateLimit({ key: 'profile:report', points: 20, durationSec: 3600, by: ['user'] }),
  validate({
    params: userIdParam,
    body: z.object({
      reason: z.enum(['spam', 'abuse', 'harassment', 'impersonation', 'nsfw', 'other']),
      note: z.string().max(2000).optional(),
      messageIds: z.array(z.string().uuid()).max(20).default([]),
    }),
  }),
  route(async (req, res) => {
    res.status(202);
    return ChatModerationService.reportUser({
      reporterId: req.user.id,
      reportedId: req.params.userId,
      tenantId: tenantOf(req),
      ...req.body,
    });
  }),
);

export default router;
__P1_EOF__
echo "wrote server/src/routes/profile.routes.js"

cat > .part1-patch.mjs <<'__P1_EOF__'
import { readFileSync, writeFileSync } from 'node:fs';

const files = {
  gateway: 'server/src/messaging/chatGateway.js',
  messages: 'server/src/messaging/DirectMessageService.js',
};

const plan = [
  {
    file: files.gateway,
    marker: 'socket.join(`u:${userId}`)',
    edits: [
      {
        name: 'every chat connection joins its personal room',
        find:
          "  namespace.on('connection', (socket) => {\n" +
          '    const { userId } = socket.data;\n' +
          "    log.debug({ userId, socketId: socket.id }, 'chat socket connected');\n",
        replace:
          "  namespace.on('connection', (socket) => {\n" +
          '    const { userId } = socket.data;\n' +
          "    log.debug({ userId, socketId: socket.id }, 'chat socket connected');\n" +
          '\n' +
          '    // Personal room: conversation list updates, new conversations and\n' +
          '    // unread counts are addressed to the person, not to a thread they may\n' +
          '    // not have opened yet. Every device of the user is in it.\n' +
          '    void socket.join(`u:${userId}`);\n',
      },
      {
        name: 'push one updated conversation row to a person',
        find: 'export const notifyUnreadChanged = ({ userId, summary, targets }) => {\n',
        replace:
          '/**\n' +
          ' * One conversation, as this person sees it (their unread count, their mute),\n' +
          ' * to every device of theirs. Drives the conversation list and its badges.\n' +
          ' */\n' +
          'export const notifyConversationUpdated = ({ userId, conversation }) => {\n' +
          '  if (!namespace) return false;\n' +
          '  namespace.to(`u:${userId}`).emit(SERVER.conversationUpdated, { conversation });\n' +
          '  return true;\n' +
          '};\n' +
          '\n' +
          'export const notifyUnreadChanged = ({ userId, summary, targets }) => {\n',
      },
    ],
  },
  {
    file: files.messages,
    marker: 'announceActivity',
    edits: [
      {
        name: 'history starts after "deleted for me" for that person only',
        find:
          '  const page = around\n' +
          '    ? await Message.listAround({ target, messageId: around, limit })\n' +
          '    : await Message.listByTarget({ target, cursor, limit, order });\n',
        replace:
          '  let page = around\n' +
          '    ? await Message.listAround({ target, messageId: around, limit })\n' +
          '    : await Message.listByTarget({ target, cursor, limit, order });\n' +
          '\n' +
          '  // "Deleted for me": this viewer\'s history restarts at cleared_at; the other\n' +
          '  // participants keep everything. Pages are newest-first, so once one row is\n' +
          '  // before the cut there is nothing older left for this viewer.\n' +
          "  if (target.kind === 'conversation') {\n" +
          '    const own = await Participant.state({ conversationId: target.conversationId, userId: viewerId });\n' +
          '    const cutoff = own?.cleared_at ? new Date(own.cleared_at).getTime() : null;\n' +
          '    if (cutoff !== null) {\n' +
          '      const kept = page.rows.filter((row) => new Date(row.created_at).getTime() > cutoff);\n' +
          '      if (kept.length !== page.rows.length) {\n' +
          "        page = order === 'asc'\n" +
          '          ? { ...page, rows: kept }\n' +
          '          : { ...page, rows: kept, hasMore: false, nextCursor: null };\n' +
          '      }\n' +
          '    }\n' +
          '  }\n',
      },
      {
        name: 'a new message updates every participant\'s conversation list',
        find:
          "  const { broadcastMessage } = await import('./chatGateway.js');\n" +
          '  broadcastMessage({ message, target });\n',
        replace:
          "  const { broadcastMessage } = await import('./chatGateway.js');\n" +
          '  broadcastMessage({ message, target });\n' +
          '\n' +
          '  // The thread may not be open anywhere: push the updated row (unread count,\n' +
          '  // preview, back from "deleted for me") to each participant\'s list.\n' +
          "  if (target.kind === 'conversation') {\n" +
          "    const { announceActivity } = await import('./ConversationService.js');\n" +
          '    await announceActivity({ conversationId: target.conversationId }).catch((cause) =>\n' +
          "      log.warn({ err: cause, conversationId: target.conversationId }, 'conversation list update failed'),\n" +
          '    );\n' +
          '  }\n',
      },
    ],
  },
];

let changed = 0;
for (const { file, marker, edits } of plan) {
  let src = readFileSync(file, 'utf8');
  if (src.includes(marker)) {
    console.log(`${file}: already patched, nothing to do`);
    continue;
  }
  for (const edit of edits) {
    const count = src.split(edit.find).length - 1;
    if (count !== 1) {
      console.error(`${file}: "${edit.name}": expected the anchor exactly once, found ${count}. Nothing was changed in any file.`);
      process.exit(1);
    }
  }
  for (const edit of edits) src = src.replace(edit.find, edit.replace);
  plan.find((p) => p.file === file).result = src;
  changed += 1;
}

for (const entry of plan) {
  if (!entry.result) continue;
  writeFileSync(entry.file, entry.result);
  console.log('patched', entry.file);
  for (const edit of entry.edits) console.log('  -', edit.name);
}
if (changed === 0) console.log('nothing to change');
__P1_EOF__
node .part1-patch.mjs
rm -f .part1-patch.mjs

echo "--- syntax check"
for f in "${TOUCHED[@]}"; do
  case "$f" in *.js) node --check "$f" && echo "ok  $f";; esac
done
echo
echo "Part 1 installed. Next: SERVICE_ROLE=api npm run db:migrate   (applies 020)"