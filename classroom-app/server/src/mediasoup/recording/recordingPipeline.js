/**
 * server/src/mediasoup/recording/recordingPipeline.js
 *
 * Orchestrates one recording per room.  (F1, F4)
 *
 * v6 -> v7 correction: v6 had an "ffmpeg sidecar" of unclear location and let
 * recordingWorker mux from raw RTP. The corrected pipeline is:
 *
 *   producers -> PlainTransportRecorder (loopback RTP)
 *             -> capture sidecar (same ECS task, Dockerfile.capture)
 *             -> fMP4/HLS segments streamed directly to S3
 *             -> BullMQ job "recording.mux" on the *state* Redis cluster
 *             -> worker service (Dockerfile.worker, ffmpeg) muxes from S3
 *             -> media/ asset becomes ready
 *
 * The SFU process therefore never writes durable state to disk and never holds
 * a finished file: segments are in S3 the whole time, so a node that dies mid
 * lesson loses at most the current segment. A drained node stops its sessions
 * cleanly and the mux job still runs.
 *
 * Runs inside sfu.js only.
 *
 * Node.js 22, ESM.
 */

import { randomUUID } from 'node:crypto';
import { EventEmitter } from 'node:events';

import { Queue } from 'bullmq';

import { env } from '../../config/env.js';
import { connection as stateConnection } from '../../queues/connection.js';
import { logger } from '../../observability/logger.js';
import { metrics } from '../../observability/metrics.js';
import { PlainTransportRecorder } from './PlainTransportRecorder.js';

const log = logger.child({ component: 'recording-pipeline' });

const SIDECAR_URL = env.CAPTURE_SIDECAR_URL ?? 'http://127.0.0.1:9100';
const SIDECAR_TIMEOUT_MS = 5_000;
const HEARTBEAT_INTERVAL_MS = 10_000;
const STALL_THRESHOLD_MS = 45_000;
const SESSION_STATE_TTL_S = 60;
const SEGMENT_SECONDS = env.RECORDING_SEGMENT_SECONDS ?? 6;

/** Queue producer only — the consumer lives in queues/workers/recordingWorker.js. */
const recordingQueue = new Queue('recording', {
  connection: stateConnection,
  prefix: env.REDIS_PREFIX ? `${env.REDIS_PREFIX}:bull` : 'bull',
  defaultJobOptions: {
    attempts: 5,
    backoff: { type: 'exponential', delay: 10_000 },
    removeOnComplete: 1_000,
    removeOnFail: false,
  },
});

/* ========================================================================== */
/* Session                                                                    */
/* ========================================================================== */

class RecordingSession extends EventEmitter {
  /**
   * @param {object} args
   * @param {import('mediasoup').types.Router} args.router
   * @param {object} args.room                   classroom/Room.js instance
   * @param {string} args.tenantId
   * @param {string} args.lessonId
   * @param {string} args.startedBy              userId of the host
   * @param {import('ioredis').Redis} args.stateRedis
   */
  constructor({ router, room, tenantId, lessonId, startedBy, stateRedis }) {
    super();
    this.recordingId = randomUUID();
    this.router = router;
    this.room = room;
    this.roomId = room.id;
    this.tenantId = tenantId;
    this.lessonId = lessonId;
    this.startedBy = startedBy;
    this.stateRedis = stateRedis;

    this.bucket = env.S3_BUCKET_RECORDINGS;
    this.keyPrefix = `raw/${tenantId}/${lessonId}/${this.recordingId}/`;

    this.status = 'starting'; // starting | recording | stopping | stopped | failed
    this.startedAt = null;
    this.endedAt = null;
    this.lastProgressAt = Date.now();
    this.lastByteCount = 0;
    this.error = null;

    /** @type {PlainTransportRecorder|null} */
    this.recorder = null;
    this.heartbeat = null;
  }

  /* ---------------------------------------------------------------------- */

  async start() {
    // 1. The sidecar opens its sockets and its S3 multipart writers first.
    await sidecar('POST', '/sessions', {
      recordingId: this.recordingId,
      bucket: this.bucket,
      keyPrefix: this.keyPrefix,
      segmentSeconds: SEGMENT_SECONDS,
      region: env.MEDIA_REGION,
      metadata: {
        tenantId: this.tenantId,
        lessonId: this.lessonId,
        roomId: this.roomId,
      },
    });

    // 2. mediasoup side. Port allocation is delegated to the sidecar because
    //    the sidecar owns the listening sockets.
    this.recorder = new PlainTransportRecorder({
      router: this.router,
      roomId: this.roomId,
      recordingId: this.recordingId,
      portAllocator: {
        allocate: ({ trackId, kind }) =>
          sidecar('POST', `/sessions/${this.recordingId}/tracks`, { trackId, kind }),
        release: (trackId) =>
          sidecar('DELETE', `/sessions/${this.recordingId}/tracks/${trackId}`).catch(() => {}),
      },
    });

    // 3. Attach everything already producing in the room.
    for (const peer of this.room.peers.values()) {
      for (const [source, producer] of Object.entries(peer.producers ?? {})) {
        if (!producer || producer.closed) continue;
        await this.#attach(producer, peer.id, normaliseSource(source, producer.kind));
      }
    }

    // 4. Tell the sidecar the full session SDP, then let RTP flow.
    await sidecar('POST', `/sessions/${this.recordingId}/start`, {
      sdp: this.recorder.toSessionSdp(),
      tracks: this.recorder.describe().map(publicTrack),
    });
    await this.recorder.resumeAll();

    this.status = 'recording';
    this.startedAt = new Date();
    this.#startHeartbeat();
    await this.#persistState();

    metrics.increment('sfu.recording.started');
    log.info(
      { recordingId: this.recordingId, roomId: this.roomId, tracks: this.recorder.describe().length },
      'recording started',
    );

    return this.describe();
  }

  /**
   * A new producer appeared while recording (camera on, screen share started).
   * @param {import('mediasoup').types.Producer} producer
   * @param {string} peerId
   * @param {string} source
   */
  async addProducer(producer, peerId, source) {
    if (this.status !== 'recording') return;
    const descriptor = await this.#attach(producer, peerId, normaliseSource(source, producer.kind));
    if (!descriptor) return;

    await sidecar('POST', `/sessions/${this.recordingId}/tracks/${descriptor.trackId}/start`, {
      sdp: descriptor.sdp,
      track: publicTrack(descriptor),
    });
    await this.recorder.resumeProducer(producer.id);
  }

  /**
   * @param {'host-stopped'|'room-closed'|'node-drain'|'sidecar-failed'|'error'} reason
   */
  async stop(reason) {
    if (this.status === 'stopped' || this.status === 'stopping') return this.describe();
    this.status = 'stopping';
    this.#stopHeartbeat();
    this.endedAt = new Date();

    const tracks = this.recorder?.describe().map(publicTrack) ?? [];

    // Stop RTP before the sidecar finalises, otherwise the last segment gets
    // a truncated tail.
    await this.recorder?.close();

    /** @type {{ segments?: number, bytes?: number, durationMs?: number }} */
    let finalised = {};
    try {
      finalised = await sidecar('POST', `/sessions/${this.recordingId}/stop`, { reason });
    } catch (err) {
      // A dead sidecar must not swallow the recording: whatever segments
      // already reached S3 are still worth muxing.
      this.error = `sidecar finalise failed: ${err.message}`;
      log.error({ err, recordingId: this.recordingId }, 'sidecar finalise failed');
    }

    this.status = this.error ? 'failed' : 'stopped';
    await this.#enqueueMux({ reason, tracks, ...finalised });
    await this.#clearState();

    metrics.increment('sfu.recording.stopped', { reason, status: this.status });
    log.info(
      {
        recordingId: this.recordingId,
        roomId: this.roomId,
        reason,
        status: this.status,
        durationMs: this.endedAt - (this.startedAt ?? this.endedAt),
      },
      'recording stopped',
    );

    this.emit('stopped', this.describe());
    this.removeAllListeners();
    return this.describe();
  }

  describe() {
    return {
      recordingId: this.recordingId,
      roomId: this.roomId,
      lessonId: this.lessonId,
      tenantId: this.tenantId,
      status: this.status,
      startedAt: this.startedAt?.toISOString() ?? null,
      endedAt: this.endedAt?.toISOString() ?? null,
      bucket: this.bucket,
      keyPrefix: this.keyPrefix,
      trackCount: this.recorder?.describe().length ?? 0,
      error: this.error,
    };
  }

  /* ---------------------------------------------------------------------- */

  async #attach(producer, peerId, source) {
    try {
      return await this.recorder.addProducer({ producer, peerId, source });
    } catch (err) {
      log.error(
        { err, recordingId: this.recordingId, producerId: producer.id },
        'failed to attach producer to recording',
      );
      metrics.increment('sfu.recording.track_error');
      return null;
    }
  }

  #startHeartbeat() {
    this.heartbeat = setInterval(() => {
      this.#tick().catch((err) =>
        log.warn({ err, recordingId: this.recordingId }, 'recording heartbeat failed'),
      );
    }, HEARTBEAT_INTERVAL_MS);
    this.heartbeat.unref();
  }

  #stopHeartbeat() {
    if (this.heartbeat) clearInterval(this.heartbeat);
    this.heartbeat = null;
  }

  async #tick() {
    if (this.status !== 'recording') return;

    const stats = (await this.recorder?.stats()) ?? [];
    const bytes = stats.reduce((sum, s) => sum + s.byteCount, 0);
    if (bytes > this.lastByteCount) {
      this.lastByteCount = bytes;
      this.lastProgressAt = Date.now();
    }

    metrics.gauge('sfu.recording.bytes', bytes, { roomId: this.roomId });
    metrics.gauge('sfu.recording.tracks', stats.length, { roomId: this.roomId });

    await this.#persistState();

    // Sidecar liveness. Two consecutive failures or a stalled byte counter
    // means the recording is dead; stop it so the mux job runs on what exists
    // instead of producing a silent gap nobody notices until playback.
    const healthy = await sidecar('GET', `/sessions/${this.recordingId}/status`)
      .then((s) => s?.healthy !== false)
      .catch(() => false);

    const stalled = Date.now() - this.lastProgressAt > STALL_THRESHOLD_MS;

    if (!healthy || stalled) {
      log.error(
        { recordingId: this.recordingId, healthy, stalled },
        'recording unhealthy, stopping',
      );
      metrics.increment('sfu.recording.unhealthy');
      await this.stop('sidecar-failed');
    }
  }

  async #persistState() {
    // Lets api/ answer "is this lesson recording?" without an RPC to the node.
    await this.stateRedis.set(
      stateKey(this.recordingId),
      JSON.stringify({ ...this.describe(), nodeId: env.SFU_NODE_ID ?? null }),
      'EX',
      SESSION_STATE_TTL_S,
    );
    await this.stateRedis.set(
      roomIndexKey(this.roomId),
      this.recordingId,
      'EX',
      SESSION_STATE_TTL_S,
    );
  }

  async #clearState() {
    await Promise.allSettled([
      this.stateRedis.del(stateKey(this.recordingId)),
      this.stateRedis.del(roomIndexKey(this.roomId)),
    ]);
  }

  async #enqueueMux({ reason, tracks, segments, bytes, durationMs }) {
    const payload = {
      recordingId: this.recordingId,
      tenantId: this.tenantId,
      lessonId: this.lessonId,
      roomId: this.roomId,
      startedBy: this.startedBy,
      bucket: this.bucket,
      keyPrefix: this.keyPrefix,
      startedAt: this.startedAt?.toISOString() ?? null,
      endedAt: this.endedAt?.toISOString() ?? null,
      durationMs: durationMs ?? (this.endedAt - (this.startedAt ?? this.endedAt)),
      segments: segments ?? null,
      bytes: bytes ?? this.lastByteCount,
      tracks,
      stopReason: reason,
      partial: Boolean(this.error),
      release: env.RELEASE_SHA,
    };

    try {
      await recordingQueue.add('recording.mux', payload, {
        // Idempotent: a retried stop (drain racing a host click) must not
        // create a second asset.
        jobId: `mux:${this.recordingId}`,
      });
      log.info({ recordingId: this.recordingId }, 'mux job queued');
    } catch (err) {
      // Losing the job is the one genuinely bad outcome here — the segments
      // exist but nothing would ever turn them into an asset. Log at error so
      // the reconcile sweeper (jobs/reconcileTranscodes.js) picks it up.
      log.error({ err, recordingId: this.recordingId, payload }, 'failed to queue mux job');
      metrics.increment('sfu.recording.mux_enqueue_failed');
    }
  }
}

/* ========================================================================== */
/* Pipeline (one per SFU process)                                             */
/* ========================================================================== */

export class RecordingPipeline {
  /** @param {{ stateRedis: import('ioredis').Redis }} deps */
  constructor({ stateRedis }) {
    this.stateRedis = stateRedis;
    /** @type {Map<string, RecordingSession>} keyed by roomId */
    this.sessions = new Map();
  }

  isRecording(roomId) {
    return this.sessions.has(roomId);
  }

  /**
   * Start recording a room. Called from rpcHandlers on the host's request.
   * @param {object} args
   * @param {import('mediasoup').types.Router} args.router
   * @param {object} args.room
   * @param {string} args.tenantId
   * @param {string} args.lessonId
   * @param {string} args.startedBy
   */
  async start({ router, room, tenantId, lessonId, startedBy }) {
    const existing = this.sessions.get(room.id);
    if (existing) return existing.describe();

    if (!env.S3_BUCKET_RECORDINGS) {
      throw new Error('recording is not configured on this node (S3_BUCKET_RECORDINGS missing)');
    }

    const session = new RecordingSession({
      router,
      room,
      tenantId,
      lessonId,
      startedBy,
      stateRedis: this.stateRedis,
    });
    this.sessions.set(room.id, session);
    session.once('stopped', () => this.sessions.delete(room.id));

    try {
      return await session.start();
    } catch (err) {
      this.sessions.delete(room.id);
      await session.stop('error').catch(() => {});
      throw err;
    }
  }

  /**
   * @param {string} roomId
   * @param {'host-stopped'|'room-closed'|'node-drain'|'error'} [reason]
   */
  async stop(roomId, reason = 'host-stopped') {
    const session = this.sessions.get(roomId);
    if (!session) return null;
    return session.stop(reason);
  }

  /** Called by RoomManager whenever a peer starts producing. */
  async onProducerAdded({ roomId, producer, peerId, source }) {
    const session = this.sessions.get(roomId);
    if (!session) return;
    await session.addProducer(producer, peerId, source).catch((err) =>
      log.warn({ err, roomId, producerId: producer.id }, 'could not add producer to recording'),
    );
  }

  /** Called by RoomManager when the last peer leaves or the host ends the lesson. */
  async onRoomClosed(roomId) {
    await this.stop(roomId, 'room-closed');
  }

  /**
   * lifecycle/drainSfu.js: the node is terminating. Every session is finalised
   * so its segments get muxed; rooms themselves are re-placed by
   * RoomPlacementService and a new recording starts on the new node.
   */
  async drain() {
    const roomIds = [...this.sessions.keys()];
    log.info({ sessions: roomIds.length }, 'draining recordings');
    await Promise.allSettled(roomIds.map((id) => this.stop(id, 'node-drain')));
  }

  /** For /healthz/sfu. */
  describe() {
    return [...this.sessions.values()].map((s) => s.describe());
  }

  async close() {
    await this.drain();
    await recordingQueue.close();
  }
}

/* ========================================================================== */
/* Helpers                                                                    */
/* ========================================================================== */

const stateKey = (recordingId) => `recording:${recordingId}`;
const roomIndexKey = (roomId) => `recording:room:${roomId}`;

/** @param {import('./PlainTransportRecorder.js').TrackDescriptor} d */
function publicTrack(d) {
  return {
    trackId: d.trackId,
    peerId: d.peerId,
    kind: d.kind,
    source: d.source,
    ports: d.ports,
  };
}

function normaliseSource(source, kind) {
  if (source === 'screen' && kind === 'audio') return 'screen-audio';
  if (source === 'mic' || source === 'cam' || source === 'screen') return source;
  return kind === 'audio' ? 'mic' : 'cam';
}

/**
 * Loopback HTTP to the capture sidecar in the same task.
 * @param {'GET'|'POST'|'DELETE'} method
 * @param {string} path
 * @param {unknown} [body]
 */
async function sidecar(method, path, body) {
  const res = await fetch(`${SIDECAR_URL}${path}`, {
    method,
    headers: body ? { 'content-type': 'application/json' } : undefined,
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(SIDECAR_TIMEOUT_MS),
  });

  if (!res.ok) {
    const detail = await res.text().catch(() => '');
    throw new Error(`capture sidecar ${method} ${path} -> HTTP ${res.status} ${detail}`.trim());
  }

  if (res.status === 204) return undefined;
  const text = await res.text();
  return text ? JSON.parse(text) : undefined;
}

export default RecordingPipeline;