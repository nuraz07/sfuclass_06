/**
 * server/src/config/publicAddress.js
 *
 * Resolves the addresses a media node announces in ICE.  (F8)
 * Replaces v6's announcedIp.js.
 *
 * On AWS the instance never sees its Elastic IP on an interface: the EIP is
 * 1:1 NATed onto the private IPv4 address. So the socket has to bind to the
 * private address while mediasoup announces the public one. Both values come
 * from IMDSv2 — token-authenticated, hop limit 1, no credentials involved.
 *
 * IPv6, when the subnet is dual-stack, is a real address on the interface:
 * bind and announce are the same value, so it is returned separately.
 *
 * Contract:
 *   - resolve() is idempotent and cached; concurrent callers share one flight.
 *   - it NEVER falls back to a guess. If the public address cannot be
 *     determined, the process fails readiness (sfu.js / turn agent both treat
 *     a rejection as fatal). A node announcing a wrong address is worse than a
 *     node that does not start: every ICE check against it would fail.
 *   - MEDIA_PUBLIC_ADDRESS_SOURCE=static + MEDIA_PUBLIC_IPV4 is the documented
 *     escape hatch for docker-compose.dev.yml and bare-metal fallback. It is
 *     rejected when NODE_ENV=production.
 *
 * Node.js 22, ESM. Uses global fetch + AbortSignal.timeout — no dependencies.
 */

import { env } from './env.js';
import { logger } from '../observability/logger.js';

const log = logger.child({ component: 'publicAddress' });

const IMDS_BASE = 'http://169.254.169.254';
const TOKEN_TTL_SECONDS = 21_600; // 6 h, the IMDSv2 maximum
const REQUEST_TIMEOUT_MS = 1_000; // link-local; anything slower is a failure
const RETRIES = 3;
const RETRY_BASE_DELAY_MS = 150;

/**
 * @typedef {object} ResolvedAddress
 * @property {string}  privateIp    bind address for UDP/TCP sockets
 * @property {string}  publicIpv4   announcedAddress in ICE candidates
 * @property {string|null} publicIpv6 announced *and* bound, dual-stack only
 * @property {string|null} instanceId
 * @property {string|null} availabilityZone
 * @property {string|null} region
 * @property {'imds'|'static'} source
 * @property {number}  resolvedAt   epoch ms
 */

/** @type {ResolvedAddress|null} */
let cached = null;
/** @type {Promise<ResolvedAddress>|null} */
let inFlight = null;

/* -------------------------------------------------------------------------- */
/* Public API                                                                  */
/* -------------------------------------------------------------------------- */

/**
 * Resolve the node's addresses. Cached after the first success.
 * @param {{ force?: boolean }} [opts]
 * @returns {Promise<ResolvedAddress>}
 */
export async function resolve({ force = false } = {}) {
  if (cached && !force) return cached;
  if (inFlight && !force) return inFlight;

  inFlight = (async () => {
    const result =
      env.MEDIA_PUBLIC_ADDRESS_SOURCE === 'static'
        ? resolveStatic()
        : await resolveFromImds();

    cached = result;
    log.info(
      {
        source: result.source,
        privateIp: result.privateIp,
        publicIpv4: result.publicIpv4,
        publicIpv6: result.publicIpv6,
        availabilityZone: result.availabilityZone,
      },
      'public address resolved',
    );
    return result;
  })();

  try {
    return await inFlight;
  } finally {
    inFlight = null;
  }
}

/**
 * Synchronous accessor for code paths that run after boot (health checks,
 * transport creation, node registration).
 * @returns {ResolvedAddress}
 */
export function get() {
  if (!cached) {
    throw new Error('publicAddress.get() called before resolve() completed');
  }
  return cached;
}

/** @returns {boolean} true once resolve() has succeeded. */
export function isResolved() {
  return cached !== null;
}

/**
 * Re-checks that the announced IPv4 is still attached to this instance.
 * Called by mediasoup/health.js: an EIP that got reassociated during an
 * instance refresh must take the node out of the registry immediately.
 * @returns {Promise<boolean>}
 */
export async function verify() {
  if (!cached) return false;
  if (cached.source === 'static') return true;
  try {
    const token = await getToken();
    const current = await imdsGet('/latest/meta-data/public-ipv4', token);
    return current.trim() === cached.publicIpv4;
  } catch (err) {
    log.warn({ err }, 'public address verification failed');
    return false;
  }
}

/** Test seam. */
export function reset() {
  cached = null;
  inFlight = null;
}

export default { resolve, get, isResolved, verify, reset };

/* -------------------------------------------------------------------------- */
/* Static source (development / single-node fallback)                          */
/* -------------------------------------------------------------------------- */

function resolveStatic() {
  if (env.NODE_ENV === 'production') {
    throw new Error(
      'MEDIA_PUBLIC_ADDRESS_SOURCE=static is not allowed in production; ' +
        'media nodes must read their Elastic IP from IMDSv2',
    );
  }

  const publicIpv4 = env.MEDIA_PUBLIC_IPV4;
  if (!publicIpv4) {
    throw new Error(
      'MEDIA_PUBLIC_ADDRESS_SOURCE=static requires MEDIA_PUBLIC_IPV4 ' +
        '(your machine LAN IP, e.g. 192.168.1.42)',
    );
  }

  return /** @type {ResolvedAddress} */ ({
    // With host networking in compose, bind to all interfaces and announce the
    // LAN address so a phone on the same Wi-Fi can reach the dev SFU.
    privateIp: env.MEDIA_PRIVATE_IPV4 ?? '0.0.0.0',
    publicIpv4,
    publicIpv6: env.MEDIA_PUBLIC_IPV6 ?? null,
    instanceId: 'dev-local',
    availabilityZone: null,
    region: env.MEDIA_REGION ?? 'dev',
    source: 'static',
    resolvedAt: Date.now(),
  });
}

/* -------------------------------------------------------------------------- */
/* IMDSv2                                                                      */
/* -------------------------------------------------------------------------- */

/** @returns {Promise<ResolvedAddress>} */
async function resolveFromImds() {
  const token = await withRetry('imds-token', () => fetchToken());

  const [privateIp, publicIpv4, az, instanceId] = await Promise.all([
    withRetry('local-ipv4', () => imdsGet('/latest/meta-data/local-ipv4', token)),
    withRetry('public-ipv4', () => imdsGet('/latest/meta-data/public-ipv4', token)),
    withRetry('az', () => imdsGet('/latest/meta-data/placement/availability-zone', token)),
    withRetry('instance-id', () => imdsGet('/latest/meta-data/instance-id', token)).catch(
      () => null,
    ),
  ]);

  const publicIpv6 = await resolveIpv6(token).catch(() => null);

  const resolved = {
    privateIp: assertIpv4(privateIp.trim(), 'local-ipv4'),
    publicIpv4: assertIpv4(publicIpv4.trim(), 'public-ipv4'),
    publicIpv6,
    instanceId: instanceId?.trim() ?? null,
    availabilityZone: az.trim(),
    region: az.trim().replace(/[a-z]$/, ''),
    source: /** @type {'imds'} */ ('imds'),
    resolvedAt: Date.now(),
  };

  if (env.MEDIA_REGION && resolved.region !== env.MEDIA_REGION) {
    throw new Error(
      `region mismatch: instance runs in ${resolved.region} but MEDIA_REGION=${env.MEDIA_REGION}`,
    );
  }

  return resolved;
}

/**
 * IPv6 lives under the interface MAC, not at the top level.
 * Returns null on single-stack subnets — that is not an error.
 * @param {string} token
 * @returns {Promise<string|null>}
 */
async function resolveIpv6(token) {
  const macs = await imdsGet('/latest/meta-data/network/interfaces/macs/', token);
  const primaryMac = macs.split('\n').map((l) => l.trim()).filter(Boolean)[0];
  if (!primaryMac) return null;

  const path = `/latest/meta-data/network/interfaces/macs/${primaryMac}ipv6s`;
  const raw = await imdsGet(path, token).catch(() => '');
  const first = raw.split('\n').map((l) => l.trim()).filter(Boolean)[0];
  if (!first) return null;

  return assertIpv6(first, 'ipv6s');
}

/* -------------------------------------------------------------------------- */
/* Low-level IMDS helpers                                                      */
/* -------------------------------------------------------------------------- */

/** @type {{ value: string, expiresAt: number }|null} */
let tokenCache = null;

async function getToken() {
  if (tokenCache && tokenCache.expiresAt > Date.now() + 60_000) {
    return tokenCache.value;
  }
  return fetchToken();
}

async function fetchToken() {
  const res = await fetch(`${IMDS_BASE}/latest/api/token`, {
    method: 'PUT',
    headers: { 'x-aws-ec2-metadata-token-ttl-seconds': String(TOKEN_TTL_SECONDS) },
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  });

  if (!res.ok) {
    throw new Error(`IMDSv2 token request failed with HTTP ${res.status}`);
  }

  const value = (await res.text()).trim();
  tokenCache = { value, expiresAt: Date.now() + TOKEN_TTL_SECONDS * 1_000 };
  return value;
}

/**
 * @param {string} path
 * @param {string} token
 * @returns {Promise<string>}
 */
async function imdsGet(path, token) {
  const res = await fetch(`${IMDS_BASE}${path}`, {
    headers: { 'x-aws-ec2-metadata-token': token },
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  });

  if (res.status === 404) {
    throw new Error(`IMDS path ${path} not available (404)`);
  }
  if (!res.ok) {
    throw new Error(`IMDS path ${path} failed with HTTP ${res.status}`);
  }

  return res.text();
}

/**
 * @template T
 * @param {string} label
 * @param {() => Promise<T>} fn
 * @returns {Promise<T>}
 */
async function withRetry(label, fn) {
  let lastErr;
  for (let attempt = 0; attempt < RETRIES; attempt += 1) {
    try {
      return await fn();
    } catch (err) {
      lastErr = err;
      // A 404 is a definitive answer (no public IP attached yet / no IPv6):
      // retrying it only delays the failure.
      if (String(err?.message ?? '').includes('(404)')) break;
      const delay = RETRY_BASE_DELAY_MS * 2 ** attempt;
      log.debug({ label, attempt, delay, err }, 'IMDS retry');
      await sleep(delay);
    }
  }
  throw new Error(`IMDS lookup "${label}" failed: ${lastErr?.message ?? lastErr}`, {
    cause: lastErr,
  });
}

/* -------------------------------------------------------------------------- */
/* Validation                                                                  */
/* -------------------------------------------------------------------------- */

const IPV4_RE = /^(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$/;

function assertIpv4(value, label) {
  if (!IPV4_RE.test(value)) {
    throw new Error(`IMDS returned an invalid IPv4 for ${label}: ${JSON.stringify(value)}`);
  }
  return value;
}

function assertIpv6(value, label) {
  // Node's URL parser is the cheapest correct IPv6 validator available here.
  try {
    // eslint-disable-next-line no-new
    new URL(`http://[${value}]`);
  } catch {
    throw new Error(`IMDS returned an invalid IPv6 for ${label}: ${JSON.stringify(value)}`);
  }
  return value;
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms).unref());
}