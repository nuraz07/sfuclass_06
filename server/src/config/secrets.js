// classroom-app/server/src/config/secrets.js
/**
 * Secrets loader  (F7, F8)  [EXT]
 *
 * Pulls secrets from AWS Secrets Manager and puts them into process.env before
 * config/env.js is imported. That ordering is the entire design:
 *
 *   bootstrap  →  hydrateSecrets()  →  import('./config/env.js')  →  everything else
 *
 * Which is why server.js, realtime.js, sfu.js and worker.js import env.js
 * dynamically. A static import would run env validation before the secrets
 * exist.
 *
 * Version 7:
 *
 *   - Role-scoped. Each process role (api · realtime · sfu · worker) fetches
 *     only the secrets it needs. The SFU never receives a TURN secret, a JWT
 *     key or a database URL; a secret a role does not list cannot leak into it
 *     through a misconfigured task definition.
 *
 *   - TURN secret ring. The TURN REST shared secret is fetched with its
 *     Secrets Manager staging labels: AWSCURRENT signs, AWSPREVIOUS is kept for
 *     the rotation runbook and the auth-failure alarm. Only the api and
 *     realtime roles hold it — api for POST /rtc/ice-servers, realtime because
 *     the ICE configuration is embedded in the room.join acknowledgement.
 *     TurnSecretRing.js reads it through getTurnSecretRing() with a 60 s cache,
 *     which is what makes phase 2 of the rotation reach every task within a
 *     minute without a restart.
 *
 *   - ICE opaque-id pepper and the SFU control-plane mTLS material are managed
 *     here as well.
 *
 * Why not put secrets straight into the task definition? Because a task
 * definition is a versioned, readable document, and a rotated secret would mean
 * a new revision and a redeploy. Here a rotation is a new secret version and,
 * at most, a restart; the value never appears in an image, in git or in the
 * console.
 *
 * Locally this is a no-op: there is no Secrets Manager, .env already holds
 * development values, and nothing here should require AWS credentials to run
 * `npm run dev`.
 *
 * Service-role resolution lives in this module, not in env.js, because this
 * module runs first and must stay free of import-time side effects. env.js
 * imports it from here.
 */

import { basename } from 'node:path';

// ---------------------------------------------------------------------------
// Service roles
// ---------------------------------------------------------------------------

export const SERVICE_ROLES = Object.freeze(['api', 'realtime', 'sfu', 'worker']);

const ENTRYPOINT_ROLES = Object.freeze({
  'server.js': 'api',
  'realtime.js': 'realtime',
  'sfu.js': 'sfu',
  'worker.js': 'worker',
});

/** The role implied by the script node was started with, or null. */
export const roleFromEntrypoint = (argv = process.argv) => {
  const script = argv[1] ? basename(argv[1]) : '';
  return ENTRYPOINT_ROLES[script] ?? null;
};

/**
 * SERVICE_ROLE wins; the entrypoint is the fallback and the cross-check. A task
 * definition that starts sfu.js with SERVICE_ROLE=api is a deployment mistake
 * and is refused rather than guessed around.
 *
 * @returns {'api' | 'realtime' | 'sfu' | 'worker'}
 */
export const resolveServiceRole = (source = process.env, argv = process.argv) => {
  const declared = source.SERVICE_ROLE || null;
  const inferred = roleFromEntrypoint(argv);

  if (declared && inferred && declared !== inferred) {
    throw new Error(
      `SERVICE_ROLE is "${declared}" but the entrypoint starts the ${inferred} process`,
    );
  }

  const role = declared ?? inferred;
  if (!role) {
    throw new Error('SERVICE_ROLE is not set and cannot be inferred from the entrypoint');
  }
  if (!SERVICE_ROLES.includes(role)) {
    throw new Error(`SERVICE_ROLE must be one of ${SERVICE_ROLES.join(', ')}; got "${role}"`);
  }
  return role;
};

// ---------------------------------------------------------------------------
// Secret table
// ---------------------------------------------------------------------------

const ALL = SERVICE_ROLES;
const EDGE = ['api', 'realtime'];
const DATA = ['api', 'realtime', 'worker'];
const CONTROL = ['sfu', 'realtime'];

/**
 * @param {string} variable   environment variable the value lands in
 * @param {string} template   secret name; {env} = deployment, {role} = process role
 * @param {readonly string[]} roles
 * @param {{ required?: boolean }} [options] required: fatal when missing in production
 */
const secret = (variable, template, roles, { required = false } = {}) =>
  Object.freeze({ variable, template, roles: Object.freeze([...roles]), required });

/**
 * Environment variable ← secret name. Only these are ever fetched.
 *
 * `{env}` is the deployment environment, so one table serves staging and
 * production. `{role}` separates per-role material: the SFU's control-plane
 * server certificate and the realtime service's client certificate are
 * different secrets under the same variable name.
 *
 * Media regions read their secrets from regional replicas with the same names
 * (infra/media-edge/secrets-replica.tf), so AWS_REGION of the task is right
 * for every role.
 */
const SECRET_MAP = Object.freeze([
  // --- auth ---------------------------------------------------------------
  secret('JWT_PRIVATE_KEY', 'classroom/{env}/jwt/private-key', ['api'], { required: true }),
  secret('JWT_PUBLIC_KEY', 'classroom/{env}/jwt/public-key', EDGE, { required: true }),
  secret('COOKIE_SECRET', 'classroom/{env}/cookie-secret', ['api'], { required: true }),

  // --- data ---------------------------------------------------------------
  secret('DATABASE_URL', 'classroom/{env}/database/url', DATA, { required: true }),
  secret('DATABASE_READ_URL', 'classroom/{env}/database/read-url', DATA),
  secret('REDIS_STATE_URL', 'classroom/{env}/redis/state-url', ALL, { required: true }),
  secret('REDIS_CACHE_URL', 'classroom/{env}/redis/cache-url', DATA, { required: true }),
  secret('OPENSEARCH_URL', 'classroom/{env}/opensearch/url', ['api', 'worker']),

  // --- delivery and billing -----------------------------------------------
  secret('CDN_PRIVATE_KEY', 'classroom/{env}/cdn/private-key', ['api'], { required: true }),
  secret('CDN_KEY_PAIR_ID', 'classroom/{env}/cdn/key-pair-id', ['api'], { required: true }),
  secret('STRIPE_SECRET_KEY', 'classroom/{env}/stripe/secret-key', ['api']),
  secret('STRIPE_WEBHOOK_SECRET', 'classroom/{env}/stripe/webhook-secret', ['api']),

  // --- connectivity (F8) --------------------------------------------------
  secret('ICE_OPAQUE_ID_PEPPER', 'classroom/{env}/ice/opaque-id-pepper', EDGE, {
    required: true,
  }),

  // --- SFU control plane: mTLS between realtime and SFU nodes -------------
  secret('SFU_CONTROL_TLS_CERT', 'classroom/{env}/sfu-control/{role}/tls-cert', CONTROL, {
    required: true,
  }),
  secret('SFU_CONTROL_TLS_KEY', 'classroom/{env}/sfu-control/{role}/tls-key', CONTROL, {
    required: true,
  }),
  secret('SFU_CONTROL_CA', 'classroom/{env}/sfu-control/ca', CONTROL, { required: true }),
]);

/**
 * The TURN REST shared secret, with both staging labels. The rotation Lambda
 * (functions/turn-secret-rotation) moves AWSCURRENT in phase 2; the previous
 * version keeps its AWSPREVIOUS label until phase 3.
 */
const TURN_SECRET_RING = Object.freeze({
  template: 'classroom/{env}/turn/shared-secret',
  roles: Object.freeze([...EDGE]),
  currentVariable: 'TURN_SHARED_SECRET',
  previousVariable: 'TURN_SHARED_SECRET_PREVIOUS',
});

const MIN_TURN_SECRET_LENGTH = 32;

// ---------------------------------------------------------------------------
// Secrets Manager access
// ---------------------------------------------------------------------------

const CACHE_TTL_MS = 5 * 60_000;
/** Phase 2 of a rotation must reach every task within a minute. */
const RING_CACHE_TTL_MS = 60_000;

const cache = new Map(); // `${name}@${stage}` -> { value, versionId, fetchedAt }

let client = null;

/**
 * The SDK is imported lazily so a development machine never loads it, and so a
 * missing dependency cannot break `npm run dev`.
 */
const getClient = async (region) => {
  if (client) return client;
  const { SecretsManagerClient } = await import('@aws-sdk/client-secrets-manager');
  client = new SecretsManagerClient({ region });
  return client;
};

const isNotFound = (cause) =>
  cause?.name === 'ResourceNotFoundException' ||
  // Requesting a staging label no version carries.
  (cause?.name === 'InvalidRequestException' && /staging label/i.test(cause?.message ?? ''));

/**
 * @returns {Promise<{ value: string, versionId: string | null } | null>} null only
 *   when `optional` is set and the secret or the stage does not exist.
 */
const fetchSecret = async (
  name,
  region,
  { versionStage = 'AWSCURRENT', bypassCache = false, optional = false, ttlMs = CACHE_TTL_MS } = {},
) => {
  const key = `${name}@${versionStage}`;
  const cached = cache.get(key);
  if (!bypassCache && cached && Date.now() - cached.fetchedAt < ttlMs) return cached;

  const { GetSecretValueCommand } = await import('@aws-sdk/client-secrets-manager');
  const sm = await getClient(region);

  let response;
  try {
    response = await sm.send(new GetSecretValueCommand({ SecretId: name, VersionStage: versionStage }));
  } catch (cause) {
    if (optional && isNotFound(cause)) return null;
    throw cause;
  }

  // Binary secrets arrive as bytes in SecretBinary; string secrets are plain.
  const value =
    response.SecretString ??
    (response.SecretBinary ? Buffer.from(response.SecretBinary).toString('utf8') : null);

  if (value === null) throw new Error(`Secret ${name} (${versionStage}) has no value`);

  const entry = { value, versionId: response.VersionId ?? null, fetchedAt: Date.now() };
  cache.set(key, entry);
  return entry;
};

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

const resolveOptions = (options = {}) => ({
  role: options.role ?? resolveServiceRole(),
  environment:
    options.environment ??
    (process.env.DEPLOY_ENV || undefined) ??
    process.env.NODE_ENV ??
    'development',
  region: options.region ?? process.env.AWS_REGION ?? 'eu-central-1',
  // Default off outside AWS: no calls, no credentials needed.
  enabled: options.enabled ?? process.env.SECRETS_SOURCE === 'aws',
  // Staging runs with NODE_ENV=production as well, and is held to the same bar.
  production: (options.nodeEnv ?? process.env.NODE_ENV) === 'production',
});

const render = (template, { environment, role }) =>
  template.replaceAll('{env}', environment).replaceAll('{role}', role);

/** Every variable this module can fill for a role. */
export const secretsForRole = (role) =>
  Object.freeze([
    ...SECRET_MAP.filter((entry) => entry.roles.includes(role)).map((entry) => entry.variable),
    ...(TURN_SECRET_RING.roles.includes(role)
      ? [TURN_SECRET_RING.currentVariable, TURN_SECRET_RING.previousVariable]
      : []),
  ]);

// ---------------------------------------------------------------------------
// Boot-time hydration
// ---------------------------------------------------------------------------

/**
 * Fetches every secret the current role needs and writes it into process.env.
 *
 * An existing environment variable always wins. That is what lets a deployment
 * override one value without editing the table, and what lets tests inject
 * fakes without touching AWS.
 *
 * @param {{ role?: string, environment?: string, region?: string, enabled?: boolean, nodeEnv?: string }} options
 * @returns {Promise<{ role: string, loaded: string[], skipped: string[] }>}
 */
export const hydrateSecrets = async (options = {}) => {
  let resolved;
  try {
    resolved = resolveOptions(options);
  } catch (cause) {
    console.error(`\nCannot determine the service role: ${cause.message}\n`);
    process.exit(78); // EX_CONFIG
  }

  const { role, environment, region, enabled, production } = resolved;
  const wanted = SECRET_MAP.filter((entry) => entry.roles.includes(role));
  const wantsRing = TURN_SECRET_RING.roles.includes(role);

  if (!enabled) {
    return { role, loaded: [], skipped: [...secretsForRole(role)] };
  }

  const loaded = [];
  const skipped = [];
  const failures = [];

  const load = async (variable, name, { required, versionStage, optional }) => {
    if (process.env[variable]) {
      skipped.push(variable);
      return;
    }
    try {
      const entry = await fetchSecret(name, region, { versionStage, optional });
      if (entry === null) {
        skipped.push(variable);
        return;
      }
      process.env[variable] = entry.value;
      loaded.push(variable);
    } catch (cause) {
      failures.push({ variable, name, required, message: cause?.message ?? 'unknown error' });
    }
  };

  // Parallel: a dozen sequential round trips would add real seconds to a cold
  // start, and a cold start happens on every scale-out event.
  const tasks = wanted.map((entry) =>
    load(entry.variable, render(entry.template, { environment, role }), {
      required: entry.required,
    }),
  );

  if (wantsRing) {
    const ringName = render(TURN_SECRET_RING.template, { environment, role });
    tasks.push(
      load(TURN_SECRET_RING.currentVariable, ringName, {
        required: true,
        versionStage: 'AWSCURRENT',
      }),
      // Absent until the first rotation; that is normal.
      load(TURN_SECRET_RING.previousVariable, ringName, {
        required: false,
        versionStage: 'AWSPREVIOUS',
        optional: true,
      }),
    );
  }

  await Promise.all(tasks);

  const fatal = failures.filter((failure) => production && failure.required);

  if (fatal.length > 0) {
    // console, not the logger: the logger is not configured yet. Names only,
    // never values.
    console.error(
      [
        '',
        `Could not load required secrets for the ${role} role. The process will not start.`,
        ...fatal.map((failure) => `  ${failure.variable} (${failure.name}): ${failure.message}`),
        '',
      ].join('\n'),
    );
    process.exit(78); // EX_CONFIG, same as an invalid environment
  }

  for (const failure of failures) {
    if (fatal.includes(failure)) continue;
    console.warn(`secret unavailable: ${failure.variable} (${failure.message})`);
  }

  return { role, loaded, skipped };
};

// ---------------------------------------------------------------------------
// TURN secret ring (api and realtime only)
// ---------------------------------------------------------------------------

let ringCache = null; // { ring, fetchedAt }
let ringInFlight = null;

const assertRingRole = (role) => {
  if (!TURN_SECRET_RING.roles.includes(role)) {
    throw new Error(
      `The TURN secret ring is only available to the ${TURN_SECRET_RING.roles.join(' and ')} roles`,
    );
  }
};

const validRingSecret = (value, label) => {
  if (!value || value.length < MIN_TURN_SECRET_LENGTH) {
    throw new Error(`TURN ${label} secret is missing or shorter than ${MIN_TURN_SECRET_LENGTH} characters`);
  }
  return value;
};

/**
 * The signing view of the TURN shared secret, used by TurnSecretRing.js.
 *
 *   current   signs every new credential (AWSCURRENT)
 *   previous  still accepted by TURN nodes until phase 3 (AWSPREVIOUS), or null
 *
 * Cached for 60 s. When Secrets Manager is unreachable and a ring is cached,
 * the stale ring is returned: every value in it stays valid on the TURN nodes
 * for at least the 24 h between phase 2 and phase 3 of a rotation.
 *
 * Without Secrets Manager (development) the ring comes from the environment.
 *
 * @param {{ force?: boolean, role?: string, environment?: string, region?: string, enabled?: boolean }} options
 * @returns {Promise<Readonly<{
 *   current: { secret: string, versionId: string },
 *   previous: { secret: string, versionId: string } | null,
 *   fetchedAt: number
 * }>>}
 */
export const getTurnSecretRing = async (options = {}) => {
  const { role, environment, region, enabled } = resolveOptions(options);
  assertRingRole(role);

  if (!enabled) {
    return Object.freeze({
      current: {
        secret: validRingSecret(process.env[TURN_SECRET_RING.currentVariable], 'current'),
        versionId: 'env',
      },
      previous: process.env[TURN_SECRET_RING.previousVariable]
        ? { secret: process.env[TURN_SECRET_RING.previousVariable], versionId: 'env-previous' }
        : null,
      fetchedAt: Date.now(),
    });
  }

  if (!options.force && ringCache && Date.now() - ringCache.fetchedAt < RING_CACHE_TTL_MS) {
    return ringCache.ring;
  }
  if (ringInFlight) return ringInFlight;

  const name = render(TURN_SECRET_RING.template, { environment, role });

  ringInFlight = (async () => {
    try {
      const [current, previous] = await Promise.all([
        fetchSecret(name, region, {
          versionStage: 'AWSCURRENT',
          bypassCache: true,
          ttlMs: RING_CACHE_TTL_MS,
        }),
        fetchSecret(name, region, {
          versionStage: 'AWSPREVIOUS',
          bypassCache: true,
          optional: true,
          ttlMs: RING_CACHE_TTL_MS,
        }),
      ]);

      const ring = Object.freeze({
        current: Object.freeze({
          secret: validRingSecret(current.value, 'current'),
          versionId: current.versionId ?? 'unknown',
        }),
        previous: previous
          ? Object.freeze({ secret: previous.value, versionId: previous.versionId ?? 'unknown' })
          : null,
        fetchedAt: Date.now(),
      });

      ringCache = { ring, fetchedAt: ring.fetchedAt };
      return ring;
    } catch (cause) {
      if (ringCache) {
        console.warn(`TURN secret ring refresh failed, serving cached ring: ${cause?.message}`);
        return ringCache.ring;
      }
      throw cause;
    } finally {
      ringInFlight = null;
    }
  })();

  return ringInFlight;
};

// ---------------------------------------------------------------------------
// Manual refresh
// ---------------------------------------------------------------------------

/**
 * Re-reads one secret, bypassing the cache. Used by a rotation handler that
 * wants to pick up a new value without a restart; nothing calls it on a timer,
 * because a rotation is rare and a restart is cheap. The TURN ring refreshes
 * itself through getTurnSecretRing() and is handled here only for completeness.
 */
export const refreshSecret = async (variable, options = {}) => {
  const resolved = resolveOptions({ ...options, enabled: true });

  if (
    variable === TURN_SECRET_RING.currentVariable ||
    variable === TURN_SECRET_RING.previousVariable
  ) {
    const ring = await getTurnSecretRing({ ...options, enabled: true, force: true });
    const value =
      variable === TURN_SECRET_RING.currentVariable ? ring.current.secret : ring.previous?.secret;
    if (value) process.env[variable] = value;
    return value ?? null;
  }

  const entry = SECRET_MAP.find((candidate) => candidate.variable === variable);
  if (!entry) throw new Error(`${variable} is not a managed secret`);
  if (!entry.roles.includes(resolved.role)) {
    throw new Error(`${variable} does not belong to the ${resolved.role} role`);
  }

  const name = render(entry.template, resolved);
  const { value } = await fetchSecret(name, resolved.region, { bypassCache: true });
  process.env[variable] = value;
  return value;
};

/** Exported for the CI check and for tests; never mutated at runtime. */
export const managedSecrets = Object.freeze([
  ...SECRET_MAP.map((entry) => entry.variable),
  TURN_SECRET_RING.currentVariable,
  TURN_SECRET_RING.previousVariable,
]);

export default hydrateSecrets;