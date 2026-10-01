/**
 * Username API  (Sign in with a username)
 *
 * Paths: server/src/routes/username.routes.js, mounted under /account/username.
 * available() needs no sign-in, so the sign-up form can use it.
 */

import { z } from 'zod';
import type { HttpClient } from '../http/httpClient.js';

const UsernameSchema = z.object({ username: z.string().nullable() }).passthrough();
const AvailableSchema = z.object({ available: z.boolean(), problem: z.string().nullable() }).passthrough();

export interface UsernameApi {
  mine(signal?: AbortSignal): Promise<{ username: string | null }>;
  available(name: string, signal?: AbortSignal): Promise<{ available: boolean; problem: string | null }>;
  set(username: string | null): Promise<{ username: string | null }>;
}

export const createUsernameApi = (http: HttpClient): UsernameApi => ({
  mine: (signal) => http.get('/account/username', { schema: UsernameSchema, signal }),
  available: (name, signal) =>
    http.get('/account/username/available', { schema: AvailableSchema, query: { name }, signal, anonymous: true }),
  set: (username) => http.put('/account/username', { username }, { schema: UsernameSchema }),
});
