/**
 * server/src/mediasoup/createWebRtcTransport.js
 *
 * Creates one WebRTC transport bound to the worker's WebRtcServer.  (F1, F8)
 *
 * v6 -> v7: a transport no longer allocates its own port. It is attached to the
 * WebRtcServer that its worker created at boot, so every transport on that
 * worker shares one UDP and one TCP port and is demultiplexed by ICE ufrag.
 * That is why this module takes a `webRtcServer` and never a listenInfos list.
 *
 * Returned ICE candidates carry the node's Elastic IP (announcedAddress set on
 * the WebRtcServer). The SFU is ICE-lite: it answers checks, it never sends
 * them, and it knows nothing about STUN or TURN. The iceServers block the
 * client receives is produced by server/src/rtc/IceServerService.js and merged
 * into the join acknowledgement by signaling/socketHandlers.js.
 *
 * Node.js 22, ESM.
 */

import { webRtcTransportOptions, maxIncomingBitrate } from '../config/mediasoup.config.js';
import { logger } from '../observability/logger.js';
import { metrics } from '../observability/metrics.js';

const log = logger.child({ component: 'webrtc-transport' });

/**
 * @typedef {'send'|'recv'} TransportDirection
 *
 * @typedef {object} TransportParams
 * @property {string} id
 * @property {object} iceParameters
 * @property {Array<object>} iceCandidates
 * @property {object} dtlsParameters
 * @property {object|undefined} sctpParameters
 * @property {number} iceConsentTimeout
 */

/**
 * @param {object} args
 * @param {import('mediasoup').types.Router} args.router
 * @param {import('mediasoup').types.WebRtcServer} args.webRtcServer
 * @param {string} args.roomId
 * @param {string} args.peerId
 * @param {TransportDirection} args.direction
 * @param {boolean} [args.enableSctp]
 * @param {number} [args.maxIncomingBitrate]
 * @param {Record<string, unknown>} [args.appData]
 * @param {(reason: string) => void} [args.onClose] called once, whatever killed it
 * @returns {Promise<{ transport: import('mediasoup').types.WebRtcTransport, params: TransportParams }>}
 */
export async function createWebRtcTransport({
  router,
  webRtcServer,
  roomId,
  peerId,
  direction,
  enableSctp = webRtcTransportOptions.enableSctp,
  maxIncomingBitrate: incomingCap = maxIncomingBitrate,
  appData = {},
  onClose,
}) {
  if (!router || router.closed) {
    throw new Error('createWebRtcTransport: router is missing or closed');
  }
  if (!webRtcServer || webRtcServer.closed) {
    // Refuse loudly. Falling back to listenInfos would silently allocate a
    // random port that no security group opens — the failure would surface
    // much later as "ICE fails for some users on some nodes".
    throw new Error('createWebRtcTransport: webRtcServer is missing or closed');
  }
  if (direction !== 'send' && direction !== 'recv') {
    throw new TypeError(`createWebRtcTransport: unknown direction "${direction}"`);
  }

  const transport = await router.createWebRtcTransport({
    ...webRtcTransportOptions,
    webRtcServer, // <- the whole point of the v7 correction
    enableSctp,
    appData: { ...appData, roomId, peerId, direction },
  });

  // Only the receive side of the SFU (= the client's send transport) needs an
  // ingress cap; the egress side is governed by REMB/transport-cc.
  if (direction === 'send' && incomingCap > 0) {
    try {
      await transport.setMaxIncomingBitrate(incomingCap);
    } catch (err) {
      log.warn({ err, roomId, peerId }, 'setMaxIncomingBitrate failed, continuing');
    }
  }

  attachObservers({ transport, roomId, peerId, direction, onClose });

  metrics.increment('sfu.transport.created', { direction });

  return { transport, params: toTransportParams(transport) };
}

/**
 * The exact shape the client feeds into device.createSendTransport() /
 * createRecvTransport(). Anything else on the transport object stays server
 * side — see packages/contracts/src/zod/rtc.schema.ts for the wire contract.
 *
 * @param {import('mediasoup').types.WebRtcTransport} transport
 * @returns {TransportParams}
 */
export function toTransportParams(transport) {
  return {
    id: transport.id,
    iceParameters: transport.iceParameters,
    iceCandidates: transport.iceCandidates,
    dtlsParameters: transport.dtlsParameters,
    sctpParameters: transport.sctpParameters,
    iceConsentTimeout: webRtcTransportOptions.iceConsentTimeout,
  };
}

/**
 * DTLS handshake. Called from rpcHandlers 'transport.connect'.
 * Idempotent on the client's side: a retried connect with the same
 * dtlsParameters must not tear the transport down.
 *
 * @param {import('mediasoup').types.WebRtcTransport} transport
 * @param {object} dtlsParameters
 */
export async function connectWebRtcTransport(transport, dtlsParameters) {
  if (transport.closed) throw new Error('transport closed');
  if (transport.dtlsState === 'connected' || transport.dtlsState === 'connecting') {
    log.debug({ transportId: transport.id, dtlsState: transport.dtlsState }, 'connect ignored');
    return;
  }
  await transport.connect({ dtlsParameters });
}

/**
 * ICE restart. The client calls this through signalling when IceRecovery sees
 * `disconnected` for 5 s or `failed`; it then applies the new iceParameters
 * with transport.restartIce(). If the client is about to switch to relay-only,
 * it refreshes its TURN credentials *before* calling us — that part never
 * touches the SFU.
 *
 * @param {import('mediasoup').types.WebRtcTransport} transport
 * @returns {Promise<{ iceParameters: object }>}
 */
export async function restartIce(transport) {
  if (transport.closed) throw new Error('transport closed');

  const iceParameters = await transport.restartIce();

  metrics.increment('sfu.transport.ice_restart', {
    direction: String(transport.appData?.direction ?? 'unknown'),
  });
  log.info(
    {
      transportId: transport.id,
      roomId: transport.appData?.roomId,
      peerId: transport.appData?.peerId,
      iceState: transport.iceState,
    },
    'ice restart issued',
  );

  return { iceParameters };
}

/**
 * Candidate-level view used by loadReporter and the sfu-incident runbook:
 * which path a peer actually ended up on (host / srflx / relay).
 *
 * @param {import('mediasoup').types.WebRtcTransport} transport
 */
export function describeSelectedPath(transport) {
  const tuple = transport.iceSelectedTuple;
  if (!tuple) return { connected: false };
  return {
    connected: true,
    protocol: tuple.protocol, // udp | tcp
    localPort: tuple.localPort,
    // remoteIp is deliberately NOT logged: piiRedaction.js scrubs client IPs
    // and ICE candidates. Keep it that way.
    relayed: transport.appData?.relayed === true,
  };
}

/* -------------------------------------------------------------------------- */
/* Internals                                                                   */
/* -------------------------------------------------------------------------- */

function attachObservers({ transport, roomId, peerId, direction, onClose }) {
  const base = { transportId: transport.id, roomId, peerId, direction };
  let closed = false;

  const close = (reason) => {
    if (closed) return;
    closed = true;
    metrics.increment('sfu.transport.closed', { direction, reason });
    onClose?.(reason);
  };

  transport.on('icestatechange', (iceState) => {
    log.debug({ ...base, iceState }, 'ice state');
    metrics.gauge('sfu.transport.ice_state', iceStateToNumber(iceState), { direction });

    if (iceState === 'completed' || iceState === 'connected') {
      const tuple = transport.iceSelectedTuple;
      metrics.increment('sfu.ice.connected', {
        direction,
        protocol: tuple?.protocol ?? 'unknown',
      });
    }

    if (iceState === 'disconnected') {
      log.info(base, 'ice disconnected — waiting for client restartIce');
    }

    if (iceState === 'closed') {
      close('ice-closed');
    }
  });

  transport.on('dtlsstatechange', (dtlsState) => {
    if (dtlsState === 'failed' || dtlsState === 'closed') {
      log.warn({ ...base, dtlsState }, 'dtls state');
      metrics.increment('sfu.dtls.failed', { direction });
      close(`dtls-${dtlsState}`);
    } else {
      log.debug({ ...base, dtlsState }, 'dtls state');
    }
  });

  transport.on('sctpstatechange', (sctpState) => {
    log.debug({ ...base, sctpState }, 'sctp state');
  });

  transport.on('trace', (trace) => {
    if (trace.type === 'bwe') {
      metrics.gauge(
        'sfu.transport.available_outgoing_bitrate',
        trace.info?.availableBitrate ?? 0,
        { direction },
      );
    }
  });

  transport.observer.once('close', () => close('closed'));

  // Router death (worker crash -> WorkerManager replaces it) must propagate.
  transport.observer.once('routerclose', () => close('router-closed'));
}

function iceStateToNumber(state) {
  switch (state) {
    case 'new':
      return 0;
    case 'connected':
      return 1;
    case 'completed':
      return 2;
    case 'disconnected':
      return 3;
    case 'closed':
      return 4;
    default:
      return -1;
  }
}

export default createWebRtcTransport;