/**
 * server/src/queues/queues.js
 *
 * Queue definitions and typed producers.  (F7)
 *
 * Four queues, one per concern, all on the state Redis cluster:
 *
 *   transcode  MediaConvert submit + poll, caption jobs            (F4)
 *   notify     push, email and in-app fan-out                      (F2, F5, F6)
 *   chat       unread counters, mentions, digests, retention sweep (F6)
 *   recording  mux uploaded segments into an asset                 (F1, F4)
 *
 * This module is imported by producers (api, realtime, sfu) and by
 * worker.js, which attaches the consumers from queues/workers/. Importing it
 * creates Queue objects only — never a Worker — so an api task never starts
 * processing jobs by accident.
 *
 * Job names are part of the contract between producer and consumer. They are
 * exported as constants so a typo fails at import time instead of silently
 * queueing a job nobody consumes.
 *
 * v6 producer/consumer API: the workers in queues/workers/, the jobs in jobs/
 * and several services still use the v6 names (QUEUE_NAMES, enqueue(queue,
 * name, data), defineWorker, PermanentJobError, enqueueNotification, …). They
 * are provided at the bottom of this file on top of the v7 queues, so both
 * styles address the same four-plus-one queues.
 *
 * Node.js 22, ESM.
 */

import * as bullmq from 'bullmq';

import { env } from '../config/env.js';

import { queueOptions, workerOptions } from './connection.js';
import { logger } from '../observability/logger.js';
import { metrics } from '../observability/metrics.js';

const { Queue, Worker } = bullmq;

const log = logger.child({ component: 'queues' });

/* -------------------------------------------------------------------------- */
/* Names                                                                       */
/* -------------------------------------------------------------------------- */

export const QUEUE = Object.freeze({
  TRANSCODE: 'transcode',
  NOTIFY: 'notify',
  CHAT: 'chat',
  RECORDING: 'recording',
  MAINTENANCE: 'maintenance',
});

export const JOB = Object.freeze({
  // transcode
  TRANSCODE_SUBMIT: 'transcode.submit',
  TRANSCODE_POLL: 'transcode.poll',
  // Must match the handler key in workers/transcodeWorker.js.
  TRANSCRIBE_SUBMIT: 'transcript.submit',
  ASSET_SCAN: 'asset.scan',
  // notify
  NOTIFY_PUSH: 'notify.push',
  NOTIFY_EMAIL: 'notify.email',
  NOTIFY_IN_APP: 'notify.inApp',
  NOTIFY_DIGEST: 'notify.digest',
  // chat
  // Must match the handler key in workers/chatFanoutWorker.js.
  CHAT_FANOUT: 'chat.message.fanout',
  CHAT_MENTION: 'chat.mention',
  CHAT_RETENTION: 'chat.retention',
  // recording
  RECORDING_MUX: 'recording.mux',
  RECORDING_CLEANUP: 'recording.cleanup',
});

/* -------------------------------------------------------------------------- */
/* Queues                                                                      */
/* -------------------------------------------------------------------------- */

/**
 * Per-queue overrides. Anything not listed inherits defaultJobOptions from
 * connection.js.
 */
const overrides = {
  [QUEUE.TRANSCODE]: {
    defaultJobOptions: {
      // MediaConvert polling is cheap and long-running; give it room.
      attempts: 10,
      backoff: { type: 'exponential', delay: 15_000 },
    },
  },
  [QUEUE.NOTIFY]: {
    defaultJobOptions: {
      // A push notification that is four hours late is noise, not delivery.
      attempts: 4,
      backoff: { type: 'exponential', delay: 3_000 },
      removeOnComplete: { age: 3_600, count: 5_000 },
    },
  },
  [QUEUE.CHAT]: {
    defaultJobOptions: {
      attempts: 6,
      backoff: { type: 'exponential', delay: 1_000 },
      removeOnComplete: { age: 3_600, count: 10_000 },
    },
  },
  [QUEUE.MAINTENANCE]: {
    defaultJobOptions: {
      // Sweeps run again on the next tick; retrying one hard only piles up.
      attempts: 2,
      backoff: { type: 'fixed', delay: 30_000 },
      removeOnComplete: { age: 24 * 3_600, count: 500 },
    },
  },
  [QUEUE.RECORDING]: {
    defaultJobOptions: {
      // Muxing an hour of class is expensive; do not retry it into the ground.
      attempts: 3,
      backoff: { type: 'exponential', delay: 60_000 },
      removeOnComplete: { age: 7 * 24 * 3_600, count: 500 },
      removeOnFail: false, // keep every failure: segments are still in S3
    },
  },
};

/** @type {Map<string, Queue>} */
const registry = new Map();

/**
 * @param {string} name
 * @returns {Queue}
 */
export function getQueue(name) {
  let queue = registry.get(name);
  if (queue) return queue;

  queue = new Queue(name, {
    ...queueOptions,
    ...overrides[name],
    defaultJobOptions: {
      ...queueOptions.defaultJobOptions,
      ...overrides[name]?.defaultJobOptions,
    },
  });

  queue.on('error', (err) => {
    log.error({ err, queue: name }, 'queue error');
    metrics.increment('queue.error', { queue: name });
  });

  registry.set(name, queue);
  return queue;
}

export const transcodeQueue = getQueue(QUEUE.TRANSCODE);
export const notifyQueue = getQueue(QUEUE.NOTIFY);
export const chatQueue = getQueue(QUEUE.CHAT);
export const recordingQueue = getQueue(QUEUE.RECORDING);
export const maintenanceQueue = getQueue(QUEUE.MAINTENANCE);

export const queues = {
  [QUEUE.TRANSCODE]: transcodeQueue,
  [QUEUE.NOTIFY]: notifyQueue,
  [QUEUE.CHAT]: chatQueue,
  [QUEUE.RECORDING]: recordingQueue,
  [QUEUE.MAINTENANCE]: maintenanceQueue,
};

/* -------------------------------------------------------------------------- */
/* Producers                                                                   */
/* -------------------------------------------------------------------------- */

/**
 * Every producer passes an explicit jobId derived from the domain object.
 * BullMQ deduplicates on jobId, so a retried HTTP request, a redelivered
 * webhook or a drain racing a user action cannot create two jobs.
 *
 * Every job in the codebase is added through this function (the v6 enqueue()
 * below included), which is what makes the id normalisation complete.
 *
 * @param {Queue} queue
 * @param {string} name
 * @param {object} data
 * @param {import('bullmq').JobsOptions} [opts]
 */
async function add(queue, name, data, opts = {}) {
  // BullMQ 5 rejects custom job ids containing ':' ("Custom Id cannot contain
  // :"), and every producer here builds ids like `transcode:<assetId>`. They
  // are normalised in this one place, deterministically, so deduplication
  // still works: the same domain object always yields the same id.
  if (opts.jobId !== undefined && opts.jobId !== null) {
    opts = { ...opts, jobId: String(opts.jobId).replaceAll(':', '.') };
  }
  try {
    const job = await queue.add(name, data, opts);
    metrics.increment('queue.enqueued', { queue: queue.name, job: name });
    return job;
  } catch (err) {
    log.error({ err, queue: queue.name, job: name, jobId: opts.jobId }, 'enqueue failed');
    metrics.increment('queue.enqueue_failed', { queue: queue.name, job: name });
    throw err;
  }
}

export const jobs = {
  /** @param {{ assetId: string, tenantId: string, sourceKey: string }} data */
  transcodeAsset: (data) =>
    add(transcodeQueue, JOB.TRANSCODE_SUBMIT, data, { jobId: `transcode:${data.assetId}` }),

  /** @param {{ assetId: string, jobId: string }} data */
  pollTranscode: (data, delayMs = 15_000) =>
    add(transcodeQueue, JOB.TRANSCODE_POLL, data, {
      jobId: `transcode-poll:${data.assetId}:${Date.now()}`,
      delay: delayMs,
    }),

  /** @param {{ assetId: string, languageCode?: string }} data */
  transcribeAsset: (data) =>
    add(transcodeQueue, JOB.TRANSCRIBE_SUBMIT, data, { jobId: `transcript:${data.assetId}` }),

  /** @param {{ userId: string, kind: string, payload: object, dedupeKey: string }} data */
  notify: (data) =>
    add(notifyQueue, JOB.NOTIFY_IN_APP, data, { jobId: `notify:${data.dedupeKey}` }),

  /** @param {{ messageId: string, conversationId: string, senderId: string }} data */
  fanoutChatMessage: (data) =>
    add(chatQueue, JOB.CHAT_FANOUT, data, { jobId: `chat-fanout:${data.messageId}` }),

  /** @param {object} data see recordingPipeline.#enqueueMux */
  muxRecording: (data) =>
    add(recordingQueue, JOB.RECORDING_MUX, data, { jobId: `mux:${data.recordingId}` }),

  /** @param {{ recordingId: string, bucket: string, keyPrefix: string }} data */
  cleanupRecordingSegments: (data, delayMs = 24 * 3_600 * 1_000) =>
    add(recordingQueue, JOB.RECORDING_CLEANUP, data, {
      jobId: `mux-cleanup:${data.recordingId}`,
      delay: delayMs,
    }),
};

/* -------------------------------------------------------------------------- */
/* v6 API                                                                      */
/* -------------------------------------------------------------------------- */

/** v6 name for QUEUE. */
export const QUEUE_NAMES = QUEUE;

/**
 * A failure that retrying cannot fix: a missing row, a rejected payload, an
 * unknown job name. Extends BullMQ's UnrecoverableError, so the job goes
 * straight to failed instead of burning its remaining attempts.
 */
const Unrecoverable = bullmq.UnrecoverableError ?? Error;

export class PermanentJobError extends Unrecoverable {
  /**
   * @param {string} message
   * @param {object} [details]  logged with the failure
   */
  constructor(message, details = {}) {
    super(message);
    this.name = 'PermanentJobError';
    this.details = details;
  }
}

/**
 * Enqueue by queue name: enqueue(QUEUE_NAMES.NOTIFY, 'notification.fanout', data, opts).
 * @param {string} queueName
 * @param {string} jobName
 * @param {object} data
 * @param {import('bullmq').JobsOptions} [opts]
 */
export function enqueue(queueName, jobName, data, opts = {}) {
  const queue = queues[queueName];
  if (!queue) throw new Error(`enqueue: unknown queue '${queueName}'`);
  return add(queue, jobName, data, opts);
}

const withoutUndefined = (object) =>
  Object.fromEntries(Object.entries(object ?? {}).filter(([, value]) => value !== undefined));

/**
 * Builds a BullMQ Worker for one queue. The processor receives (job, log),
 * where log is a child logger carrying the queue, job name and job id.
 *
 * Options left undefined by the caller (transcodeWorker passes
 * `concurrency: undefined`) fall back to the shared defaults instead of
 * overriding them with undefined.
 *
 * @param {string} queueName
 * @param {(job: import('bullmq').Job, log: import('pino').Logger) => Promise<unknown>} processor
 * @param {import('bullmq').WorkerOptions} [opts]
 * @returns {import('bullmq').Worker}
 */
export function defineWorker(queueName, processor, opts = {}) {
  if (!queues[queueName]) throw new Error(`defineWorker: unknown queue '${queueName}'`);

  const worker = new Worker(
    queueName,
    async (job) => {
      const jobLog = log.child({ queue: queueName, job: job.name, jobId: job.id });
      return processor(job, jobLog);
    },
    {
      ...workerOptions,
      concurrency: env.WORKER_CONCURRENCY ?? 1,
      ...withoutUndefined(opts),
    },
  );

  worker.on('failed', (job, err) => {
    const permanent = err instanceof PermanentJobError;
    log[permanent ? 'error' : 'warn'](
      { err, queue: queueName, job: job?.name, jobId: job?.id, attempts: job?.attemptsMade, permanent, details: err?.details },
      permanent ? 'job failed permanently' : 'job failed, will retry if attempts remain',
    );
    metrics.increment('queue.failed', { queue: queueName, job: job?.name ?? 'unknown', permanent: String(permanent) });
  });

  worker.on('error', (err) => {
    log.error({ err, queue: queueName }, 'worker error');
  });

  return worker;
}

/** v6 name for collectDepths(). */
export const collectQueueMetrics = collectDepths;

const minutes = (value) => (Number(value) > 0 ? Number(value) * 60_000 : undefined);

/**
 * Notification producers (community/NotificationService, identity/AuthService).
 * The job name is passed through unchanged; notificationWorker decides by name.
 * A dedupeKey makes the job id stable, so a retried request queues it once.
 *
 * @param {string} jobName  e.g. 'notification.push', 'notification.email', 'notification.fanout'
 * @param {object} data
 */
export function enqueueNotification(jobName, data = {}) {
  const dedupeKey = data.dedupeKey ?? null;
  return add(notifyQueue, jobName, data, withoutUndefined({
    jobId: dedupeKey ? `${jobName}:${dedupeKey}` : undefined,
    delay: minutes(data.delayMinutes),
  }));
}

/**
 * A scanned upload, or a finished recording, goes to MediaConvert.
 * Same job id as jobs.transcodeAsset, so both producers deduplicate together.
 * @param {{ assetId: string, purpose?: string, ladder?: string }} data
 */
export function enqueueTranscode({ assetId, purpose = null, ladder } = {}) {
  if (!assetId) throw new Error('enqueueTranscode needs an assetId');
  const selected = ladder ?? (purpose === 'recording' ? 'recording' : 'standard');
  return add(transcodeQueue, JOB.TRANSCODE_SUBMIT, { assetId, purpose, ladder: selected }, { jobId: `transcode:${assetId}` });
}

/**
 * Captions for a transcoded asset. Handled by transcodeWorker ('transcript.submit').
 * @param {{ assetId: string, language?: string }} data
 */
export function enqueueTranscript({ assetId, language = 'en' } = {}) {
  if (!assetId) throw new Error('enqueueTranscript needs an assetId');
  return add(transcodeQueue, JOB.TRANSCRIBE_SUBMIT, { assetId, language }, { jobId: `transcript:${assetId}` });
}

/**
 * Virus scan of a completed upload.
 *
 * OPEN: no worker consumes 'asset.scan' yet. The job lands on the transcode
 * queue and transcodeWorker fails it permanently as an unknown job, which is
 * visible in the failed set instead of silently lost. Until a scan handler
 * exists, uploads stay in status 'scanning'.
 *
 * @param {{ assetId: string }} data
 */
export function enqueueScan({ assetId } = {}) {
  if (!assetId) throw new Error('enqueueScan needs an assetId');
  return add(transcodeQueue, JOB.ASSET_SCAN, { assetId }, { jobId: `scan:${assetId}` });
}

/**
 * A chat message was stored; unread counters, mentions and pushes follow in
 * chatFanoutWorker ('chat.message.fanout').
 *
 * @param {{ messageId: string, target: { kind: string, conversationId?: string, channelId?: string },
 *           authorId: string, recipients?: string[], preview?: string, mentions?: string[] }} data
 */
export function enqueueChatNotification({ messageId, target = {}, authorId, recipients = [], preview = null, mentions = [] } = {}) {
  if (!messageId) throw new Error('enqueueChatNotification needs a messageId');
  return add(
    chatQueue,
    JOB.CHAT_FANOUT,
    {
      messageId,
      conversationId: target.kind === 'conversation' ? target.conversationId : undefined,
      channelId: target.kind === 'channel' ? target.channelId : undefined,
      senderId: authorId,
      recipients,
      preview,
      mentions,
    },
    { jobId: `chat-fanout:${messageId}` },
  );
}

/* -------------------------------------------------------------------------- */
/* Observability and shutdown                                                  */
/* -------------------------------------------------------------------------- */

/** Feeds the queue-depth scaling signal for the worker service (autoscaling.tf). */
export async function collectDepths() {
  const out = {};
  for (const [name, queue] of Object.entries(queues)) {
    const counts = await queue.getJobCounts('waiting', 'active', 'delayed', 'failed');
    out[name] = counts;
    metrics.gauge('queue.waiting', counts.waiting ?? 0, { queue: name });
    metrics.gauge('queue.active', counts.active ?? 0, { queue: name });
    metrics.gauge('queue.failed', counts.failed ?? 0, { queue: name });
  }
  return out;
}

/** Producers only — workers close themselves. Safe to call more than once. */
export async function closeQueues() {
  await Promise.allSettled([...registry.values()].map((q) => q.close()));
  registry.clear();
}

export default {
  QUEUE, QUEUE_NAMES, JOB, queues, jobs, getQueue, collectDepths, collectQueueMetrics, closeQueues,
  enqueue, defineWorker, PermanentJobError,
  enqueueNotification, enqueueTranscode, enqueueTranscript, enqueueScan, enqueueChatNotification,
};