// server/src/config/publicAddress.js
//
// Replaces v6 announcedIp.js. Resolves the network identity of an SFU node — the address mediasoup announces in its
// ICE candidates — and refuses to return anything a client could not reach.
//
//   source 'imds'    (AWS, default)  IMDSv2 only:
//                      local-ipv4                   listen address (host networking)
//                      public-ipv4                  must equal the instance tag SfuPublicIp, which the node-lifecycle
//                                                   Lambda writes after associating the node's Elastic IP from the pool
//                                                   (infra/functions/node-lifecycle). Until then the instance still has
//                                                   its transient auto-assigned address, which is in no published range,
//                                                   no prefix list and no customer allowlist — so we wait.
//                      ipv6                         optional, only when the subnet is dual-stack
//                      instance-id, placement/availability-zone
//   source 'static'  (docker-compose.dev.yml, tests)  MEDIA_PUBLIC_IPV4 as announced address, the first non-internal
//                    IPv4 of the host as listen address
//
// Contract with server/src/sfu.js:
//   resolvePublicAddress({ source, staticIpv4, logger }) →
//     { instanceId, availabilityZone, privateIp, publicIpv4, publicIpv6? }
//   instanceId is lowercase [a-z0-9-] so that nodeId "sfu-<region>-<instanceId>" passes the registry schema
//   (sfu-node/NodeRegistrar.js) and matches the drain flag the node-lifecycle function writes.
//
// Owner: F8 Real-Time Connectivity + F1 Live Classrooms.

import { isIPv4, isIPv6 } from 'node:net';
import { networkInterfaces, hostname } from 'node:os';
import { setTimeout as sleep } from 'node:timers/promises';

const IMDS = 'http://169.254.169.254';
const TOKEN_TTL_SECONDS = 21_600;

/** Private, shared, loopback, link-local, documentation and other non-routable IPv4 ranges are not public. */
export function isPublicIpv4(ip) {
  if (!isIPv4(ip ?? '')) return false;
  const [a, b, c] = ip.split('.').map(Number);
  if (a === 0 || a === 10 || a === 127 || a >= 224) return false;
  if (a === 100 && b >= 64 && b <= 127) return false; // CGNAT
  if (a === 169 && b === 254) return false; // link-local
  if (a === 172 && b >= 16 && b <= 31) return false;
  if (a === 192 && b === 168) return false;
  if (a === 192 && b === 0 && (c === 0 || c === 2)) return false; // IETF assignments, TEST-NET-1
  if (a === 198 && (b === 18 || b === 19)) return false; // benchmarking
  if (a === 198 && b === 51 && c === 100) return false; // TEST-NET-2
  if (a === 203 && b === 0 && c === 113) return false; // TEST-NET-3
  return true;
}

function addressError(message) {
  const err = new Error(message);
  err.code = 'PUBLIC_ADDRESS_UNAVAILABLE';
  return err;
}

/**
 * @param {object} options
 * @param {'imds'|'static'} [options.source='imds']
 * @param {string} [options.staticIpv4]            MEDIA_PUBLIC_IPV4 (static source only)
 * @param {{ info: Function, warn: Function }} [options.logger]
 * @param {number} [options.waitSeconds=300]       how long to wait for the Elastic IP (imds)
 * @param {number} [options.pollMs=5000]
 * @param {string} [options.endpoint]              IMDS base URL (tests)
 * @param {typeof fetch} [options.fetchImpl]
 * @returns {Promise<{ instanceId: string, availabilityZone: string, privateIp: string, publicIpv4: string, publicIpv6?: string }>}
 */
export async function resolvePublicAddress({
  source = 'imds',
  staticIpv4,
  logger = console,
  waitSeconds = 300,
  pollMs = 5_000,
  endpoint = IMDS,
  fetchImpl = fetch,
} = {}) {
  if (source === 'static') return resolveStatic({ staticIpv4, logger });
  if (source !== 'imds') throw addressError(`unknown public address source '${source}'`);

  const imds = createImdsClient({ endpoint, fetchImpl });
  const [instanceId, availabilityZone, privateIp] = await Promise.all([
    imds.get('meta-data/instance-id'),
    imds.get('meta-data/placement/availability-zone'),
    imds.get('meta-data/local-ipv4'),
  ]);
  if (!isIPv4(privateIp ?? '')) throw addressError(`IMDS returned no private IPv4 (${privateIp})`);

  const deadline = Date.now() + waitSeconds * 1000;
  let publicIpv4;
  for (;;) {
    const [current, tagged] = await Promise.all([
      imds.get('meta-data/public-ipv4', { optional: true }),
      imds.get('meta-data/tags/instance/SfuPublicIp', { optional: true }),
    ]);
    if (current && current === tagged && isPublicIpv4(current)) {
      publicIpv4 = current;
      break;
    }
    if (Date.now() >= deadline) {
      throw addressError(
        `Elastic IP not attached after ${waitSeconds} s (public-ipv4=${current ?? 'none'}, SfuPublicIp tag=${tagged ?? 'none'}); `
        + 'check the node-lifecycle function and that instance metadata tags are enabled',
      );
    }
    logger.info({ current: current ?? null, tagged: tagged ?? null }, 'waiting for node-lifecycle to attach the pool Elastic IP');
    await sleep(pollMs);
  }

  // Dual-stack subnets only: the first IPv6 of the primary interface is globally routable and announced unchanged.
  const ipv6 = await imds.get('meta-data/ipv6', { optional: true });
  const publicIpv6 = ipv6 && isIPv6(ipv6) ? ipv6 : undefined;

  return Object.freeze({
    instanceId: sanitiseId(instanceId),
    availabilityZone,
    privateIp,
    publicIpv4,
    ...(publicIpv6 ? { publicIpv6 } : {}),
  });
}

function resolveStatic({ staticIpv4, logger }) {
  if (!isIPv4(staticIpv4 ?? '')) throw addressError('MEDIA_PUBLIC_IPV4 must be an IPv4 address when the source is static');
  const privateIp = Object.values(networkInterfaces()).flat()
    .find((i) => i && i.family === 'IPv4' && !i.internal)?.address ?? '127.0.0.1';
  if (!isPublicIpv4(staticIpv4)) {
    logger.warn({ staticIpv4 }, 'announcing a non-public address: only clients on this network can reach the SFU');
  }
  return Object.freeze({
    instanceId: sanitiseId(`local-${hostname()}`),
    availabilityZone: 'local',
    privateIp,
    publicIpv4: staticIpv4,
  });
}

function sanitiseId(value) {
  const id = String(value).toLowerCase().replace(/[^a-z0-9-]/g, '-').replace(/-+/g, '-').replace(/^-|-$/g, '').slice(0, 60);
  if (id.length < 3) throw addressError(`cannot derive a node id from '${value}'`);
  return id;
}

function createImdsClient({ endpoint, fetchImpl }) {
  let token = null;
  let tokenExpires = 0;

  async function refreshToken() {
    const res = await fetchImpl(`${endpoint}/latest/api/token`, {
      method: 'PUT',
      headers: { 'x-aws-ec2-metadata-token-ttl-seconds': String(TOKEN_TTL_SECONDS) },
      signal: AbortSignal.timeout(2_000),
    });
    if (!res.ok) throw addressError(`IMDSv2 token request failed with HTTP ${res.status}`);
    token = await res.text();
    tokenExpires = Date.now() + (TOKEN_TTL_SECONDS - 60) * 1000;
  }

  return {
    /** GET a metadata path; optional paths resolve null when absent (404) or unreachable. */
    async get(path, { optional = false } = {}) {
      let lastError;
      for (let attempt = 0; attempt < 3; attempt += 1) {
        try {
          if (!token || Date.now() > tokenExpires) await refreshToken();
          const res = await fetchImpl(`${endpoint}/latest/${path}`, {
            headers: { 'x-aws-ec2-metadata-token': token },
            signal: AbortSignal.timeout(2_000),
          });
          if (res.status === 404) {
            if (optional) return null;
            throw addressError(`IMDS ${path} not found`);
          }
          if (res.status === 401) {
            token = null; // token expired or revoked: fetch a new one
            continue;
          }
          if (!res.ok) throw addressError(`IMDS ${path} returned HTTP ${res.status}`);
          return (await res.text()).trim();
        } catch (err) {
          lastError = err;
          if (err.code === 'PUBLIC_ADDRESS_UNAVAILABLE' && !/token/.test(err.message)) break;
          await sleep(250 * (attempt + 1));
        }
      }
      if (optional) return null;
      throw lastError?.code === 'PUBLIC_ADDRESS_UNAVAILABLE'
        ? lastError
        : addressError(`IMDS ${path} unreachable: ${lastError?.message ?? 'no response'}`);
    },
  };
}