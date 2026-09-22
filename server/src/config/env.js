// classroom-app/server/src/config/env.js
/**
 * Environment configuration  (F7, F8)  [EXT]
 *
 * The single source of truth for every runtime setting. Importing this module
 * validates the environment and, on failure, prints what is wrong and exits.
 * That is the whole point: a process that boots with a missing S3 bucket and
 * discovers it during a learner's upload is worse than one that never booted.
 *
 * Version 7: one schema per process role.
 *
 *   api       HTTP API (server.js)
 *   realtime  Socket.IO: signalling, chat, presence, Yjs (realtime.js)
 *   sfu       mediasoup node: workers, WebRtcServers, control RPC (sfu.js)
 *   worker    BullMQ workers and scheduled jobs (worker.js)
 *
 * Every variable is declared once below with the roles that receive it. A
 * role's schema is built from its variables only, so an SFU process cannot
 * even read a TURN secret or a JWT key through `env`. In production a
 * variable that belongs to other roles but is present in this process is an
 * error: it means a task definition hands out more than the role needs.
 *
 * Three rules keep this honest:
 *
 *   1. Every variable in .env.example appears here, and nothing else does.
 *      `ops/scripts/check-env-schema.js` compares the two in CI and fails the
 *      build on drift; it reads `envVariableNames` (or `envSchema.shape`, the
 *      union of all roles).
 *
 *   2. Secrets are already in process.env by the time this runs. In AWS they
 *      arrive from Secrets Manager via config/secrets.js, called from the
 *      bootstrap before this module is imported. This file never fetches.
 *
 *   3. The SFU role has no TURN variable at all. The SFU is ICE-lite; STUN and
 *      TURN reach clients through the API, never through the media server.
 */

import { z } from 'zod';
import { SERVICE_ROLES, resolveServiceRole } from './secrets.js';

export { SERVICE_ROLES };

// ---------------------------------------------------------------------------
// Coercion helpers
// ---------------------------------------------------------------------------

/** '1', 'true', 'yes', 'on' are true; everything else is false. */
const bool = (defaultValue) =>
  z
    .string()
    .optional()
    .transform((value) => {
      if (value === undefined) return defaultValue;
      return ['1', 'true', 'yes', 'on'].includes(value.toLowerCase());
    });

const int = (defaultValue, { min, max } = {}) => {
  let schema = z.coerce.number().int();
  if (min !== undefined) schema = schema.min(min);
  if (max !== undefined) schema = schema.max(max);
  return defaultValue === undefined ? schema : schema.default(defaultValue);
};

/** Comma-separated list into a trimmed array, empties dropped. */
const csv = (defaultValue = []) =>
  z
    .string()
    .optional()
    .transform((value) =>
      value === undefined
        ? defaultValue
        : value
            .split(',')
            .map((entry) => entry.trim())
            .filter(Boolean),
    );

/** base64-encoded PEM, so a key survives a single-line environment variable. */
const pem = z
  .string()
  .optional()
  .transform((value, ctx) => {
    if (!value) return null;
    try {
      const decoded = Buffer.from(value, 'base64').toString('utf8');
      if (!decoded.includes('-----BEGIN')) throw new Error('not a PEM');
      return decoded;
    } catch {
      ctx.addIssue({ code: 'custom', message: 'must be a base64-encoded PEM block' });
      return z.NEVER;
    }
  });

const duration = z.string().regex(/^\d+[smhd]$/, 'e.g. 15m, 30d');

const redisUrl = z.string().regex(/^rediss?:\/\//, 'must be a redis:// or rediss:// URL');

const awsRegion = z.string().regex(/^[a-z]{2}(-[a-z]+)+-\d{1,2}$/, 'must be an AWS region name');

const optionalString = z.string().optional().default('');

// ---------------------------------------------------------------------------
// Roles
// ---------------------------------------------------------------------------

const ALL = SERVICE_ROLES;
const API = ['api'];
const EDGE = ['api', 'realtime'];
const DATA = ['api', 'realtime', 'worker'];
const ASSETS = ['api', 'worker'];
const MEDIA_STORAGE = ['api', 'worker', 'sfu'];
const SFU = ['sfu'];
const CONTROL = ['sfu', 'realtime'];
const REALTIME = ['realtime'];
const WORKER = ['worker'];

const DEFAULT_PORT = Object.freeze({ api: 4000, realtime: 4100, sfu: 4200, worker: 4300 });

/** Each mediasoup worker owns port base + index; 64 workers is the ceiling. */
const MAX_MEDIASOUP_WORKERS = 64;

const TURN_TRANSPORTS = ['udp', 'tcp', 'tls'];

/**
 * @param {readonly string[]} roles     processes that receive the variable
 * @param {z.ZodType | ((role: string) => z.ZodType)} schema
 * @param {{ secret?: boolean, requiredInProduction?: boolean }} [meta]
 */
const define = (roles, schema, { secret = false, requiredInProduction = false } = {}) =>
  Object.freeze({ roles: Object.freeze([...roles]), schema, secret, requiredInProduction });

// ---------------------------------------------------------------------------
// Variables — mirrors .env.example section for section
// ---------------------------------------------------------------------------

const variables = Object.freeze({
  // --- runtime ------------------------------------------------------------
  NODE_ENV: define(ALL, z.enum(['development', 'test', 'production']).default('development')),
  SERVICE_ROLE: define(ALL, z.enum(SERVICE_ROLES)),
  PORT: define(ALL, (role) => int(DEFAULT_PORT[role], { min: 1, max: 65535 })),
  APP_URL: define(ALL, z.url()),
  API_URL: define(ALL, z.url()),
  ALLOWED_ORIGINS: define(ALL, csv()),
  TRUST_PROXY: define(ALL, int(0, { min: 0, max: 10 })),
  /** Names the secret set (staging, production); falls back to NODE_ENV. */
  DEPLOY_ENV: define(ALL, optionalString),
  /** 'aws' makes config/secrets.js read Secrets Manager; 'env' reads nothing. */
  SECRETS_SOURCE: define(ALL, z.enum(['env', 'aws']).default('env')),
  AWS_REGION: define(ALL, awsRegion.default('eu-central-1')),

  // --- edge: api and realtime face clients ---------------------------------
  PUBLIC_WS_URL: define(EDGE, z.string().min(1)),
  ALLOWED_HOSTS: define(EDGE, csv(['localhost'])),

  // --- auth (secret) ------------------------------------------------------
  JWT_PRIVATE_KEY: define(API, pem, { secret: true, requiredInProduction: true }),
  JWT_PUBLIC_KEY: define(EDGE, pem, { secret: true, requiredInProduction: true }),
  JWT_ACCESS_TTL: define(API, duration.default('15m')),
  REFRESH_TTL: define(API, duration.default('30d')),
  JWT_ISSUER: define(EDGE, z.string().default('classroom-app')),
  JWT_AUDIENCE: define(EDGE, z.string().default('classroom-clients')),
  COOKIE_SECRET: define(API, z.string().min(16), { secret: true }),
  COOKIE_DOMAIN: define(API, z.string().default('localhost')),
  COOKIE_SECURE: define(API, bool(false)),

  // --- database -----------------------------------------------------------
  DATABASE_URL: define(DATA, z.string().startsWith('postgres'), { secret: true }),
  DATABASE_READ_URL: define(DATA, optionalString, { secret: true }),
  PGSSLMODE: define(DATA, z.enum(['disable', 'require', 'verify-full']).default('require')),
  PG_POOL_MAX: define(DATA, int(10, { min: 1, max: 100 })),
  PG_POOL_IDLE_TIMEOUT_MS: define(DATA, int(30_000)),
  PG_STATEMENT_TIMEOUT_MS: define(DATA, int(15_000, { min: 1_000 })),
  PG_CONNECTION_TIMEOUT_MS: define(DATA, int(5_000)),

  // --- redis: state (noeviction) and cache (volatile-lru) -----------------
  /** BullMQ, seat Lua, room and media-node registries, rate limits, revocation. */
  REDIS_STATE_URL: define(ALL, redisUrl, { secret: true }),
  /** Entitlements, presence, unread counters, Socket.IO sharded Pub/Sub. */
  REDIS_CACHE_URL: define(DATA, redisUrl, { secret: true }),
  REDIS_TLS: define(ALL, bool(false)),
  REDIS_PREFIX: define(ALL, z.string().default('classroom')),

  // --- storage ------------------------------------------------------------
  S3_BUCKET_RAW: define(ASSETS, z.string().min(1)),
  S3_BUCKET_QUARANTINE: define(ASSETS, z.string().min(1)),
  S3_BUCKET_DELIVERY: define(ASSETS, z.string().min(1)),
  /** Capture sidecar segments; required when RECORDING_ENABLED. */
  S3_BUCKET_RECORDINGS: define(MEDIA_STORAGE, optionalString),
  S3_ENDPOINT: define(MEDIA_STORAGE, optionalString),
  S3_FORCE_PATH_STYLE: define(MEDIA_STORAGE, bool(false)),
  AWS_ACCESS_KEY_ID: define(MEDIA_STORAGE, optionalString),
  AWS_SECRET_ACCESS_KEY: define(MEDIA_STORAGE, optionalString),
  CDN_DOMAIN: define(ASSETS, z.string().min(1)),
  CDN_KEY_PAIR_ID: define(API, optionalString, { secret: true, requiredInProduction: true }),
  CDN_PRIVATE_KEY: define(API, pem, { secret: true, requiredInProduction: true }),
  CDN_SIGNED_URL_TTL_SEC: define(API, int(300, { min: 30, max: 86_400 })),
  MAX_UPLOAD_MB: define(ASSETS, int(2048, { min: 1 })),
  MEDIACONVERT_ROLE_ARN: define(ASSETS, optionalString),
  MEDIACONVERT_ENDPOINT: define(ASSETS, optionalString),
  MEDIACONVERT_QUEUE_ARN: define(ASSETS, optionalString),
  ANTIVIRUS_MODE: define(ASSETS, z.enum(['disabled', 'clamav', 'lambda']).default('disabled')),
  CLAMAV_HOST: define(ASSETS, z.string().default('localhost')),
  CLAMAV_PORT: define(ASSETS, int(3310)),

  // --- sfu network --------------------------------------------------------
  MEDIA_REGION: define(SFU, awsRegion.default('eu-central-1')),
  /** 0 = one worker per vCPU, capped at 64. */
  MEDIASOUP_WORKERS: define(SFU, int(0, { min: 0, max: MAX_MEDIASOUP_WORKERS })),
  /** Worker i owns UDP and TCP port base + i for its WebRtcServer. */
  MEDIASOUP_RTC_PORT_BASE: define(SFU, int(40_000, { min: 1024, max: 65535 })),
  /** Node-to-node pipe transports, private IPs only, never announced. */
  MEDIASOUP_PIPE_PORT_MIN: define(SFU, int(41_000, { min: 1024, max: 65535 })),
  MEDIASOUP_PIPE_PORT_MAX: define(SFU, int(41_999, { min: 1024, max: 65535 })),
  /** 'imds' reads the Elastic IP from IMDSv2; 'static' uses MEDIA_PUBLIC_IPV4 (dev). */
  MEDIA_PUBLIC_ADDRESS_SOURCE: define(SFU, z.enum(['imds', 'static']).default('static')),
  MEDIA_PUBLIC_IPV4: define(SFU, z.ipv4().optional()),
  /** Empty: derived from the EC2 instance id by NodeRegistrar. */
  SFU_NODE_ID: define(SFU, z.string().max(64).optional().default('')),
  SFU_CONTROL_PORT: define(SFU, int(7443, { min: 1, max: 65535 })),
  SFU_MAX_LOAD_SCORE: define(SFU, int(100, { min: 1 })),
  SFU_DRAIN_TIMEOUT_SEC: define(SFU, int(1_800, { min: 0 })),

  // v6 names still read by the SFU path in this codebase (config/announcedIp.js,
  // config/mediasoup.config.js, classroom/RoomRegistry.js, mediasoup/index.js,
  // mediasoup/health.js). They belong to the v6 per-transport port model and are
  // removed together with it when the SFU moves to WebRtcServer (section 4.3).
  ANNOUNCED_IP: define(SFU, z.ipv4().default('127.0.0.1')),
  MEDIASOUP_MIN_PORT: define(SFU, int(40_000, { min: 1024, max: 65535 })),
  MEDIASOUP_MAX_PORT: define(SFU, int(40_100, { min: 1024, max: 65535 })),
  SFU_MAX_ROOMS_PER_NODE: define(SFU, int(40, { min: 1 })),
  SFU_HTTP_PORT: define(SFU, int(4_200, { min: 1, max: 65535 })),

  // --- sfu control plane: mTLS (secret) -----------------------------------
  SFU_CONTROL_TLS_CERT: define(CONTROL, pem, { secret: true, requiredInProduction: true }),
  SFU_CONTROL_TLS_KEY: define(CONTROL, pem, { secret: true, requiredInProduction: true }),
  SFU_CONTROL_CA: define(CONTROL, pem, { secret: true, requiredInProduction: true }),

  // --- screen sharing and recording ---------------------------------------
  SCREENSHARE_MAX_PRESENTERS: define(CONTROL, int(1, { min: 1, max: 4 })),
  SCREENSHARE_MAX_BITRATE_KBPS: define(CONTROL, int(2_500, { min: 200 })),
  SCREENSHARE_MAX_FRAMERATE: define(CONTROL, int(15, { min: 1, max: 60 })),
  RECORDING_ENABLED: define(ALL, bool(false)),
  RECORDING_RETENTION_DAYS: define(ASSETS, int(90, { min: 1 })),

  // --- ICE issuance (F8) --------------------------------------------------
  /** Zone for turn-<region>-NN names, e.g. rtc.example.com. */
  ICE_RTC_DOMAIN: define(EDGE, z.string().min(1).default('localhost')),
  /** Default 8 h; tenants override within 1–24 h through tenant_rtc_policy. */
  ICE_CREDENTIAL_TTL_S: define(EDGE, int(28_800, { min: 3_600, max: 86_400 })),
  ICE_MAX_URLS: define(EDGE, int(5, { min: 1, max: 5 })),
  ICE_DEFAULT_POLICY: define(EDGE, z.enum(['all', 'relay']).default('all')),
  ICE_ENABLED_TRANSPORTS: define(
    EDGE,
    csv([...TURN_TRANSPORTS]).pipe(z.array(z.enum(TURN_TRANSPORTS)).min(1)),
  ),

  // --- ICE issuance (secret) ----------------------------------------------
  /** AWSCURRENT: signs every credential. */
  TURN_SHARED_SECRET: define(EDGE, optionalString, { secret: true, requiredInProduction: true }),
  /** AWSPREVIOUS: informational during a rotation; never used for signing. */
  TURN_SHARED_SECRET_PREVIOUS: define(EDGE, optionalString, { secret: true }),
  /** HMAC pepper for pseudonymous TURN usernames. */
  ICE_OPAQUE_ID_PEPPER: define(EDGE, optionalString, { secret: true, requiredInProduction: true }),

  // --- realtime -----------------------------------------------------------
  SOCKET_PING_INTERVAL_MS: define(REALTIME, int(25_000)),
  SOCKET_PING_TIMEOUT_MS: define(REALTIME, int(20_000)),
  SOCKET_MAX_EVENTS_PER_MIN: define(REALTIME, int(240, { min: 1 })),
  PRESENCE_TTL_SEC: define(EDGE, int(60, { min: 10 })),

  // --- messaging ----------------------------------------------------------
  CHAT_MAX_MESSAGE_LEN: define(DATA, int(4_000, { min: 1, max: 10_000 })),
  CHAT_RATE_PER_MIN: define(DATA, int(30, { min: 1 })),
  CHAT_ATTACHMENT_MAX_MB: define(DATA, int(100, { min: 1 })),
  CHAT_RETENTION_DAYS: define(DATA, int(0, { min: 0 })),
  CHAT_SLOW_MODE_SEC: define(EDGE, int(0, { min: 0, max: 21_600 })),
  CHAT_EDIT_WINDOW_MIN: define(EDGE, int(15, { min: 0 })),
  CHAT_DEFAULT_DM_POLICY: define(
    EDGE,
    z.enum(['anyone', 'shared-context', 'nobody']).default('shared-context'),
  ),

  // --- notifications ------------------------------------------------------
  MAIL_TRANSPORT: define(WORKER, z.enum(['smtp', 'ses']).default('smtp')),
  SMTP_HOST: define(WORKER, z.string().default('localhost')),
  SMTP_PORT: define(WORKER, int(1025)),
  SES_FROM: define(WORKER, z.email().or(z.string().min(1))),
  SES_REGION: define(WORKER, awsRegion.default('eu-central-1')),
  SNS_PLATFORM_APP_APNS: define(WORKER, optionalString),
  SNS_PLATFORM_APP_FCM: define(WORKER, optionalString),
  NOTIFY_PUSH_DELAY_MIN: define(WORKER, int(2, { min: 0 })),
  DIGEST_SEND_HOUR_UTC: define(WORKER, int(6, { min: 0, max: 23 })),

  // --- billing ------------------------------------------------------------
  STRIPE_SECRET_KEY: define(API, optionalString, { secret: true }),
  STRIPE_WEBHOOK_SECRET: define(API, optionalString, { secret: true }),
  STRIPE_PRICE_MAP: define(
    API,
    z
      .string()
      .default('{}')
      .transform((value, ctx) => {
        try {
          return JSON.parse(value);
        } catch {
          ctx.addIssue({ code: 'custom', message: 'must be a JSON object' });
          return z.NEVER;
        }
      }),
  ),
  BILLING_ENTITLEMENT_TTL_SEC: define(EDGE, int(60, { min: 5 })),

  // --- search -------------------------------------------------------------
  OPENSEARCH_URL: define(ASSETS, optionalString, { secret: true }),
  OPENSEARCH_INDEX_PREFIX: define(ASSETS, z.string().default('classroom')),
  SEARCH_ENABLED: define(ASSETS, bool(false)),

  // --- background work ----------------------------------------------------
  WORKER_CONCURRENCY: define(WORKER, int(5, { min: 1, max: 100 })),
  QUEUE_ATTEMPTS: define(DATA, int(5, { min: 1 })),
  QUEUE_BACKOFF_MS: define(DATA, int(5_000, { min: 100 })),
  QUEUE_KEEP_COMPLETED: define(DATA, int(1_000, { min: 0 })),
  QUEUE_KEEP_FAILED: define(DATA, int(5_000, { min: 0 })),

  // --- observability ------------------------------------------------------
  LOG_LEVEL: define(ALL, z.enum(['trace', 'debug', 'info', 'warn', 'error', 'fatal']).default('info')),
  LOG_PRETTY: define(ALL, bool(false)),
  SERVICE_NAME: define(ALL, (role) => z.string().default(`classroom-${role}`)),
  RELEASE_SHA: define(ALL, z.string().default('local')),
  OTEL_EXPORTER_OTLP_ENDPOINT: define(ALL, optionalString),
  OTEL_TRACES_SAMPLER_ARG: define(ALL, z.coerce.number().min(0).max(1).default(0.1)),
  METRICS_ENABLED: define(ALL, bool(true)),

  // --- limits and hardening -----------------------------------------------
  BODY_LIMIT_KB: define(API, int(256, { min: 1 })),
  RATE_LIMIT_WINDOW_SEC: define(EDGE, int(60, { min: 1 })),
  RATE_LIMIT_MAX_PER_IP: define(EDGE, int(300, { min: 1 })),
  RATE_LIMIT_MAX_PER_USER: define(EDGE, int(600, { min: 1 })),
  SHUTDOWN_GRACE_SEC: define(ALL, int(25, { min: 0 })),
  READINESS_TIMEOUT_MS: define(ALL, int(2_000, { min: 100 })),
});

/** Every variable any role knows. check-env-schema.js compares this with .env.example. */
export const envVariableNames = Object.freeze(Object.keys(variables));

/** Metadata for tooling: which roles receive a variable and whether it is a secret. */
export const envVariables = Object.freeze(
  Object.fromEntries(
    Object.entries(variables).map(([name, { roles, secret }]) => [name, { roles, secret }]),
  ),
);

// ---------------------------------------------------------------------------
// Cross-field rules the individual fields cannot express
// ---------------------------------------------------------------------------

const has = (env, key) => Object.hasOwn(env, key);

const issue = (ctx, path, message) => ctx.addIssue({ code: 'custom', message, path: [path] });

const checkRules = (env, ctx, role) => {
  // mediasoup ports: WebRtcServer range and pipe range must not collide.
  if (has(env, 'MEDIASOUP_RTC_PORT_BASE')) {
    const rtcMin = env.MEDIASOUP_RTC_PORT_BASE;
    const rtcMax = rtcMin + MAX_MEDIASOUP_WORKERS - 1;
    if (rtcMax > 65535) {
      issue(ctx, 'MEDIASOUP_RTC_PORT_BASE', `base + ${MAX_MEDIASOUP_WORKERS - 1} exceeds 65535`);
    }
    if (env.MEDIASOUP_PIPE_PORT_MAX <= env.MEDIASOUP_PIPE_PORT_MIN) {
      issue(ctx, 'MEDIASOUP_PIPE_PORT_MAX', 'must be greater than MEDIASOUP_PIPE_PORT_MIN');
    }
    if (rtcMin <= env.MEDIASOUP_PIPE_PORT_MAX && rtcMax >= env.MEDIASOUP_PIPE_PORT_MIN) {
      issue(
        ctx,
        'MEDIASOUP_PIPE_PORT_MIN',
        `pipe ports overlap the WebRtcServer range ${rtcMin}–${rtcMax}`,
      );
    }
  }

  if (env.MEDIA_PUBLIC_ADDRESS_SOURCE === 'static' && !env.MEDIA_PUBLIC_IPV4) {
    issue(ctx, 'MEDIA_PUBLIC_IPV4', "is required when MEDIA_PUBLIC_ADDRESS_SOURCE is 'static'");
  }

  if (has(env, 'CHAT_ATTACHMENT_MAX_MB') && has(env, 'MAX_UPLOAD_MB')) {
    if (env.CHAT_ATTACHMENT_MAX_MB > env.MAX_UPLOAD_MB) {
      issue(ctx, 'CHAT_ATTACHMENT_MAX_MB', 'cannot exceed MAX_UPLOAD_MB');
    }
  }

  if (has(env, 'SOCKET_PING_TIMEOUT_MS')) {
    if (env.SOCKET_PING_TIMEOUT_MS >= env.SOCKET_PING_INTERVAL_MS * 2) {
      issue(ctx, 'SOCKET_PING_TIMEOUT_MS', 'must stay below twice the ping interval');
    }
  }

  if (env.RECORDING_ENABLED && has(env, 'S3_BUCKET_RECORDINGS') && !env.S3_BUCKET_RECORDINGS) {
    issue(ctx, 'S3_BUCKET_RECORDINGS', 'is required when RECORDING_ENABLED is true');
  }

  if (
    has(env, 'TURN_SHARED_SECRET_PREVIOUS') &&
    env.TURN_SHARED_SECRET_PREVIOUS &&
    env.TURN_SHARED_SECRET_PREVIOUS === env.TURN_SHARED_SECRET
  ) {
    issue(ctx, 'TURN_SHARED_SECRET_PREVIOUS', 'must differ from TURN_SHARED_SECRET');
  }

  if (env.NODE_ENV !== 'production') return;

  // --- production has stricter minimums; development is allowed to be sloppy.

  for (const [name, definition] of Object.entries(variables)) {
    if (!definition.requiredInProduction || !definition.roles.includes(role)) continue;
    if (!env[name]) issue(ctx, name, `is required in production for the ${role} role`);
  }

  if (role === 'api' || role === 'realtime') {
    if (env.ALLOWED_ORIGINS.length === 0) {
      issue(ctx, 'ALLOWED_ORIGINS', 'cannot be empty in production');
    }
    if (env.ALLOWED_ORIGINS.includes('*')) {
      issue(ctx, 'ALLOWED_ORIGINS', 'wildcard origins are not allowed');
    }
    if (env.ICE_RTC_DOMAIN === 'localhost') {
      issue(ctx, 'ICE_RTC_DOMAIN', 'must be the public rtc zone in production');
    }
    for (const name of ['TURN_SHARED_SECRET', 'ICE_OPAQUE_ID_PEPPER']) {
      if (env[name] && env[name].length < 32) issue(ctx, name, 'must be at least 32 characters');
    }
  }

  if (has(env, 'PGSSLMODE') && env.PGSSLMODE === 'disable') {
    issue(ctx, 'PGSSLMODE', 'TLS to the database is mandatory');
  }
  if (!env.REDIS_TLS) {
    issue(ctx, 'REDIS_TLS', 'TLS to Redis is mandatory');
  }
  if (has(env, 'COOKIE_SECURE') && !env.COOKIE_SECURE) {
    issue(ctx, 'COOKIE_SECURE', 'must be true behind HTTPS');
  }
  if (has(env, 'COOKIE_SECRET') && env.COOKIE_SECRET.startsWith('dev-')) {
    issue(ctx, 'COOKIE_SECRET', 'the development cookie secret is still set');
  }
  if (has(env, 'S3_ENDPOINT') && env.S3_ENDPOINT) {
    issue(ctx, 'S3_ENDPOINT', 'is a MinIO setting and must be empty in production');
  }
  if (has(env, 'AWS_ACCESS_KEY_ID') && env.AWS_ACCESS_KEY_ID) {
    issue(ctx, 'AWS_ACCESS_KEY_ID', 'must be empty in production; use the task role');
  }
  if (role === 'sfu') {
    if (env.MEDIA_PUBLIC_ADDRESS_SOURCE !== 'imds') {
      issue(ctx, 'MEDIA_PUBLIC_ADDRESS_SOURCE', "must be 'imds': the Elastic IP comes from IMDSv2");
    }
    if (env.MEDIA_PUBLIC_IPV4) {
      issue(ctx, 'MEDIA_PUBLIC_IPV4', 'is a development setting and must be empty in production');
    }
  }
  if (env.LOG_PRETTY) {
    issue(ctx, 'LOG_PRETTY', 'production logs must be JSON');
  }
};

// ---------------------------------------------------------------------------
// Schemas
// ---------------------------------------------------------------------------

const schemaOf = (definition, role) =>
  typeof definition.schema === 'function' ? definition.schema(role) : definition.schema;

/** The schema for one process role. */
export const envSchemaFor = (role) => {
  if (!SERVICE_ROLES.includes(role)) throw new Error(`Unknown service role: ${role}`);
  const shape = Object.fromEntries(
    Object.entries(variables)
      .filter(([, definition]) => definition.roles.includes(role))
      .map(([name, definition]) => [name, schemaOf(definition, role)]),
  );
  return z.object(shape).superRefine((env, ctx) => checkRules(env, ctx, role));
};

export const envSchemas = Object.freeze(
  Object.fromEntries(SERVICE_ROLES.map((role) => [role, envSchemaFor(role)])),
);

/**
 * Development runs one process for three roles: server.js starts the
 * mediasoup workers and the socket gateways inside the api process. That
 * process therefore receives the realtime and SFU variables too; with only
 * the api schema they were dropped, and every setting of the other two roles
 * read as undefined (socket heartbeat, socket budget, node id, announced IP,
 * port range, room cap).
 *
 * Variables of the api role keep their exact schema. Those of the other two
 * are optional here, so a secret that only a separate SFU or realtime task
 * needs cannot stop a development boot; a value that is present is still
 * validated, and defaults still apply. Production is untouched: one role
 * per process, foreign variables rejected.
 */
const DEV_COMBINED_ROLES = Object.freeze(['api', 'realtime', 'sfu']);

const devCombinedSchema = (() => {
  const shape = {};
  for (const [name, definition] of Object.entries(variables)) {
    if (definition.roles.includes('api')) {
      shape[name] = schemaOf(definition, 'api');
      continue;
    }
    const owner = DEV_COMBINED_ROLES.find((role) => definition.roles.includes(role));
    if (owner) shape[name] = schemaOf(definition, owner).optional();
  }
  return z.object(shape).superRefine((env, ctx) => checkRules(env, ctx, 'api'));
})();

/**
 * The union of every role's variables. For drift detection and tooling only —
 * never used to parse a running process.
 */
export const envSchema = z.object(
  Object.fromEntries(
    Object.entries(variables).map(([name, definition]) => [name, schemaOf(definition, 'api')]),
  ),
);

// ---------------------------------------------------------------------------
// Parse
// ---------------------------------------------------------------------------

/** `FOO=` in a .env file means "not set", not "the empty string" or 0. */
const withoutEmptyValues = (source) =>
  Object.fromEntries(
    Object.entries(source).filter(([, value]) => value !== undefined && value !== ''),
  );

/** Variables present in this process that belong only to other roles. */
const foreignVariables = (source, role) =>
  envVariableNames.filter(
    (name) => Object.hasOwn(source, name) && !variables[name].roles.includes(role),
  );

const failure = (issues) => ({
  success: false,
  error: new z.ZodError(
    issues.map((entry) => ({ code: 'custom', input: undefined, path: [], ...entry })),
  ),
});

/**
 * Exported so tests and ops/scripts/check-env-schema.js can validate an
 * arbitrary object without touching process.env or exiting the process.
 *
 * @param {Record<string, string | undefined>} source
 * @param {string} [role] defaults to SERVICE_ROLE, or the entrypoint's role
 */
export const parseEnv = (source = process.env, role) => {
  let resolvedRole = role;
  if (!resolvedRole) {
    try {
      resolvedRole = resolveServiceRole(source);
    } catch (cause) {
      return failure([{ path: ['SERVICE_ROLE'], message: cause.message }]);
    }
  }
  if (!SERVICE_ROLES.includes(resolvedRole)) {
    return failure([
      { path: ['SERVICE_ROLE'], message: `must be one of ${SERVICE_ROLES.join(', ')}` },
    ]);
  }

  const input = { ...withoutEmptyValues(source), SERVICE_ROLE: resolvedRole };
  const combined = resolvedRole === 'api' && input.NODE_ENV !== 'production';
  const result = (combined ? devCombinedSchema : envSchemas[resolvedRole]).safeParse(input);

  // A shared development .env feeds every role; only production is strict.
  if (input.NODE_ENV !== 'production') return result;

  const foreign = foreignVariables(input, resolvedRole);
  if (foreign.length === 0) return result;

  return failure([
    ...(result.success ? [] : result.error.issues),
    ...foreign.map((name) => ({
      path: [name],
      message: `does not belong to the ${resolvedRole} role; remove it from this task definition`,
    })),
  ]);
};

// ---------------------------------------------------------------------------
// Parse, or die
// ---------------------------------------------------------------------------

const result = parseEnv();

if (!result.success) {
  // Deliberately console, not the logger: the logger is configured from the
  // very values that just failed to parse. Paths and messages only, never values.
  const issues = result.error.issues
    .map((entry) => `  ${entry.path.join('.') || '(root)'}: ${entry.message}`)
    .join('\n');

  console.error(
    [
      '',
      'Invalid environment configuration. The process will not start.',
      '',
      issues,
      '',
      'Compare your environment against .env.example.',
      '',
    ].join('\n'),
  );
  process.exit(78); // EX_CONFIG
}

export const env = Object.freeze(result.data);

export const serviceRole = env.SERVICE_ROLE;

// Convenience flags, so nothing has to compare strings in a hot path.
export const isProduction = env.NODE_ENV === 'production';
export const isTest = env.NODE_ENV === 'test';
export const isDevelopment = env.NODE_ENV === 'development';

export const isApi = serviceRole === 'api';
export const isRealtime = serviceRole === 'realtime';
export const isSfu = serviceRole === 'sfu';
export const isWorker = serviceRole === 'worker';

export default env;