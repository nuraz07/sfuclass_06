/**
 * Account security API  (Settings, Phase C)
 *
 * Password, two-step sign-in, passkeys and "your data". Paths are the
 * server's (server/src/routes/accountSecurity.routes.js, mounted under
 * /account/security).
 *
 * Calls that switch protection off or delete something take a
 * confirmation: the password, or a code when two-step sign-in is on.
 */

import { z } from 'zod';
import type { HttpClient } from '../http/httpClient.js';

export interface Confirmation {
  password?: string;
  code?: string;
}

export const PasskeyViewSchema = z
  .object({
    id: z.string(),
    name: z.string(),
    deviceType: z.string().nullable().default(null),
    backedUp: z.boolean().default(false),
    site: z.string().nullable().default(null),
    createdAt: z.string().nullable().default(null),
    lastUsedAt: z.string().nullable().default(null),
  })
  .passthrough();
export type PasskeyView = z.infer<typeof PasskeyViewSchema>;

export const SecurityOverviewSchema = z
  .object({
    password: z.object({ set: z.boolean(), changedAt: z.string().nullable().default(null) }).passthrough(),
    twoStep: z
      .object({
        totp: z.object({ enabled: z.boolean(), enabledAt: z.string().nullable().default(null) }).passthrough(),
        recoveryCodesRemaining: z.number().default(0),
        passkeyCount: z.number().default(0),
        required: z.boolean().default(false),
      })
      .passthrough(),
    passkeys: z.object({ available: z.boolean().default(false), items: z.array(PasskeyViewSchema) }).passthrough(),
    deletion: z
      .object({ requestedAt: z.string().nullable().default(null), scheduledFor: z.string() })
      .passthrough()
      .nullable()
      .default(null),
  })
  .passthrough();
export type SecurityOverview = z.infer<typeof SecurityOverviewSchema>;

const TotpSetupSchema = z
  .object({ secret: z.string(), uri: z.string(), qr: z.string().nullable().default(null), expiresInSec: z.number() })
  .passthrough();
export type TotpSetup = z.infer<typeof TotpSetupSchema>;

const RecoveryCodesSchema = z.object({ recoveryCodes: z.array(z.string()) }).passthrough();

const RegistrationOptionsSchema = z
  .object({ optionsId: z.string(), options: z.record(z.string(), z.unknown()) })
  .passthrough();

const PasskeyAddedSchema = z
  .object({ passkey: PasskeyViewSchema, recoveryCodes: z.array(z.string()).nullable().default(null) })
  .passthrough();

const DeletionSchema = z
  .object({
    deletion: z
      .object({ requestedAt: z.string().nullable().default(null), scheduledFor: z.string() })
      .passthrough()
      .nullable(),
  })
  .passthrough();

export interface AccountSecurityApi {
  overview(signal?: AbortSignal): Promise<SecurityOverview>;
  changePassword(input: {
    currentPassword: string;
    newPassword: string;
    signOutOthers?: boolean;
  }): Promise<{ changed: boolean; signedOut: number }>;
  startTotpSetup(confirmation: Confirmation): Promise<TotpSetup>;
  enableTotp(code: string): Promise<{ recoveryCodes: string[] }>;
  disableTotp(confirmation: Confirmation): Promise<SecurityOverview>;
  regenerateRecoveryCodes(confirmation: Confirmation): Promise<{ recoveryCodes: string[] }>;
  passkeyRegistrationOptions(confirmation: Confirmation): Promise<z.infer<typeof RegistrationOptionsSchema>>;
  addPasskey(input: {
    optionsId: string;
    response: Record<string, unknown>;
    name?: string;
  }): Promise<z.infer<typeof PasskeyAddedSchema>>;
  renamePasskey(id: string, name: string): Promise<unknown>;
  removePasskey(id: string, confirmation: Confirmation): Promise<SecurityOverview>;
  /** Everything as one JSON document; the caller offers it as a download. */
  exportData(): Promise<unknown>;
  requestDeletion(confirmation: Confirmation): Promise<z.infer<typeof DeletionSchema>>;
  cancelDeletion(): Promise<z.infer<typeof DeletionSchema>>;
}

const BASE = '/account/security';
const once = { retry: { attempts: 1 } } as const;

export const createAccountSecurityApi = (http: HttpClient): AccountSecurityApi => ({
  overview: (signal) => http.get(BASE, { schema: SecurityOverviewSchema, signal }),

  changePassword: (input) =>
    http.post(`${BASE}/password`, { signOutOthers: true, ...input }, {
      schema: z.object({ changed: z.boolean(), signedOut: z.number().default(0) }).passthrough(),
      ...once,
    }),

  startTotpSetup: (confirmation) => http.post(`${BASE}/totp/setup`, confirmation, { schema: TotpSetupSchema, ...once }),

  enableTotp: (code) => http.post(`${BASE}/totp/enable`, { code }, { schema: RecoveryCodesSchema, ...once }),

  disableTotp: (confirmation) =>
    http.post(`${BASE}/totp/disable`, confirmation, { schema: SecurityOverviewSchema, ...once }),

  regenerateRecoveryCodes: (confirmation) =>
    http.post(`${BASE}/recovery-codes`, confirmation, { schema: RecoveryCodesSchema, ...once }),

  passkeyRegistrationOptions: (confirmation) =>
    http.post(`${BASE}/passkeys/options`, confirmation, { schema: RegistrationOptionsSchema, ...once }),

  addPasskey: (input) => http.post(`${BASE}/passkeys`, input, { schema: PasskeyAddedSchema, ...once }),

  renamePasskey: (id, name) => http.patch(`${BASE}/passkeys/${encodeURIComponent(id)}`, { name }),

  removePasskey: (id, confirmation) =>
    http.post(`${BASE}/passkeys/${encodeURIComponent(id)}/remove`, confirmation, {
      schema: SecurityOverviewSchema,
      ...once,
    }),

  // A large account can take a while to collect.
  exportData: () => http.get(`${BASE}/export`, { timeoutMs: 120_000, retry: { attempts: 1 } }),

  requestDeletion: (confirmation) => http.post(`${BASE}/deletion`, confirmation, { schema: DeletionSchema, ...once }),

  cancelDeletion: () => http.post(`${BASE}/deletion/cancel`, {}, { schema: DeletionSchema }),
});
