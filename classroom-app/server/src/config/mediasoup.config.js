/**
 * server/src/config/mediasoup.config.js
 *
 * Single source of truth for the SFU's mediasoup settings.  (F1, F8)
 *
 * Version 7 model — what changed against v6:
 *   - No per-transport port range. Every worker owns exactly ONE UDP and ONE
 *     TCP port (MEDIASOUP_RTC_PORT_BASE + workerIndex) through a WebRtcServer;
 *     all WebRTC transports on that worker are multiplexed over them and
 *     demultiplexed by ICE ufrag. Port usage no longer grows with participants.
 *   - The worker's rtcMinPort/rtcMaxPort range is now used *only* by
 *     PipeTransport (node-to-node cascading, private IPs) and PlainTransport
 *     (loopback RTP to the capture sidecar). It is sliced per worker so two
 *     workers can never collide.
 *   - announcedAddress carries the instance's Elastic IP; the socket binds to
 *     the private IP because AWS does 1:1 NAT.
 *   - This file contains NO TURN configuration. The SFU is ICE-lite: it never
 *     gathers, never queries STUN, never allocates on TURN. Everything about
 *     STUN/TURN reaches the client through the API (server/src/rtc/).
 *
 * Node.js 22, ESM.
 */

import os from 'node:os';

import { env } from './env.js';

/* -------------------------------------------------------------------------- */
/* Workers                                                                     */
/* -------------------------------------------------------------------------- */

const hostParallelism = os.availableParallelism?.() ?? os.cpus().length;

/**
 * One worker per core, capped at 64 because the port scheme reserves
 * 40000..40063 for WebRtcServers.
 */
export const MAX_WORKERS = 64;

export const numWorkers = Math.max(
  1,
  Math.min(env.MEDIASOUP_WORKERS ?? hostParallelism, MAX_WORKERS),
);

/**
 * Non-WebRTC port range, split evenly between workers.
 * Pipe transports are announced on private IPs only; plain transports for
 * recording never leave 127.0.0.1.
 */
const pipeRangeMin = env.MEDIASOUP_PIPE_PORT_MIN; // 41000
const pipeRangeMax = env.MEDIASOUP_PIPE_PORT_MAX; // 41999
const portsPerWorker = Math.floor((pipeRangeMax - pipeRangeMin + 1) / numWorkers);

if (portsPerWorker < 20) {
  throw new Error(
    `mediasoup: pipe/plain port range ${pipeRangeMin}-${pipeRangeMax} is too small ` +
      `for ${numWorkers} workers (${portsPerWorker} ports each)`,
  );
}

/**
 * Settings for worker index `i`.
 * @param {number} workerIndex
 */
export function workerSettings(workerIndex) {
  const rtcMinPort = pipeRangeMin + workerIndex * portsPerWorker;
  const rtcMaxPort = rtcMinPort + portsPerWorker - 1;

  return {
    logLevel: env.MEDIASOUP_LOG_LEVEL ?? (env.NODE_ENV === 'production' ? 'warn' : 'debug'),
    logTags: [
      'info',
      'ice',
      'dtls',
      'rtp',
      'srtp',
      'rtcp',
      'bwe',
      'score',
      'simulcast',
      'svc',
      'sctp',
    ],
    // Used by PipeTransport and PlainTransport only — see header.
    rtcMinPort,
    rtcMaxPort,
    disableLiburing: false,
    appData: { workerIndex },
  };
}

/* -------------------------------------------------------------------------- */
/* WebRtcServer (one per worker)                                               */
/* -------------------------------------------------------------------------- */

/**
 * The single UDP/TCP port this worker announces in ICE candidates.
 * @param {number} workerIndex
 */
export function rtcPortForWorker(workerIndex) {
  if (workerIndex < 0 || workerIndex >= MAX_WORKERS) {
    throw new RangeError(`workerIndex ${workerIndex} out of range 0..${MAX_WORKERS - 1}`);
  }
  return env.MEDIASOUP_RTC_PORT_BASE + workerIndex; // 40000 + i
}

/**
 * listenInfos for worker.createWebRtcServer().
 *
 * Bind to the private IP (host networking), announce the Elastic IP.
 * IPv6 is added only when the subnet is dual-stack and IMDS returned an
 * address; announcedAddress is omitted there because an IPv6 address is not
 * NATed — the bound address *is* the public one.
 *
 * @param {{ privateIp: string, publicIpv4: string, publicIpv6?: string|null, workerIndex: number }} args
 */
export function buildWebRtcServerListenInfos({
  privateIp,
  publicIpv4,
  publicIpv6 = null,
  workerIndex,
}) {
  const port = rtcPortForWorker(workerIndex);

  /** @type {Array<Record<string, unknown>>} */
  const listenInfos = [
    {
      protocol: 'udp',
      ip: privateIp,
      announcedAddress: publicIpv4,
      port,
      flags: { ipv6Only: false },
      sendBufferSize: SOCKET_BUFFER_BYTES,
      recvBufferSize: SOCKET_BUFFER_BYTES,
    },
    {
      protocol: 'tcp',
      ip: privateIp,
      announcedAddress: publicIpv4,
      port, // same number for TCP — ICE-TCP passive
    },
  ];

  if (publicIpv6) {
    listenInfos.push(
      {
        protocol: 'udp',
        ip: '::',
        port,
        announcedAddress: publicIpv6,
        flags: { ipv6Only: true },
        sendBufferSize: SOCKET_BUFFER_BYTES,
        recvBufferSize: SOCKET_BUFFER_BYTES,
      },
      {
        protocol: 'tcp',
        ip: '::',
        port,
        announcedAddress: publicIpv6,
        flags: { ipv6Only: true },
      },
    );
  }

  return listenInfos;
}

/** 4 MiB socket buffers: a loaded node moves a lot of small UDP packets. */
const SOCKET_BUFFER_BYTES = 4 * 1024 * 1024;

/* -------------------------------------------------------------------------- */
/* Router                                                                      */
/* -------------------------------------------------------------------------- */

/**
 * Codec list. Order is preference order.
 *
 * VP8 stays first for video because every browser and react-native-webrtc
 * build supports it and it simulcasts reliably. VP9 is offered for screen
 * shares (SVC, text stays sharp). H264 is kept for Safari/iOS hardware paths.
 */
export const routerOptions = {
  mediaCodecs: [
    {
      kind: 'audio',
      mimeType: 'audio/opus',
      clockRate: 48000,
      channels: 2,
      parameters: {
        useinbandfec: 1,
        usedtx: 1,
        minptime: 10,
        // 'stereo' is decided per producer; classroom audio is mono by default.
      },
    },
    {
      kind: 'video',
      mimeType: 'video/VP8',
      clockRate: 90000,
      parameters: {
        'x-google-start-bitrate': 800,
      },
    },
    {
      kind: 'video',
      mimeType: 'video/VP9',
      clockRate: 90000,
      parameters: {
        'profile-id': 2,
        'x-google-start-bitrate': 800,
      },
    },
    {
      kind: 'video',
      mimeType: 'video/H264',
      clockRate: 90000,
      parameters: {
        'packetization-mode': 1,
        'profile-level-id': '42e01f',
        'level-asymmetry-allowed': 1,
        'x-google-start-bitrate': 800,
      },
    },
    {
      kind: 'video',
      mimeType: 'video/H264',
      clockRate: 90000,
      parameters: {
        'packetization-mode': 1,
        'profile-level-id': '4d0032',
        'level-asymmetry-allowed': 1,
        'x-google-start-bitrate': 800,
      },
    },
  ],
};

/* -------------------------------------------------------------------------- */
/* WebRTC transports                                                           */
/* -------------------------------------------------------------------------- */

/**
 * Options merged into every router.createWebRtcTransport() call.
 * `webRtcServer` is injected at call time by createWebRtcTransport.js — there
 * is no listenIps/listenInfos here on purpose: a transport that allocates its
 * own port is exactly the v6 bug this version removes.
 */
export const webRtcTransportOptions = {
  enableUdp: true,
  enableTcp: true, // ICE-TCP for networks that block UDP
  preferUdp: true,
  enableSctp: true, // DataChannels: whiteboard cursor, low-latency signals
  numSctpStreams: { OS: 1024, MIS: 1024 },
  maxSctpMessageSize: 262_144,
  initialAvailableOutgoingBitrate: 1_000_000,
  /**
   * ICE consent freshness (RFC 7675). 30 s means a silently disappeared client
   * releases its transport slot without waiting for a DTLS timeout.
   */
  iceConsentTimeout: 30,
};

/** Upper bound per receive transport, applied after the DTLS handshake. */
export const maxIncomingBitrate = env.MEDIASOUP_MAX_INCOMING_BITRATE ?? 3_000_000;

/* -------------------------------------------------------------------------- */
/* Encoding profiles                                                           */
/* -------------------------------------------------------------------------- */

/**
 * Camera: three simulcast layers. The client applies these; the server keeps
 * them here so web and Expo cannot drift apart (they import the same values
 * through packages/contracts).
 */
export const cameraProfile = {
  encodings: [
    { rid: 'q', scaleResolutionDownBy: 4, maxBitrate: 180_000, scalabilityMode: 'L1T3' },
    { rid: 'h', scaleResolutionDownBy: 2, maxBitrate: 500_000, scalabilityMode: 'L1T3' },
    { rid: 'f', scaleResolutionDownBy: 1, maxBitrate: 1_500_000, scalabilityMode: 'L1T3' },
  ],
  codecOptions: {
    videoGoogleStartBitrate: 600,
    videoGoogleMinBitrate: 150,
    videoGoogleMaxBitrate: 1_500,
  },
};

/**
 * Screen share (F1): simulcast OFF, one high-resolution layer, low frame rate,
 * contentHint 'detail' so text stays readable. Sent over the *existing* send
 * transport as a second producer with appData.source = 'screen'.
 */
export const screenShareProfile = {
  contentHint: 'detail',
  preferredCodecMimeTypes: ['video/VP9', 'video/VP8'],
  encodings: [
    {
      maxBitrate: 3_000_000,
      maxFramerate: 15,
      scalabilityMode: 'L1T2',
      dtx: false,
    },
  ],
  codecOptions: {
    videoGoogleStartBitrate: 1_500,
    videoGoogleMinBitrate: 600,
    videoGoogleMaxBitrate: 3_000,
  },
  /** getDisplayMedia constraints handed to ScreenShareAdapter. */
  constraints: {
    video: {
      width: { max: 1920 },
      height: { max: 1080 },
      frameRate: { max: 15 },
    },
    audio: true, // optional tab/system audio -> extra producer
  },
};

/** Screen-share audio, when the presenter shares tab or system audio. */
export const screenAudioProfile = {
  codecOptions: { opusStereo: true, opusDtx: false, opusFec: true },
};

/* -------------------------------------------------------------------------- */
/* Pipe transports (cascading, F1)                                             */
/* -------------------------------------------------------------------------- */

export const pipeTransportOptions = {
  // Private IP only. The listen IP is filled in by the caller from
  // publicAddress.resolve().privateIp — never announced publicly.
  enableSctp: false,
  enableRtx: true,
  enableSrtp: true, // node-to-node traffic is encrypted even inside the VPC
};

/* -------------------------------------------------------------------------- */
/* Plain transports (recording, F1/F4)                                         */
/* -------------------------------------------------------------------------- */

/**
 * RTP to the capture sidecar in the same ECS task. Loopback only: raw RTP must
 * never cross the network. rtcpMux disabled so ffmpeg gets a conventional
 * RTP/RTCP port pair; comedia disabled because we connect explicitly to the
 * sidecar's ports.
 */
export const plainTransportOptions = {
  listenInfo: { protocol: 'udp', ip: '127.0.0.1' },
  rtcpMux: false,
  comedia: false,
  enableSctp: false,
  enableSrtp: false, // loopback, inside one task's network namespace
};

/* -------------------------------------------------------------------------- */
/* Load and capacity                                                           */
/* -------------------------------------------------------------------------- */

/**
 * Inputs for sfu-node/loadReporter.js. A node above `maxLoadScore` stops
 * receiving new rooms (RoomPlacementService) and, above the cascade
 * threshold, existing rooms fan out to a second node.
 */
export const capacity = {
  maxLoadScore: env.SFU_MAX_LOAD_SCORE ?? 0.85,
  cascadeThreshold: 0.7,
  /** Weights must sum to 1. */
  weights: { producers: 0.25, consumers: 0.35, egressMbps: 0.25, cpu: 0.15 },
  referencePerNode: {
    producers: 400,
    consumers: 4_000,
    egressMbps: env.SFU_EGRESS_BASELINE_MBPS ?? 2_000,
  },
  /** Headroom kept free on every node for breakout rooms of a live lesson. */
  breakoutHeadroom: 0.1,
};

export default {
  numWorkers,
  workerSettings,
  rtcPortForWorker,
  buildWebRtcServerListenInfos,
  routerOptions,
  webRtcTransportOptions,
  maxIncomingBitrate,
  cameraProfile,
  screenShareProfile,
  screenAudioProfile,
  pipeTransportOptions,
  plainTransportOptions,
  capacity,
};