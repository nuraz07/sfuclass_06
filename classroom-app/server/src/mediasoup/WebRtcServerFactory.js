// server/src/mediasoup/WebRtcServerFactory.js
//
// Creates one mediasoup WebRtcServer per worker. Every WebRTC transport of that worker is multiplexed
// over the server's sockets (demultiplexed by ICE username fragment), so a node needs exactly
//
//   UDP  MEDIASOUP_RTC_PORT_BASE + workerIndex
//   TCP  MEDIASOUP_RTC_PORT_BASE + workerIndex
//
// no matter how many participants it carries. These are the only public ports of an SFU node and are
// opened by infra/modules/sfu-node-pool/security-group.tf (40000–40063 for up to 64 workers).
//
// Addressing (architecture doc, section 4.3):
//   IPv4  listen on the instance's private IP (host networking); AWS maps the Elastic IP 1:1 onto it,
//         so the Elastic IP is announced in ICE candidates (announcedAddress).
//   IPv6  optional; instance IPv6 addresses are globally routable, so the socket listens on the public
//         IPv6 address itself and announces it unchanged.
// The SFU is ICE-lite and never gathers candidates: what is configured here IS the candidate list.
// There is no STUN or TURN configuration on this side — relayed clients arrive from a TURN node's IP.
//
// Owner: F8 Real-Time Connectivity + F1 Live Classrooms. Used by sfu.js through WorkerManager.

import { isIPv4, isIPv6 } from 'node:net';

const MAX_PORT = 65_535;

export class WebRtcServerFactory {
  /**
   * @param {object} options
   * @param {string} options.listenIp          private IPv4 of the instance
   * @param {string} options.announcedIpv4     Elastic IP (public) announced in ICE candidates
   * @param {string} [options.announcedIpv6]   public IPv6 of the instance, if the subnet is dual-stack
   * @param {number} options.portBase          MEDIASOUP_RTC_PORT_BASE (default 40000)
   * @param {number} [options.maxWorkers=64]   upper bound, must match the security group range
   * @param {number} [options.socketBufferBytes]  optional SO_SNDBUF/SO_RCVBUF (kernel limits apply)
   * @param {{ info: Function }} [options.logger]
   */
  constructor({ listenIp, announcedIpv4, announcedIpv6, portBase, maxWorkers = 64, socketBufferBytes, logger = console }) {
    if (!isIPv4(listenIp ?? '')) throw new TypeError('WebRtcServerFactory: listenIp must be an IPv4 address');
    if (!isIPv4(announcedIpv4 ?? '')) throw new TypeError('WebRtcServerFactory: announcedIpv4 must be an IPv4 address');
    if (announcedIpv6 !== undefined && !isIPv6(announcedIpv6)) {
      throw new TypeError('WebRtcServerFactory: announcedIpv6 must be an IPv6 address');
    }
    if (!Number.isInteger(portBase) || portBase < 1024 || portBase + maxWorkers - 1 > MAX_PORT) {
      throw new RangeError('WebRtcServerFactory: portBase must leave room for maxWorkers ports below 65536');
    }
    this.#listenIp = listenIp;
    this.#announcedIpv4 = announcedIpv4;
    this.#announcedIpv6 = announcedIpv6;
    this.#portBase = portBase;
    this.#maxWorkers = maxWorkers;
    this.#buffers = socketBufferBytes ? { sendBufferSize: socketBufferBytes, recvBufferSize: socketBufferBytes } : {};
    this.#logger = logger;
  }

  #listenIp;
  #announcedIpv4;
  #announcedIpv6;
  #portBase;
  #maxWorkers;
  #buffers;
  #logger;

  /** Ports owned by worker `index`. Same number for UDP and TCP. */
  portsFor(index) {
    this.#assertIndex(index);
    const port = this.#portBase + index;
    return Object.freeze({ udp: port, tcp: port });
  }

  /**
   * @param {import('mediasoup').types.Worker} worker
   * @param {number} index  worker index on this node (0-based, stable across worker replacement)
   * @returns {Promise<import('mediasoup').types.WebRtcServer>}
   */
  async create(worker, index) {
    const { udp, tcp } = this.portsFor(index);
    const listenInfos = [
      { protocol: 'udp', ip: this.#listenIp, announcedAddress: this.#announcedIpv4, port: udp, ...this.#buffers },
      { protocol: 'tcp', ip: this.#listenIp, announcedAddress: this.#announcedIpv4, port: tcp, ...this.#buffers },
    ];
    if (this.#announcedIpv6) {
      listenInfos.push(
        { protocol: 'udp', ip: this.#announcedIpv6, port: udp, ...this.#buffers },
        { protocol: 'tcp', ip: this.#announcedIpv6, port: tcp, ...this.#buffers },
      );
    }

    const webRtcServer = await worker.createWebRtcServer({
      listenInfos,
      appData: { workerIndex: index },
    });
    this.#logger.info(
      { workerIndex: index, pid: worker.pid, udp, tcp, announced: [this.#announcedIpv4, this.#announcedIpv6].filter(Boolean) },
      'webrtc server listening',
    );
    return webRtcServer;
  }

  #assertIndex(index) {
    if (!Number.isInteger(index) || index < 0 || index >= this.#maxWorkers) {
      throw new RangeError(`WebRtcServerFactory: worker index must be in [0, ${this.#maxWorkers - 1}]`);
    }
  }
}