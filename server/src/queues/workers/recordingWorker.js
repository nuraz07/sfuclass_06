/**
 * server/src/queues/workers/recordingWorker.js
 *
 * Turns the segments a capture sidecar wrote into a playable asset.  (F1, F4)
 *
 * v6 -> v7 correction: v6 had this worker muxing raw RTP, which meant RTP
 * would have had to cross the network and the worker would have had to stay
 * alive for the whole lesson. In v7 the sidecar has already written fMP4
 * segments to S3 during the lesson; this worker starts *after* the recording
 * ended and only has to concatenate, compose, upload and register.
 *
 *   s3://<recordings>/raw/<tenant>/<lesson>/<recordingId>/<trackId>/NNNNN.mp4
 *     -> concat per track
 *     -> compose (primary video + mixed audio)
 *     -> s3://<recordings>/mux/<...>/recording.mp4
 *     -> Asset (status=processing)
 *     -> transcode job (MediaConvert -> HLS ladder) + transcribe job
 *     -> delayed cleanup job for the raw segments
 *
 * Runs in worker.js, in the ffmpeg image (Dockerfile.worker).
 * Idempotent on recordingId: a retry after a partial failure reuses the
 * existing asset instead of creating a second one.
 *
 * Node.js 22, ESM.
 */

import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import { createWriteStream } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';

import { Worker } from 'bullmq';
import {
  S3Client,
  ListObjectsV2Command,
  GetObjectCommand,
  DeleteObjectsCommand,
} from '@aws-sdk/client-s3';
import { Upload } from '@aws-sdk/lib-storage';

import { env } from '../../config/env.js';
import { workerOptions } from '../connection.js';
import { QUEUE, JOB, jobs } from '../queues.js';
import { assetRepository } from '../../media/models/Asset.js';
import { logger } from '../../observability/logger.js';
import { metrics } from '../../observability/metrics.js';

const log = logger.child({ component: 'recording-worker' });

const s3 = new S3Client({ region: env.AWS_REGION ?? env.MEDIA_REGION });

const FFMPEG = env.FFMPEG_PATH ?? 'ffmpeg';
const MUX_TIMEOUT_MS = env.RECORDING_MUX_TIMEOUT_MS ?? 45 * 60_000;

/* -------------------------------------------------------------------------- */
/* Worker                                                                      */
/* -------------------------------------------------------------------------- */

export function createRecordingWorker() {
  const worker = new Worker(
    QUEUE.RECORDING,
    async (job) => {
      switch (job.name) {
        case JOB.RECORDING_MUX:
          return muxRecording(job);
        case JOB.RECORDING_CLEANUP:
          return cleanupSegments(job);
        default:
          throw new Error(`unknown job "${job.name}" on the recording queue`);
      }
    },
    {
      ...workerOptions,
      // Muxing is CPU- and disk-bound. One at a time per task; the worker
      // service scales out on queue depth instead.
      concurrency: env.RECORDING_MUX_CONCURRENCY ?? 1,
      lockDuration: 5 * 60_000,
      lockRenewTime: 60_000,
    },
  );

  worker.on('completed', (job, result) => {
    log.info({ jobId: job.id, name: job.name, assetId: result?.assetId }, 'recording job completed');
    metrics.increment('recording.job.completed', { name: job.name });
  });

  worker.on('failed', (job, err) => {
    log.error({ err, jobId: job?.id, name: job?.name, attempts: job?.attemptsMade }, 'recording job failed');
    metrics.increment('recording.job.failed', { name: job?.name ?? 'unknown' });
  });

  return worker;
}

/* -------------------------------------------------------------------------- */
/* recording.mux                                                               */
/* -------------------------------------------------------------------------- */

/**
 * @param {import('bullmq').Job} job
 */
async function muxRecording(job) {
  const {
    recordingId,
    tenantId,
    lessonId,
    roomId,
    bucket,
    keyPrefix,
    startedAt,
    endedAt,
    durationMs,
    tracks = [],
    partial = false,
  } = job.data;

  const startedProcessingAt = Date.now();
  const workDir = await fs.mkdtemp(path.join(os.tmpdir(), `rec-${recordingId}-`));

  try {
    // 1. Idempotency. A retry must not produce a second asset.
    const existing = await assetRepository.findBySourceRef(`recording:${recordingId}`);
    if (existing && existing.status !== 'failed') {
      log.info({ recordingId, assetId: existing.id }, 'asset already exists, skipping mux');
      return { assetId: existing.id, skipped: true };
    }

    // 2. Collect what the sidecar actually wrote.
    const segments = await listSegments({ bucket, keyPrefix });
    if (segments.size === 0) {
      // Nothing to mux. This is a real outcome (host started and stopped
      // within a second, or the sidecar died before its first flush) and must
      // not be retried five times.
      log.warn({ recordingId, keyPrefix }, 'no segments found, nothing to mux');
      metrics.increment('recording.mux.empty');
      return { assetId: null, empty: true };
    }

    await job.updateProgress(10);

    // 3. Download and concatenate per track.
    const trackFiles = [];
    let downloaded = 0;
    for (const [trackId, keys] of segments) {
      const meta = tracks.find((t) => t.trackId === trackId) ?? inferTrack(trackId);
      const file = await concatTrack({ bucket, keys, trackId, workDir });
      trackFiles.push({ ...meta, trackId, file });
      downloaded += 1;
      await job.updateProgress(10 + Math.round((downloaded / segments.size) * 40));
    }

    // 4. Compose one file: the presenter's screen share if there was one,
    //    otherwise the first camera; all audio tracks mixed.
    const outputPath = path.join(workDir, 'recording.mp4');
    await compose({ trackFiles, outputPath });
    await job.updateProgress(75);

    // 5. Upload the mux result next to the segments.
    const outputKey = `${keyPrefix.replace(/^raw\//, 'mux/')}recording.mp4`;
    const { size } = await fs.stat(outputPath);
    await uploadFile({ bucket, key: outputKey, filePath: outputPath, contentType: 'video/mp4' });
    await job.updateProgress(85);

    // 6. Register the asset. It enters the normal media domain from here:
    //    transcoding, captions, signed delivery, retention, quotas.
    const asset = await assetRepository.create({
      tenantId,
      kind: 'recording',
      status: 'processing',
      sourceRef: `recording:${recordingId}`,
      bucket,
      key: outputKey,
      sizeBytes: size,
      durationMs: durationMs ?? null,
      metadata: {
        recordingId,
        lessonId,
        roomId,
        startedAt,
        endedAt,
        trackCount: trackFiles.length,
        partial,
      },
    });

    await jobs.transcodeAsset({ assetId: asset.id, tenantId, sourceKey: outputKey });
    if (env.RECORDING_AUTO_CAPTIONS !== false) {
      await jobs.transcribeAsset({ assetId: asset.id });
    }

    // 7. Raw segments stay for a day so a failed transcode can be re-run from
    //    the source, then a delayed job removes them.
    await jobs.cleanupRecordingSegments({ recordingId, bucket, keyPrefix });

    await job.updateProgress(100);

    metrics.increment('recording.mux.completed', { partial: String(partial) });
    metrics.gauge('recording.mux.duration_ms', Date.now() - startedProcessingAt);
    log.info(
      {
        recordingId,
        assetId: asset.id,
        tracks: trackFiles.length,
        sizeBytes: size,
        muxMs: Date.now() - startedProcessingAt,
      },
      'recording muxed',
    );

    return { assetId: asset.id, key: outputKey, sizeBytes: size };
  } finally {
    // Containers are stateless: never leave gigabytes behind on the task's
    // ephemeral volume, whatever happened above.
    await fs.rm(workDir, { recursive: true, force: true }).catch((err) =>
      log.warn({ err, workDir }, 'temp cleanup failed'),
    );
  }
}

/* -------------------------------------------------------------------------- */
/* recording.cleanup                                                           */
/* -------------------------------------------------------------------------- */

async function cleanupSegments(job) {
  const { recordingId, bucket, keyPrefix } = job.data;

  const asset = await assetRepository.findBySourceRef(`recording:${recordingId}`);
  if (!asset || asset.status === 'failed') {
    // The mux never succeeded — keep the segments, they are the only copy.
    log.warn({ recordingId }, 'skipping segment cleanup, no ready asset');
    return { deleted: 0, skipped: true };
  }

  const segments = await listSegments({ bucket, keyPrefix });
  const keys = [...segments.values()].flat();
  let deleted = 0;

  for (let i = 0; i < keys.length; i += 1_000) {
    const chunk = keys.slice(i, i + 1_000);
    await s3.send(
      new DeleteObjectsCommand({
        Bucket: bucket,
        Delete: { Objects: chunk.map((Key) => ({ Key })), Quiet: true },
      }),
    );
    deleted += chunk.length;
  }

  log.info({ recordingId, deleted }, 'raw segments removed');
  return { deleted };
}

/* -------------------------------------------------------------------------- */
/* S3 helpers                                                                  */
/* -------------------------------------------------------------------------- */

/**
 * @returns {Promise<Map<string, string[]>>} trackId -> ordered segment keys
 */
async function listSegments({ bucket, keyPrefix }) {
  /** @type {Map<string, string[]>} */
  const byTrack = new Map();
  let ContinuationToken;

  do {
    const res = await s3.send(
      new ListObjectsV2Command({ Bucket: bucket, Prefix: keyPrefix, ContinuationToken }),
    );
    for (const obj of res.Contents ?? []) {
      if (!obj.Key || obj.Size === 0) continue;
      const rest = obj.Key.slice(keyPrefix.length);
      const [trackId, file] = rest.split('/');
      if (!trackId || !file) continue;
      if (!byTrack.has(trackId)) byTrack.set(trackId, []);
      byTrack.get(trackId).push(obj.Key);
    }
    ContinuationToken = res.IsTruncated ? res.NextContinuationToken : undefined;
  } while (ContinuationToken);

  // Segment names are zero-padded counters, so lexical order is time order.
  for (const keys of byTrack.values()) keys.sort();
  return byTrack;
}

async function downloadObject({ bucket, key, destination }) {
  const res = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
  await pipeline(res.Body, createWriteStream(destination));
}

async function uploadFile({ bucket, key, filePath, contentType }) {
  const handle = await fs.open(filePath, 'r');
  try {
    const upload = new Upload({
      client: s3,
      params: {
        Bucket: bucket,
        Key: key,
        Body: handle.createReadStream(),
        ContentType: contentType,
        ServerSideEncryption: 'aws:kms',
        SSEKMSKeyId: env.S3_KMS_KEY_ID,
      },
      queueSize: 4,
      partSize: 16 * 1024 * 1024,
    });
    await upload.done();
  } finally {
    await handle.close();
  }
}

/* -------------------------------------------------------------------------- */
/* ffmpeg                                                                      */
/* -------------------------------------------------------------------------- */

/**
 * Concatenate one track's segments. The segments are already fMP4 with the
 * same codec parameters, so this is a stream copy — no re-encode, no quality
 * loss, seconds instead of minutes.
 */
async function concatTrack({ bucket, keys, trackId, workDir }) {
  const trackDir = path.join(workDir, trackId);
  await fs.mkdir(trackDir, { recursive: true });

  const localFiles = [];
  for (const [index, key] of keys.entries()) {
    const destination = path.join(trackDir, `${String(index).padStart(6, '0')}.mp4`);
    await downloadObject({ bucket, key, destination });
    localFiles.push(destination);
  }

  const listPath = path.join(trackDir, 'segments.txt');
  await fs.writeFile(
    listPath,
    localFiles.map((f) => `file '${f.replaceAll("'", "'\\''")}'`).join('\n'),
    'utf8',
  );

  const output = path.join(workDir, `${trackId}.mp4`);
  await runFfmpeg([
    '-f', 'concat',
    '-safe', '0',
    '-i', listPath,
    '-c', 'copy',
    '-movflags', '+faststart',
    output,
  ]);

  return output;
}

/**
 * Compose the final file.
 *
 * Layout 'primary': the screen share if the lesson had one, otherwise the
 * first camera track, with every audio track mixed down. This is what people
 * actually rewatch; a full grid composition is a separate, much more expensive
 * job and is deliberately not done here.
 */
async function compose({ trackFiles, outputPath }) {
  const videos = trackFiles.filter((t) => t.kind === 'video');
  const audios = trackFiles.filter((t) => t.kind === 'audio');

  const primary =
    videos.find((t) => t.source === 'screen') ??
    videos.find((t) => t.source === 'cam') ??
    videos[0];

  if (!primary && audios.length === 0) {
    throw new Error('compose: no usable track');
  }

  const args = ['-y'];
  const inputs = [];

  if (primary) {
    args.push('-i', primary.file);
    inputs.push(primary);
  }
  for (const audio of audios) {
    args.push('-i', audio.file);
    inputs.push(audio);
  }

  if (audios.length > 1) {
    const audioStart = primary ? 1 : 0;
    const mix = audios
      .map((_, i) => `[${audioStart + i}:a]`)
      .join('');
    args.push(
      '-filter_complex',
      `${mix}amix=inputs=${audios.length}:duration=longest:dropout_transition=2,dynaudnorm[aout]`,
      '-map', '[aout]',
    );
  } else if (audios.length === 1) {
    args.push('-map', `${primary ? 1 : 0}:a`);
  }

  if (primary) {
    args.push('-map', '0:v');
    // Video is copied: the sidecar already produced H.264/VP8 fMP4 and
    // MediaConvert builds the HLS ladder afterwards. Re-encoding here would
    // cost CPU twice for nothing.
    args.push('-c:v', 'copy');
  }

  args.push('-c:a', 'aac', '-b:a', '128k', '-ar', '48000');
  args.push('-movflags', '+faststart', '-shortest', outputPath);

  await runFfmpeg(args);
}

/**
 * @param {string[]} args
 */
function runFfmpeg(args) {
  return new Promise((resolve, reject) => {
    const child = spawn(FFMPEG, ['-hide_banner', '-loglevel', 'error', '-nostdin', ...args], {
      stdio: ['ignore', 'ignore', 'pipe'],
    });

    let stderr = '';
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
      if (stderr.length > 16_384) stderr = stderr.slice(-16_384);
    });

    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      reject(new Error(`ffmpeg timed out after ${MUX_TIMEOUT_MS} ms`));
    }, MUX_TIMEOUT_MS);
    timer.unref();

    child.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });

    child.on('close', (code) => {
      clearTimeout(timer);
      if (code === 0) return resolve();
      reject(new Error(`ffmpeg exited with ${code}: ${stderr.trim()}`));
    });
  });
}

/* -------------------------------------------------------------------------- */

/**
 * Fallback when the job payload lost its track list (an old job, or a session
 * that died before it could report). The sidecar encodes kind and source into
 * the track directory name, so the directory is still authoritative.
 */
function inferTrack(trackId) {
  const lower = trackId.toLowerCase();
  const kind = lower.includes('audio') || lower.includes('mic') ? 'audio' : 'video';
  const source = lower.includes('screen') ? 'screen' : kind === 'audio' ? 'mic' : 'cam';
  return { kind, source };
}

export default createRecordingWorker;