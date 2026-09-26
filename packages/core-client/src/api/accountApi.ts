/**
 * Account API  (Settings, Phase B)
 *
 * Notifications, push registration for this browser, muted chats, signed-in
 * devices and the account's history. Paths are the server's
 * (server/src/routes/account.routes.js, mounted under /account).
 *
 * Responses are validated loosely (passthrough): the server fills in every
 * default, so the client never has to know one.
 */

import { z } from 'zod';
import type { HttpClient } from '../http/httpClient.js';

const ChannelFlagsSchema = z.object({ inApp: z.boolean(), push: z.boolean(), email: z.boolean() });

export const NotificationSettingsSchema = z
  .object({
    categories: z.record(z.string(), ChannelFlagsSchema),
    quietHours: z
      .object({
        enabled: z.boolean(),
        start: z.string(),
        end: z.string(),
        allowLessonReminders: z.boolean(),
      })
      .passthrough(),
    focusDuringLessons: z.boolean(),
    showPreviews: z.boolean(),
    digest: z.enum(['off', 'daily', 'weekly']),
  })
  .passthrough();
export type NotificationSettings = z.infer<typeof NotificationSettingsSchema>;

export const NotificationsViewSchema = z
  .object({
    settings: NotificationSettingsSchema,
    timeZone: z.string().default('UTC'),
    quietNow: z.boolean().default(false),
    push: z
      .object({
        configured: z.boolean().default(false),
        publicKey: z.string().nullable().default(null),
        devices: z.number().default(0),
      })
      .passthrough(),
    email: z
      .object({ address: z.string().nullable().default(null), suppressed: z.boolean().default(false) })
      .passthrough(),
  })
  .passthrough();
export type NotificationsView = z.infer<typeof NotificationsViewSchema>;

export const TestResultSchema = z
  .object({ channel: z.string(), delivered: z.number(), detail: z.string() })
  .passthrough();
export type TestResult = z.infer<typeof TestResultSchema>;

const PushStatusSchema = z.object({ registered: z.boolean(), devices: z.number() }).passthrough();

export const MutedChatSchema = z
  .object({
    kind: z.enum(['conversation', 'channel']),
    id: z.string(),
    title: z.string(),
    mutedUntil: z.string().nullable().default(null),
  })
  .passthrough();
export type MutedChat = z.infer<typeof MutedChatSchema>;
const MutedChatListSchema = z.object({ items: z.array(MutedChatSchema) });

export const DeviceSessionSchema = z
  .object({
    sessionId: z.string(),
    label: z.string(),
    platform: z.string().nullable().default(null),
    ip: z.string().nullable().default(null),
    createdAt: z.string().nullable().default(null),
    lastActiveAt: z.string().nullable().default(null),
    current: z.boolean().default(false),
  })
  .passthrough();
export type DeviceSession = z.infer<typeof DeviceSessionSchema>;
const DeviceSessionListSchema = z.object({ items: z.array(DeviceSessionSchema) });

export const HistoryEntrySchema = z
  .object({
    id: z.string(),
    action: z.string(),
    at: z.string().nullable().default(null),
    device: z.string().nullable().default(null),
    ip: z.string().nullable().default(null),
    section: z.string().nullable().default(null),
    fields: z.array(z.string()).default([]),
    detail: z.string().nullable().default(null),
    count: z.number().nullable().default(null),
  })
  .passthrough();
export type HistoryEntry = z.infer<typeof HistoryEntrySchema>;
const HistoryPageSchema = z.object({
  items: z.array(HistoryEntrySchema),
  nextCursor: z.string().nullable().default(null),
});
export type HistoryPage = z.infer<typeof HistoryPageSchema>;

export type NotificationChannel = 'inApp' | 'push' | 'email';

export interface PushSubscriptionInput {
  endpoint: string;
  keys: { p256dh: string; auth: string };
}

export interface AccountApi {
  getNotifications(signal?: AbortSignal): Promise<NotificationsView>;
  /** Any part of the settings, any subset of its keys; returns the full view. */
  updateNotifications(patch: Record<string, unknown>): Promise<NotificationsView>;
  sendTestNotification(channel: NotificationChannel): Promise<TestResult>;
  registerPush(subscription: PushSubscriptionInput): Promise<z.infer<typeof PushStatusSchema>>;
  unregisterPush(endpoint: string): Promise<z.infer<typeof PushStatusSchema>>;
  listMutedChats(signal?: AbortSignal): Promise<z.infer<typeof MutedChatListSchema>>;
  unmuteChat(chat: { kind: MutedChat['kind']; id: string }): Promise<unknown>;
  muteChat(chat: { kind: MutedChat['kind']; id: string; until?: string | null }): Promise<unknown>;
  listSessions(signal?: AbortSignal): Promise<z.infer<typeof DeviceSessionListSchema>>;
  signOutSession(sessionId: string): Promise<void>;
  signOutOtherSessions(): Promise<{ revoked: number }>;
  loginHistory(query?: { cursor?: string | null; limit?: number }, signal?: AbortSignal): Promise<HistoryPage>;
  activity(query?: { cursor?: string | null; limit?: number }, signal?: AbortSignal): Promise<HistoryPage>;
}

const page = (query: { cursor?: string | null; limit?: number } = {}) => ({
  cursor: query.cursor ?? undefined,
  limit: query.limit,
});

export const createAccountApi = (http: HttpClient): AccountApi => ({
  getNotifications: (signal) => http.get('/account/notifications', { schema: NotificationsViewSchema, signal }),

  updateNotifications: (patch) =>
    http.patch('/account/notifications', patch, { schema: NotificationsViewSchema }),

  sendTestNotification: (channel) =>
    http.post('/account/notifications/test', { channel }, { schema: TestResultSchema }),

  registerPush: (subscription) =>
    http.put('/account/push-subscriptions', subscription, { schema: PushStatusSchema }),

  unregisterPush: (endpoint) =>
    http.post('/account/push-subscriptions/remove', { endpoint }, { schema: PushStatusSchema }),

  listMutedChats: (signal) => http.get('/account/muted-chats', { schema: MutedChatListSchema, signal }),

  unmuteChat: (chat) =>
    http.post(`/account/muted-chats/${chat.kind}/${encodeURIComponent(chat.id)}/unmute`, {}),

  muteChat: (chat) =>
    http.post(`/account/muted-chats/${chat.kind}/${encodeURIComponent(chat.id)}/mute`, {
      until: chat.until ?? null,
    }),

  listSessions: (signal) => http.get('/account/sessions', { schema: DeviceSessionListSchema, signal }),

  signOutSession: async (sessionId) => {
    await http.delete(`/account/sessions/${encodeURIComponent(sessionId)}`);
  },

  signOutOtherSessions: () =>
    http.post('/account/sessions/sign-out-others', {}, { schema: z.object({ revoked: z.number() }) }),

  loginHistory: (query = {}, signal) =>
    http.get('/account/login-history', { schema: HistoryPageSchema, query: page(query), signal }),

  activity: (query = {}, signal) =>
    http.get('/account/activity', { schema: HistoryPageSchema, query: page(query), signal }),
});
