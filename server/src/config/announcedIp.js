// server/src/config/announcedIp.js
/**
 * Announced media address of the SFU  (F1, F8)  [BRIDGE]
 *
 * Version 7 replaces this module with config/publicAddress.js and the
 * WebRtcServer model (one UDP + one TCP port per mediasoup worker, section 4.3).
 * The SFU path in this codebase is still the v6 per-transport model:
 * mediasoup/createWebRtcTransport.js calls getAnnouncedIp() synchronously, and
 * the environment carries ANNOUNCED_IP plus a port range.
 *
 * This file keeps that path working. Delete it in the same change that moves
 * createWebRtcTransport.js onto WebRtcServerFactory.js and publicAddress.js;
 * the two must switch together.
 *
 * What the browser is told to send media to:
 *   127.0.0.1   works only when the browser runs on the same machine
 *   LAN IP      testing from other devices on the same network
 *   public IP   anything reachable from the internet
 *
 * Production refuses anything that is not a public IPv4 address, because an
 * announced private or loopback address produces ICE candidates no client can
 * reach, and the only symptom would be every call silently failing.
 */

import { env, isProduction } from './env.js';

const IPV4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;

/** Loopback, RFC 1918, link-local, CGNAT and "this network" ranges. */
const isNonPublic = ([a, b]) =>
  a === 0 ||
  a === 10 ||
  a === 127 ||
  (a === 100 && b >= 64 && b <= 127) ||
  (a === 169 && b === 254) ||
  (a === 172 && b >= 16 && b <= 31) ||
  (a === 192 && b === 168);

let cached = null;

/**
 * The address mediasoup announces in its ICE candidates.
 * Validated once, then cached for the life of the process.
 * @returns {string}
 */
export const getAnnouncedIp = () => {
  if (cached) return cached;

  const ip = String(env.ANNOUNCED_IP ?? '').trim();
  const match = IPV4.exec(ip);
  const octets = match ? match.slice(1).map(Number) : null;

  if (!octets || octets.some((octet) => octet > 255)) {
    throw new Error(`ANNOUNCED_IP is not a valid IPv4 address: '${ip}'`);
  }

  if (isProduction && isNonPublic(octets)) {
    throw new Error(
      `ANNOUNCED_IP '${ip}' is not a public address. In production the SFU must announce ` +
        'its Elastic IP (see config/publicAddress.js and section 4.3 of the architecture).',
    );
  }

  cached = ip;
  return cached;
};

export default getAnnouncedIp;