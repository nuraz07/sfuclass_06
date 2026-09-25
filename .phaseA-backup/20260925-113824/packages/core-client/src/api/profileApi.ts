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
