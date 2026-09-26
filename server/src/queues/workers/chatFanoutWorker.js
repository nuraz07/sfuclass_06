/**
 * chatFanoutWorker — who hears about a chat message  (F6 · Settings Phase B)
 *
 * The send path does the minimum: store the message, put it on everyone's
 * screen, count it unread (DirectMessageService). Deciding who else should
 * hear about it happens here, a beat later, so a slow push provider never
 * delays a message that is already visible.
 *
 * For each message:
 *
 *   recipients   a private chat: its participants, minus the author and
 *                anyone who muted it. A channel (the lesson's default
 *                chatroom): only people who opted in under Settings →
 *                Notifications, since the audience is the whole organisation.
 *                Mentioned people always count, unless a block stands between.
 *
 *   presence     looking at the app → nothing more (the badge moves).
 *                In a lesson → held for the summary afterwards, if they have
 *                focus on. Away or offline → a notification job, where the
 *                settings, quiet hours and dedupe decide the channels.
 *
 * The job loads the message itself, so the producer only needs its id, and a
 * message deleted before the job runs notifies nobody.
 */

import { defineWorker, enqueue, QUEUE_NAMES, PermanentJobError } from '../queues.js';
import { pool } from '../../db/pool.js';
import * as LiveState from '../../realtime/liveState.js';
import * as NotificationService from '../../community/NotificationService.js';
import * as Focus from '../../notifications/focus.js';

const handlers = {
  'chat.message.fanout': fanoutMessage,
  'chat.message.index': indexMessage,
  'chat.read.sync': syncRead,
};

export function createChatFanoutWorker() {
  return defineWorker(QUEUE_NAMES.CHAT, async (job, log) => {
    const handler = handlers[job.name];
    if (!handler) throw new PermanentJobError(`Unknown chat job: ${job.name}`);
    return handler(job, log);
  });
}

/* ------------------------------------------------------------------ *
 * Loading
 * ------------------------------------------------------------------ */

const loadMessage = async (messageId) => {
  const { rows } = await pool.query(
    `SELECT m.message_id, m.author_id, m.body, m.mentions, m.conversation_id, m.channel_id,
            m.deleted_at, u.display_name AS author_name, ch.name AS channel_name
       FROM messages m
       JOIN users u ON u.id = m.author_id
       LEFT JOIN channels ch ON ch.channel_id = m.channel_id
      WHERE m.message_id = $1`,
    [messageId],
  );
  return rows[0] ?? null;
};

/** The other people in a private chat who have not left it or muted it. */
const conversationRecipients = async (conversationId, authorId) => {
  const { rows } = await pool.query(
    `SELECT cp.user_id
       FROM conversation_participants cp
       JOIN users u ON u.id = cp.user_id AND u.deleted_at IS NULL
      WHERE cp.conversation_id = $1
        AND cp.user_id <> $2
        AND cp.left_at IS NULL
        AND NOT (coalesce(cp.muted, false) AND (cp.muted_until IS NULL OR cp.muted_until > now()))`,
    [conversationId, authorId],
  );
  return rows.map((row) => row.user_id);
};

/** People who asked to hear about the channel, minus mutes and blocks. */
const channelOptIns = async (channelId, authorId) => {
  const { rows } = await pool.query(
    `SELECT np.user_id
       FROM notification_preferences np
       JOIN users u ON u.id = np.user_id AND u.deleted_at IS NULL AND u.status = 'active'
       JOIN channels ch ON ch.channel_id = $1 AND ch.archived_at IS NULL AND ch.tenant_id = u.tenant_id
      WHERE np.user_id <> $2
        AND (coalesce((np.channels -> 'channelMessages' ->> 'inApp')::boolean, false)
          OR coalesce((np.channels -> 'channelMessages' ->> 'push')::boolean, false)
          OR coalesce((np.channels -> 'channelMessages' ->> 'email')::boolean, false))
        AND NOT EXISTS (SELECT 1 FROM channel_members cm
                         WHERE cm.channel_id = $1 AND cm.user_id = np.user_id AND cm.muted
                           AND (cm.muted_until IS NULL OR cm.muted_until > now()))
        AND NOT EXISTS (SELECT 1 FROM blocks b
                         WHERE (b.user_id = np.user_id AND b.blocked_id = $2)
                            OR (b.user_id = $2 AND b.blocked_id = np.user_id))
        AND (ch.scope = 'public'
          OR (ch.scope = 'space' AND EXISTS (SELECT 1 FROM space_memberships s
                                              WHERE s.space_id = ch.scope_ref_id AND s.user_id = np.user_id))
          OR (ch.scope = 'course' AND EXISTS (SELECT 1 FROM enrollments e
                                               WHERE e.course_id = ch.scope_ref_id AND e.user_id = np.user_id
                                                 AND e.status = 'active')))
      LIMIT 5000`,
    [channelId, authorId],
  );
  return rows.map((row) => row.user_id);
};

/** Mentioned people the author is not blocked with, either way. */
const unblocked = async (authorId, userIds) => {
  if (userIds.length === 0) return [];
  const { rows } = await pool.query(
    `SELECT DISTINCT CASE WHEN user_id = $1 THEN blocked_id ELSE user_id END AS other
       FROM blocks
      WHERE (user_id = $1 AND blocked_id = ANY($2::uuid[]))
         OR (blocked_id = $1 AND user_id = ANY($2::uuid[]))`,
    [authorId, userIds],
  );
  const blocked = new Set(rows.map((row) => row.other));
  return userIds.filter((id) => !blocked.has(id));
};

/** 'in-class', 'online' or 'offline', from the presence gateway (realtime/liveState.js). */
const presenceOf = (userId) => LiveState.stateOf(userId);

const preview = (text) => {
  const value = String(text ?? '').replace(/\s+/g, ' ').trim();
  return value.length > 160 ? `${value.slice(0, 159)}…` : value || 'Sent an attachment';
};

/* ------------------------------------------------------------------ *
 * Fan-out
 * ------------------------------------------------------------------ */

async function fanoutMessage(job, log) {
  // The producer's payload has changed shape over time; accept every one of them.
  const messageId =
    job.data?.messageId ?? job.data?.message?.messageId ?? job.data?.message?.id ?? job.data?.id ?? null;
  if (!messageId) throw new PermanentJobError('chat fan-out needs a messageId');

  const message = await loadMessage(messageId);
  if (!message || message.deleted_at) return { skipped: 'message gone' };
  if (!message.conversation_id && !message.channel_id) return { skipped: 'lesson chat' };

  const authorId = message.author_id;
  const sender = message.author_name ?? 'Someone';
  const conversationId = message.conversation_id ?? null;
  const channelId = message.channel_id ?? null;
  const url = conversationId ? `/messages/${conversationId}` : '/messages';

  const recipients = conversationId
    ? await conversationRecipients(conversationId, authorId)
    : await channelOptIns(channelId, authorId);

  const mentioned = await unblocked(
    authorId,
    [...new Set((message.mentions ?? []).map(String))].filter((id) => id !== authorId),
  );
  const mentionSet = new Set(mentioned);

  const away = { message: [], mention: [] };
  let looking = 0;
  let held = 0;

  for (const userId of new Set([...recipients, ...mentioned])) {
    const type = mentionSet.has(userId) ? 'mention' : 'message';
    const presence = await presenceOf(userId);

    if (presence === 'in-class') {
      const settings = await NotificationService.getSettings(userId);
      const category = type === 'mention' ? 'mentions' : conversationId ? 'directMessages' : 'channelMessages';
      const anyChannel = Object.values(settings.categories[category]).some(Boolean);
      if (settings.focusDuringLessons && anyChannel) {
        await Focus.hold(userId, { type, from: sender, conversationId, channelId });
        held += 1;
      }
      continue;
    }

    if (presence === 'online') {
      looking += 1;
      continue;
    }

    away[type].push(userId);
  }

  const data = { conversationId, channelId, messageId, from: sender };

  if (away.message.length > 0) {
    await enqueue(
      QUEUE_NAMES.NOTIFY,
      'notification.fanout',
      {
        kind: conversationId ? 'chat.direct.message' : 'chat.channel.message',
        recipientIds: away.message,
        actorId: authorId,
        title: conversationId ? sender : `${sender} in # ${message.channel_name ?? 'chat'}`,
        body: preview(message.body),
        url,
        // Three messages in two minutes are one push, not three.
        dedupeKey: `chat:${conversationId ?? channelId}`,
        channels: ['in-app', 'push', 'email'],
        data,
      },
      { jobId: `chat-push:${messageId}` },
    );
  }

  if (away.mention.length > 0) {
    await enqueue(
      QUEUE_NAMES.NOTIFY,
      'notification.fanout',
      {
        kind: 'chat.mention',
        recipientIds: away.mention,
        actorId: authorId,
        title: `${sender} mentioned you`,
        body: preview(message.body),
        url,
        dedupeKey: `mention:${messageId}`,
        channels: ['in-app', 'push', 'email'],
        data,
      },
      { jobId: `chat-mention:${messageId}` },
    );
  }

  const outcome = {
    recipients: recipients.length,
    mentioned: mentioned.length,
    looking,
    held,
    notified: away.message.length + away.mention.length,
  };
  log.debug({ messageId, ...outcome }, 'chat: fan-out done');
  return outcome;
}

/* ------------------------------------------------------------------ *
 * Search index and read sync — run only where their services exist
 * ------------------------------------------------------------------ */

async function indexMessage(job, log) {
  const Search = await import('../../messaging/ChatSearchService.js');
  const message = await loadMessage(job.data?.messageId ?? job.data?.message?.messageId);
  if (!message || message.deleted_at) {
    const remove = Search.removeFromIndex ?? Search.remove;
    if (typeof remove === 'function') await remove(job.data.messageId);
    return { removed: true };
  }
  const index = Search.indexMessage ?? Search.index;
  if (typeof index !== 'function') {
    log.debug('chat: no search index configured');
    return { skipped: 'no index' };
  }
  await index({
    messageId: message.message_id,
    authorId: message.author_id,
    body: message.body,
    target: message.conversation_id
      ? { kind: 'conversation', conversationId: message.conversation_id }
      : { kind: 'channel', channelId: message.channel_id },
  });
  return { indexed: true };
}

async function syncRead(job) {
  const { scopeId, userId } = job.data;
  const Unread = await import('../../messaging/UnreadService.js');
  if (typeof Unread.rebuild === 'function' && userId) await Unread.rebuild({ userId });
  return { synced: true, scopeId };
}

export default createChatFanoutWorker;
