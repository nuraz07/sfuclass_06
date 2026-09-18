// server/src/config/ice.config.js
//
// Configuration of the connectivity domain (server/src/rtc/): which media regions exist, where TURN
// is reached, how long credentials live, which transports and ICE policy apply by default, and where
// the TURN shared secret comes from.
//
// Used by the api (POST /rtc/ice-servers) and realtime (room.join acknowledgement) roles only.
// The sfu role never loads this file: the SFU is ICE-lite and must not know anything about TURN.
//
// Two exports:
//   iceEnvSchema    zod object of the ICE_* / TURN_* variables; config/env.js merges it into the
//                   api and realtime role schemas so a bad value stops the process at boot.
//   loadIceConfig   parses (or accepts already-parsed) variables and returns a frozen config whose
//                   fields match the constructors in server/src/rtc/ one to one.
//
// Variables (documented in .env.example):
//   ICE_RTC_DOMAIN               rtc.example.com — delegated zone of the TURN nodes (infra/media-edge/dns.tf)
//   ICE_MEDIA_REGIONS            eu-central-1,us-east-1,ap-southeast-1
//   ICE_DEFAULT_REGION           eu-central-1 — probes without a usable hint relay here
//   ICE_REGION_FALLBACKS         eu-central-1=us-east-1;us-east-1=eu-central-1;ap-southeast-1=us-east-1
//   ICE_DEFAULT_POLICY           all | relay
//   ICE_ENABLED_TRANSPORTS       udp,tcp,tls (order = preference in the TURN URL list)
//   ICE_CREDENTIAL_TTL_S         28800   default lifetime (8 h, a school day)
//   ICE_CREDENTIAL_MIN_TTL_S     3600    lower clamp for tenant overrides
//   ICE_CREDENTIAL_MAX_TTL_S     86400   upper clamp; equals rotation phase 3 wait (24 h)
//   ICE_PROBE_TTL_S              300     pre-join network test credentials
//   ICE_REFRESH_RATIO            0.8     clients refresh at 80 % of the TTL
//   ICE_MAX_URLS                 5       more URLs only slow browser candidate gathering
//   ICE_STUN_PORT / ICE_TURN_PORT / ICE_TURNS_PORT   3478 / 3478 / 443
//   ICE_SELECTOR_SATURATION      0.9     node load above which it is only used as a last resort
//   ICE_SELECTOR_SPREAD          0.1     load band for randomised least-loaded choice
//   ICE_REGISTRY_STALE_AFTER_MS  15000   must match the agent heartbeat TTL
//   TURN_SHARED_SECRET_ARN       Secrets Manager ARN (required in production; rotated, read by TurnSecretRing)
//   TURN_SHARED_SECRET_DEV       literal secret for docker-compose.dev.yml only (rejected in production)
//   ICE_OPAQUE_ID_PEPPER         secret value injected by the ECS task definition (>= 32 characters)
//
// Owner: F8 Real-Time Connectivity.

import { z } from 'zod';

const REGION = /^[a-z]{2}(-[a-z]+)+-\d{1,2}$/;
const DOMAIN = /^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)(\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/;
const TRANSPORTS = ['udp', 'tcp', 'tls'];

const csv = (value) => String(value ?? '').split(',').map((s) => s.trim()).filter(Boolean);
const port = (fallback) => z.coerce.number().int().min(1).max(65_535).default(fallback);

export const iceEnvSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  ICE_RTC_DOMAIN: z.string().regex(DOMAIN, 'ICE_RTC_DOMAIN must be a lowercase DNS name'),
  ICE_MEDIA_REGIONS: z.string().min(1),
  ICE_DEFAULT_REGION: z.string().regex(REGION),
  ICE_REGION_FALLBACKS: z.string().default(''),
  ICE_DEFAULT_POLICY: z.enum(['all', 'relay']).default('all'),
  ICE_ENABLED_TRANSPORTS: z.string().default('udp,tcp,tls'),
  ICE_CREDENTIAL_TTL_S: z.coerce.number().int().positive().default(28_800),
  ICE_CREDENTIAL_MIN_TTL_S: z.coerce.number().int().positive().default(3_600),
  ICE_CREDENTIAL_MAX_TTL_S: z.coerce.number().int().positive().max(86_400).default(86_400),
  ICE_PROBE_TTL_S: z.coerce.number().int().min(60).max(900).default(300),
  ICE_REFRESH_RATIO: z.coerce.number().gt(0).lt(1).default(0.8),
  ICE_MAX_URLS: z.coerce.number().int().min(2).max(8).default(5),
  ICE_STUN_PORT: port(3478),
  ICE_TURN_PORT: port(3478),
  ICE_TURNS_PORT: port(443),
  ICE_SELECTOR_SATURATION: z.coerce.number().gt(0).lte(1).default(0.9),
  ICE_SELECTOR_SPREAD: z.coerce.number().min(0).lt(1).default(0.1),
  ICE_REGISTRY_STALE_AFTER_MS: z.coerce.number().int().min(5_000).max(120_000).default(15_000),
  TURN_SHARED_SECRET_ARN: z.string().startsWith('arn:aws').optional(),
  TURN_SHARED_SECRET_DEV: z.string().min(32).optional(),
  TURN_SHARED_SECRET_DEV_PREVIOUS: z.string().min(32).optional(),
  ICE_OPAQUE_ID_PEPPER: z.string().min(32, 'ICE_OPAQUE_ID_PEPPER must be at least 32 characters'),
});

/**
 * @typedef {object} IceConfig
 * @property {string} rtcDomain
 * @property {readonly string[]} regions
 * @property {string} defaultRegion
 * @property {Readonly<Record<string, readonly string[]>>} fallbacks
 * @property {(region: string) => string} regionalHost   turn-<region>.<rtcDomain>, used by GET /rtc/regions
 * @property {{ stun: number, turn: number, tls: number }} ports
 * @property {number} maxUrls
 * @property {number} probeTtlSeconds
 * @property {number} refreshRatio
 * @property {{ iceTransportPolicy: 'all'|'relay', credentialTtlSeconds: number, minTtlSeconds: number,
 *              maxTtlSeconds: number, transports: readonly ('udp'|'tcp'|'tls')[] }} policyDefaults
 * @property {{ saturation: number, spread: number }} selector
 * @property {{ staleAfterMs: number }} registry
 * @property {{ secretId?: string, staticSecrets?: { current: string, previous?: string } }} secretRing
 * @property {() => string} getPepper   non-enumerable: never serialised or logged
 */

/**
 * @param {Record<string, unknown>} [source=process.env] raw env, or the object already parsed by config/env.js
 * @returns {Readonly<IceConfig>}
 */
export function loadIceConfig(source = process.env) {
  const parsed = iceEnvSchema.safeParse(source);
  if (!parsed.success) {
    const details = parsed.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`).join('; ');
    throw new Error(`Invalid ICE configuration: ${details}`);
  }
  const env = parsed.data;
  const problems = [];

  const regions = [...new Set(csv(env.ICE_MEDIA_REGIONS))];
  for (const r of regions) if (!REGION.test(r)) problems.push(`ICE_MEDIA_REGIONS: '${r}' is not a region code`);
  if (!regions.includes(env.ICE_DEFAULT_REGION)) problems.push('ICE_DEFAULT_REGION must be one of ICE_MEDIA_REGIONS');

  const fallbacks = {};
  for (const pair of env.ICE_REGION_FALLBACKS.split(';').map((s) => s.trim()).filter(Boolean)) {
    const [from, to = ''] = pair.split('=').map((s) => s.trim());
    const targets = csv(to);
    if (!regions.includes(from)) problems.push(`ICE_REGION_FALLBACKS: unknown region '${from}'`);
    for (const t of targets) {
      if (!regions.includes(t)) problems.push(`ICE_REGION_FALLBACKS: unknown fallback '${t}' for '${from}'`);
      if (t === from) problems.push(`ICE_REGION_FALLBACKS: '${from}' cannot fall back to itself`);
    }
    fallbacks[from] = Object.freeze(targets);
  }

  const transports = [...new Set(csv(env.ICE_ENABLED_TRANSPORTS))];
  if (transports.length === 0 || transports.some((t) => !TRANSPORTS.includes(t))) {
    problems.push('ICE_ENABLED_TRANSPORTS must be a non-empty subset of udp,tcp,tls');
  }

  if (!(env.ICE_CREDENTIAL_MIN_TTL_S <= env.ICE_CREDENTIAL_TTL_S && env.ICE_CREDENTIAL_TTL_S <= env.ICE_CREDENTIAL_MAX_TTL_S)) {
    problems.push('ICE_CREDENTIAL_MIN_TTL_S <= ICE_CREDENTIAL_TTL_S <= ICE_CREDENTIAL_MAX_TTL_S must hold');
  }

  let secretRing;
  if (env.NODE_ENV === 'production') {
    if (!env.TURN_SHARED_SECRET_ARN) problems.push('TURN_SHARED_SECRET_ARN is required in production');
    if (env.TURN_SHARED_SECRET_DEV) problems.push('TURN_SHARED_SECRET_DEV must not be set in production');
    secretRing = { secretId: env.TURN_SHARED_SECRET_ARN };
  } else if (env.TURN_SHARED_SECRET_ARN) {
    secretRing = { secretId: env.TURN_SHARED_SECRET_ARN };
  } else if (env.TURN_SHARED_SECRET_DEV) {
    secretRing = {
      staticSecrets: { current: env.TURN_SHARED_SECRET_DEV, previous: env.TURN_SHARED_SECRET_DEV_PREVIOUS },
    };
  } else {
    problems.push('Set TURN_SHARED_SECRET_ARN (AWS) or TURN_SHARED_SECRET_DEV (local development)');
  }

  if (problems.length > 0) throw new Error(`Invalid ICE configuration: ${problems.join('; ')}`);

  const config = {
    rtcDomain: env.ICE_RTC_DOMAIN,
    regions: Object.freeze(regions),
    defaultRegion: env.ICE_DEFAULT_REGION,
    fallbacks: Object.freeze(fallbacks),
    regionalHost: (region) => `turn-${region}.${env.ICE_RTC_DOMAIN}`,
    ports: Object.freeze({ stun: env.ICE_STUN_PORT, turn: env.ICE_TURN_PORT, tls: env.ICE_TURNS_PORT }),
    maxUrls: env.ICE_MAX_URLS,
    probeTtlSeconds: env.ICE_PROBE_TTL_S,
    refreshRatio: env.ICE_REFRESH_RATIO,
    policyDefaults: Object.freeze({
      iceTransportPolicy: env.ICE_DEFAULT_POLICY,
      credentialTtlSeconds: env.ICE_CREDENTIAL_TTL_S,
      minTtlSeconds: env.ICE_CREDENTIAL_MIN_TTL_S,
      maxTtlSeconds: env.ICE_CREDENTIAL_MAX_TTL_S,
      transports: Object.freeze(transports),
    }),
    selector: Object.freeze({ saturation: env.ICE_SELECTOR_SATURATION, spread: env.ICE_SELECTOR_SPREAD }),
    registry: Object.freeze({ staleAfterMs: env.ICE_REGISTRY_STALE_AFTER_MS }),
    secretRing: Object.freeze(secretRing),
  };
  const pepper = env.ICE_OPAQUE_ID_PEPPER;
  Object.defineProperty(config, 'getPepper', { value: () => pepper, enumerable: false });
  return Object.freeze(config);
}