/**
 * Community API  (Community, part 1)
 *
 * Spaces, membership, threads, questions and reports — and, since part 2,
 * knowledge cards, materials, a chat per space and the space's rooms.
 * Paths are the server's
 * (server/src/routes/hub.routes.js, mounted under /hub). Responses are
 * validated loosely (passthrough): the server shapes every view, including
 * who is shown as "Anonymous".
 */

import { z } from 'zod';
import type { HttpClient } from '../http/httpClient.js';

const Author = z
  .object({
    userId: z.string().nullable(),
    displayName: z.string(),
    anonymous: z.boolean().default(false),
    you: z.boolean().default(false),
    hiddenFromOthers: z.boolean().optional(),
    revealedToModerator: z.boolean().optional(),
  })
  .passthrough();
export type HubAuthor = z.infer<typeof Author>;

export const HubSpaceSchema = z
  .object({
    spaceId: z.string(),
    name: z.string(),
    description: z.string().nullable().default(null),
    kind: z.enum(['class', 'topic', 'study']),
    access: z.enum(['open', 'request', 'invite']),
    memberList: z.enum(['members', 'moderators']),
    joinQuestion: z.string().nullable().default(null),
    endsAt: z.string().nullable().default(null),
    emoji: z.string().nullable().default(null),
    tags: z.array(z.string()).default([]),
    courseId: z.string().nullable().default(null),
    memberCount: z.number().default(0),
    newActivity: z.number().default(0),
    openQuestions: z.number().default(0),
    lastActivityAt: z.string().nullable().default(null),
    myRole: z.string().nullable().default(null),
    myRequest: z.string().nullable().default(null),
    ended: z.boolean().default(false),
    view: z.enum(['full', 'preview', 'hidden']).optional(),
    me: z
      .object({
        role: z.string().nullable(),
        moderator: z.boolean(),
        postingBlocked: z.string().nullable(),
        timeoutUntil: z.string().nullable().default(null),
        request: z.string().nullable().default(null),
      })
      .passthrough()
      .optional(),
  })
  .passthrough();
export type HubSpace = z.infer<typeof HubSpaceSchema>;

export const HubThreadSummarySchema = z
  .object({
    threadId: z.string(),
    spaceId: z.string(),
    spaceName: z.string().optional(),
    spaceEmoji: z.string().nullable().optional(),
    title: z.string(),
    kind: z.enum(['discussion', 'question']),
    excerpt: z.string().default(''),
    author: Author,
    replies: z.number().default(0),
    answered: z.boolean().default(false),
    metoo: z.number().default(0),
    myMetoo: z.boolean().default(false),
    pinned: z.boolean().default(false),
    locked: z.boolean().default(false),
    createdAt: z.string().nullable(),
    lastPostAt: z.string().nullable(),
  })
  .passthrough();
export type HubThreadSummary = z.infer<typeof HubThreadSummarySchema>;

export const HubThreadSchema = HubThreadSummarySchema.extend({
  space: z.object({ spaceId: z.string(), name: z.string(), emoji: z.string().nullable(), kind: z.string() }).passthrough(),
  answeredPostId: z.string().nullable().default(null),
  posts: z.array(
    z
      .object({
        postId: z.string(),
        first: z.boolean(),
        body: z.string(),
        replyToId: z.string().nullable().default(null),
        createdAt: z.string().nullable(),
        editedAt: z.string().nullable().default(null),
        author: Author,
        answer: z.boolean().default(false),
        canRemove: z.boolean().default(false),
        hiddenSolution: z.boolean().default(false),
        folded: z.boolean().default(false),
      })
      .passthrough(),
  ),
  me: z
    .object({
      moderator: z.boolean(),
      canReply: z.boolean(),
      replyBlocked: z.string().nullable().default(null),
      canMarkAnswer: z.boolean(),
      canRemoveThread: z.boolean(),
      canMetoo: z.boolean(),
      canSaveCard: z.boolean().default(false),
    })
    .passthrough(),
}).passthrough();
export type HubThread = z.infer<typeof HubThreadSchema>;

const Items = <T extends z.ZodTypeAny>(item: T) => z.object({ items: z.array(item) }).passthrough();

const MembersSchema = z
  .object({
    listVisible: z.boolean(),
    count: z.number(),
    items: z.array(
      z
        .object({
          userId: z.string(),
          displayName: z.string(),
          role: z.string(),
          joinedAt: z.string().nullable(),
          you: z.boolean().default(false),
          timeoutUntil: z.string().nullable().optional(),
        })
        .passthrough(),
    ),
  })
  .passthrough();
export type HubMembers = z.infer<typeof MembersSchema>;

export const HubRoomSchema = z
  .object({
    code: z.string(),
    title: z.string(),
    hostName: z.string().nullable().default(null),
    startsAt: z.string(),
    endsAt: z.string(),
    phase: z.string(),
    dropIn: z.boolean().default(false),
    here: z.number().default(0),
    spaceId: z.string(),
    spaceName: z.string().optional(),
  })
  .passthrough();
export type HubRoom = z.infer<typeof HubRoomSchema>;

export const HubCardSchema = z
  .object({
    cardId: z.string(),
    spaceId: z.string(),
    threadId: z.string().nullable().default(null),
    postId: z.string().nullable().default(null),
    title: z.string(),
    body: z.string(),
    createdBy: z.string().nullable().default(null),
    createdAt: z.string().nullable(),
    updatedAt: z.string().nullable(),
  })
  .passthrough();
export type HubCard = z.infer<typeof HubCardSchema>;

export const HubMaterialSchema = z
  .object({
    materialId: z.string(),
    title: z.string(),
    url: z.string(),
    host: z.string().nullable().default(null),
    note: z.string().nullable().default(null),
    pinned: z.boolean().default(false),
    addedBy: z.string().nullable().default(null),
    createdAt: z.string().nullable(),
  })
  .passthrough();
export type HubMaterial = z.infer<typeof HubMaterialSchema>;

export const HubMessageSchema = z
  .object({
    messageId: z.string(),
    body: z.string(),
    author: z.object({ userId: z.string(), displayName: z.string(), you: z.boolean().default(false) }).passthrough(),
    createdAt: z.string().nullable(),
    cursor: z.string(),
    canRemove: z.boolean().default(false),
  })
  .passthrough();
export type HubMessage = z.infer<typeof HubMessageSchema>;

const ChatPageSchema = z
  .object({
    items: z.array(HubMessageSchema),
    nextCursor: z.string().nullable().default(null),
    postingBlocked: z.string().nullable().default(null),
  })
  .passthrough();

const HomeSchema = z
  .object({
    live: z.array(HubRoomSchema).default([]),
    spaces: z.array(HubSpaceSchema),
    recent: z.array(HubThreadSummarySchema),
    myThreads: z.array(HubThreadSummarySchema),
    openQuestions: z.number().default(0),
  })
  .passthrough();
export type HubHome = z.infer<typeof HomeSchema>;

const RequestSchema = z
  .object({ userId: z.string(), displayName: z.string(), answer: z.string().nullable().default(null), at: z.string().nullable() })
  .passthrough();
const ReportSchema = z
  .object({
    reportId: z.string(),
    targetType: z.string(),
    targetId: z.string(),
    reason: z.string(),
    note: z.string().nullable().default(null),
    threadId: z.string().nullable().default(null),
    threadTitle: z.string().nullable().default(null),
    excerpt: z.string().nullable().default(null),
    targetName: z.string().nullable().default(null),
    at: z.string().nullable(),
  })
  .passthrough();
export type HubReport = z.infer<typeof ReportSchema>;

export interface NewSpaceInput {
  name: string;
  description?: string | null;
  kind: 'class' | 'topic' | 'study';
  access: 'open' | 'request' | 'invite';
  memberList: 'members' | 'moderators';
  joinQuestion?: string | null;
  endsAt?: string | null;
  emoji?: string | null;
  tags?: string[];
}

export interface HubApi {
  home(signal?: AbortSignal): Promise<HubHome>;
  questions(query?: { filter?: 'unanswered' | 'answered' | 'all'; sort?: 'metoo' | 'new' }, signal?: AbortSignal): Promise<{ items: HubThreadSummary[] }>;
  spaces(query?: { scope?: 'mine' | 'discover'; q?: string; kind?: string }, signal?: AbortSignal): Promise<{ items: HubSpace[] }>;
  createSpace(input: NewSpaceInput): Promise<HubSpace>;
  space(spaceId: string, signal?: AbortSignal): Promise<HubSpace>;
  updateSpace(spaceId: string, patch: Partial<NewSpaceInput>): Promise<HubSpace>;
  archiveSpace(spaceId: string): Promise<unknown>;
  join(spaceId: string, answer?: string | null): Promise<HubSpace>;
  leave(spaceId: string): Promise<unknown>;
  requests(spaceId: string, signal?: AbortSignal): Promise<{ items: z.infer<typeof RequestSchema>[] }>;
  decide(spaceId: string, userId: string, approve: boolean): Promise<unknown>;
  invite(spaceId: string, userIds: string[]): Promise<{ added: number }>;
  members(spaceId: string, signal?: AbortSignal): Promise<HubMembers>;
  updateMember(spaceId: string, userId: string, patch: { role?: string; timeoutMinutes?: number }): Promise<unknown>;
  removeMember(spaceId: string, userId: string): Promise<unknown>;
  threads(spaceId: string, filter?: 'all' | 'questions' | 'unanswered', signal?: AbortSignal): Promise<{ items: HubThreadSummary[] }>;
  createThread(spaceId: string, input: { title: string; body: string; kind: 'discussion' | 'question'; anonymous?: boolean }): Promise<HubThread>;
  thread(threadId: string, signal?: AbortSignal): Promise<HubThread>;
  reply(threadId: string, body: string, replyToId?: string | null, hiddenSolution?: boolean): Promise<HubThread>;
  markAnswer(threadId: string, postId: string | null): Promise<HubThread>;
  metoo(threadId: string): Promise<HubThread>;
  moderateThread(threadId: string, patch: { pinned?: boolean; locked?: boolean }): Promise<HubThread>;
  removeThread(threadId: string): Promise<{ removed: boolean; spaceId: string }>;
  removePost(postId: string): Promise<HubThread>;
  report(spaceId: string, input: { targetType: 'thread' | 'post' | 'user'; targetId: string; reason: string; note?: string | null }): Promise<unknown>;
  reports(spaceId: string, signal?: AbortSignal): Promise<{ items: HubReport[] }>;
  resolveReport(spaceId: string, reportId: string, action: 'remove' | 'dismiss'): Promise<unknown>;
  // Part 2
  cards(spaceId: string, q?: string, signal?: AbortSignal): Promise<{ items: HubCard[]; canCurate: boolean }>;
  createCard(spaceId: string, input: { title: string; body: string; postId?: string | null }): Promise<HubCard>;
  updateCard(cardId: string, patch: { title?: string; body?: string }): Promise<HubCard>;
  removeCard(cardId: string): Promise<unknown>;
  materials(spaceId: string, signal?: AbortSignal): Promise<{ items: HubMaterial[]; canCurate: boolean }>;
  addMaterial(spaceId: string, input: { title: string; url: string; note?: string | null; pinned?: boolean }): Promise<HubMaterial>;
  pinMaterial(materialId: string, pinned: boolean): Promise<HubMaterial>;
  removeMaterial(materialId: string): Promise<unknown>;
  chat(spaceId: string, after?: string | null, signal?: AbortSignal): Promise<z.infer<typeof ChatPageSchema>>;
  sendChat(spaceId: string, body: string): Promise<HubMessage>;
  removeChat(messageId: string): Promise<unknown>;
  rooms(spaceId: string, signal?: AbortSignal): Promise<{ items: HubRoom[] }>;
  dropIn(spaceId: string): Promise<{ room: HubRoom; started: boolean }>;
}

const enc = encodeURIComponent;
const once = { retry: { attempts: 1 } };

export const createHubApi = (http: HttpClient): HubApi => ({
  home: (signal) => http.get('/hub/home', { schema: HomeSchema, signal }),
  questions: (query = {}, signal) => http.get('/hub/questions', { schema: Items(HubThreadSummarySchema), query, signal }),
  spaces: (query = {}, signal) => http.get('/hub/spaces', { schema: Items(HubSpaceSchema), query, signal }),
  createSpace: (input) => http.post('/hub/spaces', input, { schema: HubSpaceSchema, ...once }),
  space: (spaceId, signal) => http.get(`/hub/spaces/${enc(spaceId)}`, { schema: HubSpaceSchema, signal }),
  updateSpace: (spaceId, patch) => http.patch(`/hub/spaces/${enc(spaceId)}`, patch, { schema: HubSpaceSchema }),
  archiveSpace: (spaceId) => http.post(`/hub/spaces/${enc(spaceId)}/archive`, {}, once),
  join: (spaceId, answer = null) => http.post(`/hub/spaces/${enc(spaceId)}/join`, { answer }, { schema: HubSpaceSchema, ...once }),
  leave: (spaceId) => http.post(`/hub/spaces/${enc(spaceId)}/leave`, {}, once),
  requests: (spaceId, signal) => http.get(`/hub/spaces/${enc(spaceId)}/requests`, { schema: Items(RequestSchema), signal }),
  decide: (spaceId, userId, approve) => http.post(`/hub/spaces/${enc(spaceId)}/requests/${enc(userId)}`, { approve }, once),
  invite: (spaceId, userIds) =>
    http.post(`/hub/spaces/${enc(spaceId)}/invite`, { userIds }, { schema: z.object({ added: z.number() }).passthrough(), ...once }),
  members: (spaceId, signal) => http.get(`/hub/spaces/${enc(spaceId)}/members`, { schema: MembersSchema, signal }),
  updateMember: (spaceId, userId, patch) => http.patch(`/hub/spaces/${enc(spaceId)}/members/${enc(userId)}`, patch),
  removeMember: (spaceId, userId) => http.delete(`/hub/spaces/${enc(spaceId)}/members/${enc(userId)}`),
  threads: (spaceId, filter = 'all', signal) =>
    http.get(`/hub/spaces/${enc(spaceId)}/threads`, { schema: Items(HubThreadSummarySchema), query: { filter }, signal }),
  createThread: (spaceId, input) => http.post(`/hub/spaces/${enc(spaceId)}/threads`, input, { schema: HubThreadSchema, ...once }),
  thread: (threadId, signal) => http.get(`/hub/threads/${enc(threadId)}`, { schema: HubThreadSchema, signal }),
  reply: (threadId, body, replyToId = null, hiddenSolution = false) =>
    http.post(`/hub/threads/${enc(threadId)}/replies`, { body, replyToId, hiddenSolution }, { schema: HubThreadSchema, ...once }),
  markAnswer: (threadId, postId) => http.post(`/hub/threads/${enc(threadId)}/answer`, { postId }, { schema: HubThreadSchema }),
  metoo: (threadId) => http.post(`/hub/threads/${enc(threadId)}/metoo`, {}, { schema: HubThreadSchema }),
  moderateThread: (threadId, patch) => http.patch(`/hub/threads/${enc(threadId)}`, patch, { schema: HubThreadSchema }),
  removeThread: (threadId) =>
    http.delete(`/hub/threads/${enc(threadId)}`, { schema: z.object({ removed: z.boolean(), spaceId: z.string() }).passthrough() }),
  removePost: (postId) => http.delete(`/hub/posts/${enc(postId)}`, { schema: HubThreadSchema }),
  report: (spaceId, input) => http.post(`/hub/spaces/${enc(spaceId)}/reports`, input, once),
  reports: (spaceId, signal) => http.get(`/hub/spaces/${enc(spaceId)}/reports`, { schema: Items(ReportSchema), signal }),
  resolveReport: (spaceId, reportId, action) => http.post(`/hub/spaces/${enc(spaceId)}/reports/${enc(reportId)}`, { action }, once),

  cards: (spaceId, q = '', signal) =>
    http.get(`/hub/spaces/${enc(spaceId)}/cards`, {
      schema: z.object({ items: z.array(HubCardSchema), canCurate: z.boolean().default(false) }).passthrough(),
      query: q ? { q } : undefined,
      signal,
    }),
  createCard: (spaceId, input) => http.post(`/hub/spaces/${enc(spaceId)}/cards`, input, { schema: HubCardSchema, ...once }),
  updateCard: (cardId, patch) => http.patch(`/hub/cards/${enc(cardId)}`, patch, { schema: HubCardSchema }),
  removeCard: (cardId) => http.delete(`/hub/cards/${enc(cardId)}`),
  materials: (spaceId, signal) =>
    http.get(`/hub/spaces/${enc(spaceId)}/materials`, {
      schema: z.object({ items: z.array(HubMaterialSchema), canCurate: z.boolean().default(false) }).passthrough(),
      signal,
    }),
  addMaterial: (spaceId, input) => http.post(`/hub/spaces/${enc(spaceId)}/materials`, input, { schema: HubMaterialSchema, ...once }),
  pinMaterial: (materialId, pinned) => http.patch(`/hub/materials/${enc(materialId)}`, { pinned }, { schema: HubMaterialSchema }),
  removeMaterial: (materialId) => http.delete(`/hub/materials/${enc(materialId)}`),
  chat: (spaceId, after = null, signal) =>
    http.get(`/hub/spaces/${enc(spaceId)}/chat`, { schema: ChatPageSchema, query: after ? { after } : undefined, signal, retry: { attempts: 1 } }),
  sendChat: (spaceId, body) => http.post(`/hub/spaces/${enc(spaceId)}/chat`, { body }, { schema: HubMessageSchema, ...once }),
  removeChat: (messageId) => http.delete(`/hub/chat/${enc(messageId)}`),
  rooms: (spaceId, signal) => http.get(`/hub/spaces/${enc(spaceId)}/rooms`, { schema: Items(HubRoomSchema), signal }),
  dropIn: (spaceId) =>
    http.post(`/hub/spaces/${enc(spaceId)}/rooms/drop-in`, {}, {
      schema: z.object({ room: HubRoomSchema, started: z.boolean() }).passthrough(),
      ...once,
    }),
});
