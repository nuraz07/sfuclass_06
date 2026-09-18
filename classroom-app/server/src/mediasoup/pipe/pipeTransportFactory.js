// server/src/mediasoup/pipe/pipeTransportFactory.js
//
// Creates PipeTransports for node-to-node cascading inside one media region.
//
//   - listens on the node's PRIVATE IPv4 only and never announces a public address: pipe traffic stays
//     inside the VPC (security group: pipe port range from the SFU security group only);
//   - fixed port range MEDIASOUP_PIPE_PORT_MIN–MEDIASOUP_PIPE_PORT_MAX (default 41000–41999);
//   - SRTP enabled on every pipe: media is encrypted even on the private network;
//   - RTX enabled so packet loss between nodes is repaired by retransmission instead of freezing video.
// Both ends of a pipe are created by this factory, so their options always match.
//
// Owner: F1 Live Classrooms. Used by RouterPipeManager.js.

import { isIPv4 } from 'node:net';

export class PipeTransportFactory {
  /**
   * @param {object} options
   * @param {string} options.listenIp   private IPv4 of the instance
   * @param {number} options.portMin
   * @param {number} options.portMax
   */
  constructor({ listenIp, portMin, portMax }) {
    if (!isIPv4(listenIp ?? '')) throw new TypeError('PipeTransportFactory: listenIp must be an IPv4 address');
    if (isPublicIpv4(listenIp)) throw new RangeError('PipeTransportFactory: listenIp must be a private address');
    if (!(Number.isInteger(portMin) && Number.isInteger(portMax) && portMin >= 1024 && portMin <= portMax && portMax <= 65_535)) {
      throw new RangeError('PipeTransportFactory: invalid port range');
    }
    this.#listenIp = listenIp;
    this.#portRange = Object.freeze({ min: portMin, max: portMax });
  }

  #listenIp;
  #portRange;

  get listenIp() {
    return this.#listenIp;
  }

  /**
   * @param {import('mediasoup').types.Router} router
   * @param {Record<string, unknown>} [appData]
   * @returns {Promise<import('mediasoup').types.PipeTransport>}
   */
  create(router, appData = {}) {
    return router.createPipeTransport({
      listenInfo: { protocol: 'udp', ip: this.#listenIp, portRange: this.#portRange },
      enableSrtp: true,
      enableRtx: true,
      enableSctp: false,
      appData: { ...appData, kind: 'node-pipe' },
    });
  }
}

/** RFC 1918 and CGNAT are private; everything else is treated as public. */
export function isPublicIpv4(ip) {
  const [a, b] = ip.split('.').map(Number);
  if (a === 10) return false;
  if (a === 172 && b >= 16 && b <= 31) return false;
  if (a === 192 && b === 168) return false;
  if (a === 100 && b >= 64 && b <= 127) return false;
  if (a === 127) return false;
  return true;
}