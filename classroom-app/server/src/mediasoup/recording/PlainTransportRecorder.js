/**
 * server/src/mediasoup/recording/PlainTransportRecorder.js
 *
 * Moves a room's RTP to the capture sidecar over loopback.  (F1, F4)
 *
 * v6 -> v7 correction: it was never stated where RTP is captured, and the
 * implied path sent raw RTP over the network. Here the capture container runs
 * in the *same* ECS task as the SFU, so every PlainTransport binds and connects
 * on 127.0.0.1 and nothing leaves the task's network namespace. The sidecar
 * writes HLS/fMP4 segments straight to S3; the worker service muxes them into
 * a final asset afterwards (recordingPipeline.js queues that job).
 *
 * One PlainTransport per producer (one per track), rtcpMux off, comedia off:
 * the sidecar owns the sockets and tells us which port pair to send to, so
 * ffmpeg gets a conventional RTP/RTCP pair per track and an SDP it can read.
 *
 * This class knows nothing about S3, BullMQ or room lifecycle — that is
 * recordingPipeline.js. It only owns mediasoup objects.
 *
 * Node.js 22, ESM.
 */

import { EventEmitter } from 'node:events';

import { plainTransportOptions } from '../../config/mediasoup.config.js';
import { logger } from '../../observability/logger.js';
import { metrics } from '../../observability/metrics.js';

const log = logger.child({ component: 'plain-transport-recorder' });

/** RTCP feedback we keep for the recorder. ffmpeg needs PLI, nothing else. */
const KEPT_FEEDBACK = new Set(['nack', 'nack/pli', 'ccm/fir']);

/**
 * @typedef {object} PortPair
 * @property {number} rtpPort
 * @property {number} rtcpPort
 *
 * @typedef {object} TrackDescriptor
 * @property {string} trackId          stable id used by the sidecar
 * @property {string} producerId
 * @property {string} peerId
 * @property {'audio'|'video'} kind
 * @property {'mic'|'cam'|'screen'|'screen-audio'} source
 * @property {PortPair} ports
 * @property {object} rtpParameters    consumer parameters, as sent to ffmpeg
 * @property {string} sdp              single-media SDP for this track
 */

export class PlainTransportRecorder extends EventEmitter {
  /**
   * @param {object} args
   * @param {import('mediasoup').types.Router} args.router
   * @param {string} args.roomId
   * @param {string} args.recordingId
   * @param {{ allocate: (spec: { trackId: string, kind: string }) => Promise<PortPair>,
   *           release: (trackId: string) => Promise<void> }} args.portAllocator
   *        Implemented by the sidecar client in recordingPipeline.js: the
   *        sidecar binds the sockets, therefore the sidecar hands out ports.
   */
  constructor({ router, roomId, recordingId, portAllocator }) {
    super();
    this.router = router;
    this.roomId = roomId;
    this.recordingId = recordingId;
    this.portAllocator = portAllocator;

    /** @type {Map<string, { transport: import('mediasoup').types.PlainTransport, consumer: import('mediasoup').types.Consumer, descriptor: TrackDescriptor }>} */
    this.tracks = new Map(); // keyed by producerId
    this.closed = false;

    this.rtpCapabilities = buildRecorderRtpCapabilities(router);
  }

  /* ---------------------------------------------------------------------- */
  /* Tracks                                                                  */
  /* ---------------------------------------------------------------------- */

  /**
   * Attach one producer to the recorder.
   * Safe to call twice for the same producer — the second call is a no-op.
   *
   * @param {object} args
   * @param {import('mediasoup').types.Producer} args.producer
   * @param {string} args.peerId
   * @param {'mic'|'cam'|'screen'|'screen-audio'} args.source
   * @returns {Promise<TrackDescriptor|null>} null when the producer is not consumable
   */
  async addProducer({ producer, peerId, source }) {
    this.#assertOpen();

    if (this.tracks.has(producer.id)) {
      return this.tracks.get(producer.id).descriptor;
    }

    if (!this.router.canConsume({ producerId: producer.id, rtpCapabilities: this.rtpCapabilities })) {
      log.warn(
        { roomId: this.roomId, producerId: producer.id, kind: producer.kind },
        'recorder cannot consume producer, skipping track',
      );
      return null;
    }

    const trackId = `${this.recordingId}-${producer.id.slice(0, 8)}`;
    const ports = await this.portAllocator.allocate({ trackId, kind: producer.kind });

    /** @type {import('mediasoup').types.PlainTransport|undefined} */
    let transport;
    /** @type {import('mediasoup').types.Consumer|undefined} */
    let consumer;

    try {
      transport = await this.router.createPlainTransport({
        ...plainTransportOptions,
        appData: {
          roomId: this.roomId,
          recordingId: this.recordingId,
          producerId: producer.id,
          trackId,
        },
      });

      // Loopback only. The sidecar is listening on these ports already.
      await transport.connect({
        ip: '127.0.0.1',
        port: ports.rtpPort,
        rtcpPort: ports.rtcpPort,
      });

      consumer = await transport.consume({
        producerId: producer.id,
        rtpCapabilities: this.rtpCapabilities,
        // Paused until the sidecar reports that its demuxer is ready; that
        // keeps the first seconds of a recording from being decoded into
        // nothing.
        paused: true,
        appData: { recordingId: this.recordingId, trackId },
      });

      const descriptor = {
        trackId,
        producerId: producer.id,
        peerId,
        kind: /** @type {'audio'|'video'} */ (producer.kind),
        source,
        ports,
        rtpParameters: consumer.rtpParameters,
        sdp: buildTrackSdp({ consumer, ports }),
      };

      this.#observeTrack({ producer, transport, consumer, descriptor });
      this.tracks.set(producer.id, { transport, consumer, descriptor });

      metrics.increment('sfu.recording.track_added', { kind: producer.kind, source });
      log.info(
        { roomId: this.roomId, recordingId: this.recordingId, trackId, source, kind: producer.kind },
        'recording track attached',
      );

      return descriptor;
    } catch (err) {
      // Never leak a transport or a port reservation on a partial failure.
      try {
        consumer?.close();
        transport?.close();
      } catch {
        /* already closed */
      }
      await this.portAllocator.release(trackId).catch(() => {});
      throw err;
    }
  }

  /**
   * Start the flow for a track once the sidecar confirms it is reading.
   * @param {string} producerId
   */
  async resumeProducer(producerId) {
    const entry = this.tracks.get(producerId);
    if (!entry || entry.consumer.closed) return;
    await entry.consumer.resume();
    // A keyframe right after resume: otherwise the segment starts with
    // several seconds of green.
    if (entry.consumer.kind === 'video') {
      await entry.consumer.requestKeyFrame().catch(() => {});
    }
  }

  /** Resume every attached track. */
  async resumeAll() {
    await Promise.all([...this.tracks.keys()].map((id) => this.resumeProducer(id)));
  }

  /**
   * Detach one producer (peer left, camera off, screen share ended).
   * @param {string} producerId
   */
  async removeProducer(producerId) {
    const entry = this.tracks.get(producerId);
    if (!entry) return;
    this.tracks.delete(producerId);

    try {
      entry.consumer.close();
      entry.transport.close();
    } catch {
      /* already closed */
    }
    await this.portAllocator.release(entry.descriptor.trackId).catch((err) => {
      log.warn({ err, trackId: entry.descriptor.trackId }, 'port release failed');
    });

    metrics.increment('sfu.recording.track_removed', {
      kind: entry.descriptor.kind,
      source: entry.descriptor.source,
    });
    this.emit('trackRemoved', entry.descriptor);
  }

  /* ---------------------------------------------------------------------- */
  /* Introspection                                                           */
  /* ---------------------------------------------------------------------- */

  /** @returns {TrackDescriptor[]} */
  describe() {
    return [...this.tracks.values()].map((t) => t.descriptor);
  }

  /** Combined SDP for the whole recording, in track order. */
  toSessionSdp() {
    const media = this.describe()
      .map((d) => d.sdp)
      .join('');
    return (
      'v=0\r\n' +
      'o=- 0 0 IN IP4 127.0.0.1\r\n' +
      `s=classroom-recording-${this.recordingId}\r\n` +
      'c=IN IP4 127.0.0.1\r\n' +
      't=0 0\r\n' +
      media
    );
  }

  /** Per-track RTP statistics, polled by recordingPipeline for health. */
  async stats() {
    const out = [];
    for (const { consumer, descriptor } of this.tracks.values()) {
      if (consumer.closed) continue;
      const [stat] = await consumer.getStats();
      out.push({
        trackId: descriptor.trackId,
        kind: descriptor.kind,
        source: descriptor.source,
        packetCount: stat?.packetCount ?? 0,
        byteCount: stat?.byteCount ?? 0,
        packetsLost: stat?.packetsLost ?? 0,
        score: consumer.score?.score ?? null,
      });
    }
    return out;
  }

  /* ---------------------------------------------------------------------- */
  /* Teardown                                                                */
  /* ---------------------------------------------------------------------- */

  /** Close every transport and release every port. Idempotent. */
  async close() {
    if (this.closed) return;
    this.closed = true;

    const entries = [...this.tracks.values()];
    this.tracks.clear();

    for (const { consumer, transport } of entries) {
      try {
        consumer.close();
        transport.close();
      } catch {
        /* already closed */
      }
    }

    await Promise.allSettled(
      entries.map((e) => this.portAllocator.release(e.descriptor.trackId)),
    );

    log.info(
      { roomId: this.roomId, recordingId: this.recordingId, tracks: entries.length },
      'recorder closed',
    );
    this.emit('close');
    this.removeAllListeners();
  }

  /* ---------------------------------------------------------------------- */

  #observeTrack({ producer, transport, consumer, descriptor }) {
    // The producer disappearing is the normal end of a track.
    producer.observer.once('close', () => {
      this.removeProducer(producer.id).catch((err) =>
        log.warn({ err, trackId: descriptor.trackId }, 'track cleanup failed'),
      );
    });

    consumer.on('producerclose', () => {
      this.removeProducer(producer.id).catch(() => {});
    });

    consumer.on('producerpause', () => this.emit('trackPaused', descriptor));
    consumer.on('producerresume', () => {
      this.emit('trackResumed', descriptor);
      if (consumer.kind === 'video') consumer.requestKeyFrame().catch(() => {});
    });

    consumer.on('score', (score) => {
      metrics.gauge('sfu.recording.consumer_score', score.score, { kind: descriptor.kind });
    });

    transport.on('tuple', (tuple) => {
      log.debug({ trackId: descriptor.trackId, tuple }, 'plain transport tuple');
    });

    transport.observer.once('close', () => {
      if (!this.closed) this.emit('trackTransportClosed', descriptor);
    });
  }

  #assertOpen() {
    if (this.closed) throw new Error('PlainTransportRecorder is closed');
    if (this.router.closed) throw new Error('router is closed');
  }
}

/* -------------------------------------------------------------------------- */
/* Helpers                                                                     */
/* -------------------------------------------------------------------------- */

/**
 * Capabilities presented to the router on behalf of ffmpeg.
 *
 * ffmpeg is not a browser: it wants one plain codec per track, no RTX, no FEC,
 * no simulcast. Stripping those here means the consumer we create is already
 * the single-layer stream the sidecar can decode.
 *
 * @param {import('mediasoup').types.Router} router
 */
export function buildRecorderRtpCapabilities(router) {
  const wanted = new Set(['audio/opus', 'video/VP8', 'video/H264']);

  const codecs = router.rtpCapabilities.codecs
    .filter((c) => wanted.has(c.mimeType))
    .map((c) => ({
      ...c,
      rtcpFeedback: (c.rtcpFeedback ?? []).filter((fb) =>
        KEPT_FEEDBACK.has(fb.parameter ? `${fb.type}/${fb.parameter}` : fb.type),
      ),
    }));

  if (codecs.length === 0) {
    throw new Error('recorder: router offers no codec the capture sidecar can decode');
  }

  return {
    codecs,
    headerExtensions: (router.rtpCapabilities.headerExtensions ?? []).filter((ext) =>
      ['urn:ietf:params:rtp-hdrext:sdes:mid', 'urn:ietf:params:rtp-hdrext:ssrc-audio-level'].includes(
        ext.uri,
      ),
    ),
  };
}

/**
 * One m-section describing where the sidecar will receive this track.
 * @param {{ consumer: import('mediasoup').types.Consumer, ports: PortPair }} args
 */
function buildTrackSdp({ consumer, ports }) {
  const { codecs, encodings } = consumer.rtpParameters;
  const codec = codecs[0];
  const payloadType = codec.payloadType;
  const mediaType = consumer.kind; // audio | video
  const ssrc = encodings?.[0]?.ssrc;

  const [, encodingName] = codec.mimeType.split('/');
  const channels = mediaType === 'audio' ? `/${codec.channels ?? 2}` : '';

  const fmtp = Object.entries(codec.parameters ?? {})
    .map(([k, v]) => `${k}=${v}`)
    .join(';');

  let sdp = '';
  sdp += `m=${mediaType} ${ports.rtpPort} RTP/AVP ${payloadType}\r\n`;
  sdp += 'c=IN IP4 127.0.0.1\r\n';
  sdp += `a=rtcp:${ports.rtcpPort} IN IP4 127.0.0.1\r\n`;
  sdp += `a=rtpmap:${payloadType} ${encodingName}/${codec.clockRate}${channels}\r\n`;
  if (fmtp) sdp += `a=fmtp:${payloadType} ${fmtp}\r\n`;
  for (const fb of codec.rtcpFeedback ?? []) {
    sdp += `a=rtcp-fb:${payloadType} ${fb.type}${fb.parameter ? ` ${fb.parameter}` : ''}\r\n`;
  }
  if (ssrc) sdp += `a=ssrc:${ssrc} cname:${consumer.rtpParameters.rtcp?.cname ?? 'recorder'}\r\n`;
  sdp += 'a=recvonly\r\n';

  return sdp;
}

export default PlainTransportRecorder;