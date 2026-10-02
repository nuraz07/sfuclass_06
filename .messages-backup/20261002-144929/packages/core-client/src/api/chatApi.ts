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
