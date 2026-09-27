/**
 * Rooms API  (Rooms: create your own room)
 *
 * Planning, the lobby and the host's controls for rooms people create
 * themselves. Paths are the server's (server/src/routes/scheduledRooms.routes.js,
 * mounted under /scheduled-rooms). The room is still joined through the
 * classroom socket at /rooms/<code>.
 *
 * Links in answers (lobby URL, QR code, calendar file) are built by the
 * server for the address this page is on: the page's origin travels along
 * as ?origin=, and the server only uses it when it trusts it.
 */

import { z } from 'zod';
import type { HttpClient } from '../http/httpClient.js';

const Person = z
  .object({ userId: z.string(), displayName: z.string(), handle: z.string().nullable().default(null) })
  .passthrough();
export type RoomPerson = z.infer<typeof Person>;

export const RoomPhaseSchema = z.enum(['scheduled', 'doors-open', 'live', 'ended', 'cancelled']);
export type RoomPhase = z.infer<typeof RoomPhaseSchema>;

export const RoomDetailSchema = z
  .object({
    code: z.string(),
    sessionId: z.string(),
    seriesId: z.string().nullable().default(null),
    title: z.string(),
    description: z.string().nullable().default(null),
    agenda: z.string().nullable().default(null),
    startsAt: z.string(),
    endsAt: z.string(),
    timeZone: z.string(),
    doorsOpenAt: z.string(),
    hostOpensAt: z.string(),
    lateUntil: z.string().nullable().default(null),
    earlyEntryMinutes: z.number(),
    lateJoinMinutes: z.number().nullable().default(null),
    status: z.string(),
    phase: RoomPhaseSchema,
    access: z.enum(['invited', 'link']),
    approval: z.boolean(),
    capacity: z.number().nullable().default(null),
    effectiveCapacity: z.number(),
    occupied: z.number().default(0),
    settings: z
      .object({
        learnersJoinMuted: z.boolean().nullable().default(null),
        reactionsEnabled: z.boolean().nullable().default(null),
        learnersMayShare: z.boolean().nullable().default(null),
      })
      .passthrough(),
    host: Person,
    cohosts: z.array(Person).default([]),
    invitees: z.array(Person).optional(),
    url: z.string(),
    cancelReason: z.string().nullable().default(null),
    viewer: z
      .object({
        relation: z.enum(['host', 'cohost', 'invitee', 'guest']),
        moderator: z.boolean(),
        canEnter: z.boolean(),
        reason: z.string().nullable().default(null),
        message: z.string().nullable().default(null),
        opensAt: z.string().nullable().default(null),
        knocked: z.boolean().default(false),
        admitted: z.boolean().default(false),
        waitlistPosition: z.number().nullable().default(null),
        holdUntil: z.string().nullable().default(null),
      })
      .passthrough(),
    serverTime: z.string(),
  })
  .passthrough();
export type RoomDetail = z.infer<typeof RoomDetailSchema>;

export const RoomListItemSchema = z
  .object({
    code: z.string(),
    sessionId: z.string(),
    seriesId: z.string().nullable().default(null),
    title: z.string(),
    startsAt: z.string(),
    endsAt: z.string(),
    doorsOpenAt: z.string(),
    timeZone: z.string(),
    status: z.string(),
    phase: RoomPhaseSchema,
    access: z.string(),
    capacity: z.number().nullable().default(null),
    inviteeCount: z.number().default(0),
    hostName: z.string().nullable().default(null),
    relation: z.enum(['host', 'cohost', 'invitee']),
  })
  .passthrough();
export type RoomListItem = z.infer<typeof RoomListItemSchema>;

const ConfigSchema = z
  .object({
    earlyEntry: z.object({ min: z.number(), max: z.number(), default: z.number() }),
    duration: z.object({ min: z.number(), max: z.number(), presets: z.array(z.number()) }),
    capacity: z.object({ min: z.number(), max: z.number(), default: z.number() }),
    lateJoinOptions: z.array(z.number().nullable()),
    extendOptions: z.array(z.number()),
    hostEarlyMinutes: z.number(),
    limits: z.object({ invitees: z.number(), cohosts: z.number() }),
  })
  .passthrough();
export type RoomsConfig = z.infer<typeof ConfigSchema>;

const PreviewSchema = z
  .object({
    occurrences: z.array(z.object({ startsAt: z.string(), endsAt: z.string() })),
    conflicts: z.array(
      z.object({ at: z.string(), title: z.string(), startsAt: z.string().nullable(), endsAt: z.string().nullable() }).passthrough(),
    ),
    adjusted: z.string().nullable().default(null),
    inPast: z.boolean().default(false),
  })
  .passthrough();
export type RoomPreview = z.infer<typeof PreviewSchema>;

const GateSchema = z
  .object({
    scheduled: z.boolean(),
    canEnter: z.boolean(),
    reason: z.string().nullable().optional(),
    message: z.string().nullable().optional(),
  })
  .passthrough();
export type RoomGate = z.infer<typeof GateSchema>;

const KnocksSchema = z.object({
  items: z.array(z.object({ userId: z.string(), displayName: z.string(), at: z.string().nullable() }).passthrough()),
});

export interface RoomRecurrence {
  freq: 'DAILY' | 'WEEKLY';
  interval?: number;
  byDay?: Array<'MO' | 'TU' | 'WE' | 'TH' | 'FR' | 'SA' | 'SU'>;
  count?: number;
  until?: string;
}

export interface RoomInput {
  title: string;
  description?: string | null;
  startsAtLocal: string;
  durationMinutes: number;
  timeZone: string;
  earlyEntryMinutes?: number;
  lateJoinMinutes?: number | null;
  capacity?: number | null;
  access?: 'invited' | 'link';
  approval?: boolean;
  inviteeIds?: string[];
  cohostIds?: string[];
  settings?: {
    learnersJoinMuted?: boolean;
    reactionsEnabled?: boolean;
    learnersMayShare?: boolean;
    agenda?: string | null;
  };
  recurrence?: RoomRecurrence | null;
}

export interface RoomsApi {
  config(signal?: AbortSignal): Promise<RoomsConfig>;
  preview(
    input: Pick<RoomInput, 'startsAtLocal' | 'durationMinutes' | 'timeZone' | 'recurrence'> & { excludeCode?: string },
    signal?: AbortSignal,
  ): Promise<RoomPreview>;
  create(input: RoomInput): Promise<{ room: RoomDetail; occurrences: Array<{ code: string; startsAt: string; endsAt: string }> }>;
  mine(when?: 'upcoming' | 'past', signal?: AbortSignal): Promise<{ items: RoomListItem[] }>;
  get(code: string, signal?: AbortSignal): Promise<RoomDetail>;
  gate(code: string, signal?: AbortSignal): Promise<RoomGate>;
  update(code: string, patch: Partial<Omit<RoomInput, 'recurrence'>>): Promise<RoomDetail>;
  cancel(code: string, input?: { scope?: 'this' | 'following'; reason?: string | null }): Promise<{ cancelled: number }>;
  extend(code: string, minutes: number): Promise<{ endsAt: string }>;
  end(code: string): Promise<{ ended: boolean }>;
  knock(code: string): Promise<RoomDetail>;
  withdrawKnock(code: string): Promise<RoomDetail>;
  knocks(code: string, signal?: AbortSignal): Promise<z.infer<typeof KnocksSchema>>;
  admit(code: string, userIds?: string[]): Promise<{ admitted: number }>;
  deny(code: string, userId: string): Promise<{ denied: boolean }>;
  joinWaitlist(code: string): Promise<RoomDetail>;
  leaveWaitlist(code: string): Promise<RoomDetail>;
  /** The .ics file, for a download link. */
  calendarFile(code: string): Promise<Blob>;
  /** The link as a QR code (a data: URL), for a slide or a printed sheet. */
  qr(code: string): Promise<{ dataUrl: string }>;
}

const BASE = '/scheduled-rooms';
const path = (code: string, rest = '') => `${BASE}/${encodeURIComponent(code)}${rest}`;
const once = { retry: { attempts: 1 } };

/** This page's address, for links the server builds (browsers only). */
const pageOrigin = (): string | undefined => {
  const location = (globalThis as { location?: { origin?: string } }).location;
  return location?.origin && location.origin !== 'null' ? location.origin : undefined;
};

export const createRoomsApi = (http: HttpClient): RoomsApi => ({
  config: (signal) => http.get(`${BASE}/config`, { schema: ConfigSchema, signal }),

  preview: (input, signal) => http.post(`${BASE}/preview`, input, { schema: PreviewSchema, signal, ...once }),

  create: (input) =>
    http.post(BASE, input, {
      schema: z
        .object({
          room: RoomDetailSchema,
          occurrences: z.array(z.object({ code: z.string(), startsAt: z.string(), endsAt: z.string() })),
        })
        .passthrough(),
      ...once,
    }),

  mine: (when = 'upcoming', signal) =>
    http.get(`${BASE}/mine`, { schema: z.object({ items: z.array(RoomListItemSchema) }), query: { when }, signal }),

  get: (code, signal) => http.get(path(code), { schema: RoomDetailSchema, query: { origin: pageOrigin() }, signal }),

  gate: (code, signal) => http.get(path(code, '/gate'), { schema: GateSchema, signal, retry: { attempts: 2 } }),

  update: (code, patch) => http.patch(path(code), patch, { schema: RoomDetailSchema }),

  cancel: (code, input = {}) =>
    http.post(path(code, '/cancel'), input, { schema: z.object({ cancelled: z.number() }).passthrough(), ...once }),

  extend: (code, minutes) =>
    http.post(path(code, '/extend'), { minutes }, { schema: z.object({ endsAt: z.string() }).passthrough(), ...once }),

  end: (code) => http.post(path(code, '/end'), {}, { schema: z.object({ ended: z.boolean() }).passthrough(), ...once }),

  knock: (code) => http.post(path(code, '/knock'), {}, { schema: RoomDetailSchema, ...once }),

  withdrawKnock: (code) => http.delete(path(code, '/knock'), { schema: RoomDetailSchema }),

  knocks: (code, signal) => http.get(path(code, '/knocks'), { schema: KnocksSchema, signal }),

  admit: (code, userIds = []) =>
    http.post(path(code, '/admit'), { userIds }, { schema: z.object({ admitted: z.number() }).passthrough() }),

  deny: (code, userId) =>
    http.post(path(code, '/deny'), { userId }, { schema: z.object({ denied: z.boolean() }).passthrough() }),

  joinWaitlist: (code) => http.post(path(code, '/waitlist'), {}, { schema: RoomDetailSchema, ...once }),

  leaveWaitlist: (code) => http.delete(path(code, '/waitlist'), { schema: RoomDetailSchema }),

  qr: (code) =>
    http.get(path(code, '/qr'), {
      schema: z.object({ dataUrl: z.string() }).passthrough(),
      query: { origin: pageOrigin() },
      retry: { attempts: 1 },
    }),

  calendarFile: async (code) => {
    const origin = pageOrigin();
    const query = origin ? `?origin=${encodeURIComponent(origin)}` : '';
    const response = await http.raw('GET', `${path(code, '/calendar.ics')}${query}`);
    if (!response.ok) throw new Error('The calendar file could not be downloaded.');
    return response.blob();
  },
});
