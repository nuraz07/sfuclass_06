// classroom-app/packages/contracts/src/zod/rtc.schema.ts
/**
 * Real-time connectivity contracts  (F1, F8)  [V7]
 *
 * The shapes a client needs to reach the media plane:
 *
 *   - the ICE configuration: STUN/TURN servers plus temporary credentials,
 *     minted by IceServerService and returned in the join acknowledgement
 *     (and by POST /rtc/ice-servers),
 *   - the transport parameters an SFU node returns for a WebRTC transport,
 *   - the region hint produced by the pre-join ConnectivityProbe.
 *
 * Owned by F8. signaling.events.ts imports from here and re-exports, so code
 * that already holds `SignalingEvents` never needs a second import.
 *
 * Nothing in this file names an SFU node. A client knows transport parameters
 * (whose ICE candidates carry the node's public address and WebRtcServer port)
 * and TURN hostnames. It never learns node ids, control addresses or placement.
 */

import { z } from 'zod';
import { IsoDateTimeSchema } from './common.schema.ts';

// ---------------------------------------------------------------------------
// mediasoup payloads
// ---------------------------------------------------------------------------

/**
 * mediasoup payloads are large, provider-defined structures. Validating their
 * internals here would duplicate mediasoup's own checks and break on every
 * upgrade, so they pass through as opaque records and mediasoup rejects what it
 * does not like.
 */
const OpaqueSchema = z.record(z.string(), z.unknown());

export const RtpCapabilitiesSchema = OpaqueSchema;
export const RtpParametersSchema = OpaqueSchema;
export const DtlsParametersSchema = OpaqueSchema;
export const IceParametersSchema = OpaqueSchema;
export const IceCandidateSchema = OpaqueSchema;

// ---------------------------------------------------------------------------
// ICE policy
// ---------------------------------------------------------------------------

/**
 * 'all'   ICE may use host, server-reflexive and relay candidates.
 * 'relay' Only TURN candidates. Tenants use it for privacy (learners and SFU
 *         never learn each other's addresses); IceRecovery uses it as the
 *         retry after two failed ICE restarts.
 */
export const ICE_TRANSPORT_POLICIES = ['all', 'relay'] as const;
export const IceTransportPolicySchema = z.enum(ICE_TRANSPORT_POLICIES);
export type IceTransportPolicy = z.infer<typeof IceTransportPolicySchema>;

/** TURN transports a tenant may enable: UDP 3478, TCP 3478, TLS 443. */
export const TURN_TRANSPORTS = ['udp', 'tcp', 'tls'] as const;
export const TurnTransportSchema = z.enum(TURN_TRANSPORTS);
export type TurnTransport = z.infer<typeof TurnTransportSchema>;

/**
 * Hard cap across all entries: one STUN URL, three transports on the primary
 * TURN node, TLS 443 on a backup node. More URLs only slow candidate gathering.
 */
export const ICE_MAX_URLS = 5;

const IceUrlSchema = z
  .string()
  .max(256)
  .regex(/^(stun|turns?):\S+$/, 'must be a stun:, turn: or turns: URL');

export const IceServerSchema = z
  .object({
    urls: z.array(IceUrlSchema).min(1).max(ICE_MAX_URLS),
    /** TURN REST username: `<expiresAtUnix>:<opaqueId>`. Never contains PII. */
    username: z.string().max(128).optional(),
    /** base64(HMAC-SHA1(secret, username)). */
    credential: z.string().max(256).optional(),
  })
  .refine(
    (server) =>
      server.urls.every((url) => url.startsWith('stun:')) ||
      (Boolean(server.username) && Boolean(server.credential)),
    { error: 'TURN URLs require a username and a credential' },
  );
export type IceServer = z.infer<typeof IceServerSchema>;

export const IceConfigSchema = z
  .object({
    iceServers: z.array(IceServerSchema).min(1).max(ICE_MAX_URLS),
    iceTransportPolicy: IceTransportPolicySchema,
    /** When the TURN credentials stop being accepted. */
    expiresAt: IsoDateTimeSchema,
    /** 80 % of the TTL: IceConfigProvider refreshes from here on. */
    refreshAfter: IsoDateTimeSchema,
  })
  .refine(
    (config) =>
      config.iceServers.reduce((count, server) => count + server.urls.length, 0) <= ICE_MAX_URLS,
    { error: `at most ${ICE_MAX_URLS} ICE URLs in total`, path: ['iceServers'] },
  )
  .refine((config) => Date.parse(config.refreshAfter) < Date.parse(config.expiresAt), {
    error: 'refreshAfter must be before expiresAt',
    path: ['refreshAfter'],
  });
export type IceConfig = z.infer<typeof IceConfigSchema>;

// ---------------------------------------------------------------------------
// Transports
// ---------------------------------------------------------------------------

/**
 * What an SFU node returns for one WebRTC transport. The candidates point at
 * the node's Elastic IP and its WebRtcServer UDP/TCP port; the client maps
 * `transportId` to mediasoup-client's `id`.
 */
export const TransportOptionsSchema = z.object({
  transportId: z.string().max(64),
  iceParameters: IceParametersSchema,
  iceCandidates: z.array(IceCandidateSchema).max(16),
  dtlsParameters: DtlsParametersSchema,
});
export type TransportOptions = z.infer<typeof TransportOptionsSchema>;

// ---------------------------------------------------------------------------
// Region hint
// ---------------------------------------------------------------------------

/**
 * Produced by ConnectivityProbe before joining. Advisory only: RegionHint.js
 * validates it against live media regions and tenant residency policy wins.
 */
export const RegionHintSchema = z.object({
  region: z.string().regex(/^[a-z]{2}(-[a-z]+)+-\d{1,2}$/, 'must be an AWS region name'),
  rttMs: z.number().int().min(0).max(10_000).optional(),
});
export type RegionHint = z.infer<typeof RegionHintSchema>;