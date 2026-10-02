/**
 * Files API  (Files and Media)
 *
 * Your own uploads — the Media library. Paths are the server's
 * (server/src/routes/files.routes.js, mounted under /files).
 *
 * An upload is three steps: startUpload() reserves it and returns a signed
 * URL; the browser PUTs the bytes there (apps/web/src/lib/files.js does that,
 * with progress); completeUpload() has the server check and scan the file and
 * answers with the ready file — or an error that says why it was refused.
 *
 * `openUrl` is a path relative to the API, valid for two hours; it opens the
 * file in a new tab without a sign-in header.
 */

import { z } from 'zod';
import type { HttpClient } from '../http/httpClient.js';

export const FileViewSchema = z
  .object({
    fileId: z.string(),
    name: z.string(),
    ext: z.string(),
    kind: z.enum(['image', 'document', 'video', 'audio', 'text']),
    contentType: z.string(),
    sizeBytes: z.number(),
    status: z.string(),
    inline: z.boolean().default(false),
    createdAt: z.string().nullable(),
    usedIn: z.number().optional(),
    openUrl: z.string().nullable().default(null),
  })
  .passthrough();
export type FileView = z.infer<typeof FileViewSchema>;

const UploadTicketSchema = z
  .object({
    fileId: z.string(),
    uploadUrl: z.string(),
    uploadHeaders: z.record(z.string(), z.string()).default({}),
    expiresInSec: z.number().default(900),
  })
  .passthrough();
export type UploadTicket = z.infer<typeof UploadTicketSchema>;

const LibrarySchema = z
  .object({
    items: z.array(FileViewSchema),
    usage: z.object({ usedBytes: z.number(), quotaBytes: z.number(), maxFileBytes: z.number() }).passthrough(),
    accept: z.array(z.string()).default([]),
  })
  .passthrough();
export type FileLibrary = z.infer<typeof LibrarySchema>;

export const FileUsageSchema = z
  .object({
    items: z.array(
      z
        .object({
          materialId: z.string(),
          spaceId: z.string(),
          spaceName: z.string(),
          emoji: z.string().nullable().default(null),
          addedAt: z.string().nullable().default(null),
        })
        .passthrough(),
    ),
  })
  .passthrough();
export type FileUsage = z.infer<typeof FileUsageSchema>;

export type LibrarySort = 'new' | 'old' | 'name' | 'size';

export interface FilesApi {
  startUpload(input: { name: string; sizeBytes: number }): Promise<UploadTicket>;
  completeUpload(fileId: string): Promise<FileView>;
  list(query?: { q?: string; kind?: string; sort?: LibrarySort }, signal?: AbortSignal): Promise<FileLibrary>;
  /** The spaces where one of my files is a material. */
  usage(fileId: string, signal?: AbortSignal): Promise<FileUsage>;
  rename(fileId: string, name: string): Promise<FileView>;
  remove(fileId: string): Promise<unknown>;
  link(fileId: string): Promise<{ url: string }>;
}

const enc = encodeURIComponent;

export const createFilesApi = (http: HttpClient): FilesApi => ({
  startUpload: (input) => http.post('/files/uploads', input, { schema: UploadTicketSchema, retry: { attempts: 1 } }),
  completeUpload: (fileId) => http.post(`/files/${enc(fileId)}/complete`, {}, { schema: FileViewSchema, retry: { attempts: 1 } }),
  list: (query = {}, signal) =>
    http.get('/files', {
      schema: LibrarySchema,
      query: Object.fromEntries(Object.entries(query).filter(([, value]) => value)),
      signal,
    }),
  usage: (fileId, signal) => http.get(`/files/${enc(fileId)}/usage`, { schema: FileUsageSchema, signal }),
  rename: (fileId, name) => http.patch(`/files/${enc(fileId)}`, { name }, { schema: FileViewSchema }),
  remove: (fileId) => http.delete(`/files/${enc(fileId)}`),
  link: (fileId) => http.get(`/files/${enc(fileId)}/link`, { schema: z.object({ url: z.string() }).passthrough() }),
});
