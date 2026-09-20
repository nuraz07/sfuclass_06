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
 * Node.js 22, ESM.
 */

import { Queue } from 'bullmq';

import { queueOptions } from './connection.js';
import { logger } from '../observability/logger.js';
import { metrics } from '../observability/metrics.js';

const log = logger.child({ component: 'queues' });

/* -------------------------------------------------------------------------- */
/* Names                                                                       */
/* -------------------------------------------------------------------------- */

export const QUEUE = Object.freeze({
  TRANSCODE: 'transcode',
  NOTIFY: 'notify',
  CHAT: 'chat',
  RECORDING: 'recording',
});

export const JOB = Object.freeze({
  // transcode
  TRANSCODE_SUBMIT: 'transcode.submit',
  TRANSCODE_POLL: 'transcode.poll',
  TRANSCRIBE_SUBMIT: 'transcribe.submit',
  // notify
  NOTIFY_PUSH: 'notify.push',
  NOTIFY_EMAIL: 'notify.email',
  NOTIFY_IN_APP: 'notify.inApp',
  NOTIFY_DIGEST: 'notify.digest',
  // chat
  CHAT_FANOUT: 'chat.fanout',
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

export const queues = {
  [QUEUE.TRANSCODE]: transcodeQueue,
  [QUEUE.NOTIFY]: notifyQueue,
  [QUEUE.CHAT]: chatQueue,
  [QUEUE.RECORDING]: recordingQueue,
};

/* -------------------------------------------------------------------------- */
/* Producers                                                                   */
/* -------------------------------------------------------------------------- */

/**
 * Every producer passes an explicit jobId derived from the domain object.
 * BullMQ deduplicates on jobId, so a retried HTTP request, a redelivered
 * webhook or a drain racing a user action cannot create two jobs.
 *
 * @param {Queue} queue
 * @param {string} name
 * @param {object} data
 * @param {import('bullmq').JobsOptions} [opts]
 */
async function enqueue(queue, name, data, opts = {}) {
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
    enqueue(transcodeQueue, JOB.TRANSCODE_SUBMIT, data, { jobId: `transcode:${data.assetId}` }),

  /** @param {{ assetId: string, jobId: string }} data */
  pollTranscode: (data, delayMs = 15_000) =>
    enqueue(transcodeQueue, JOB.TRANSCODE_POLL, data, {
      jobId: `transcode-poll:${data.assetId}:${Date.now()}`,
      delay: delayMs,
    }),

  /** @param {{ assetId: string, languageCode?: string }} data */
  transcribeAsset: (data) =>
    enqueue(transcodeQueue, JOB.TRANSCRIBE_SUBMIT, data, { jobId: `transcribe:${data.assetId}` }),

  /** @param {{ userId: string, kind: string, payload: object, dedupeKey: string }} data */
  notify: (data) =>
    enqueue(notifyQueue, JOB.NOTIFY_IN_APP, data, { jobId: `notify:${data.dedupeKey}` }),

  /** @param {{ messageId: string, conversationId: string, senderId: string }} data */
  fanoutChatMessage: (data) =>
    enqueue(chatQueue, JOB.CHAT_FANOUT, data, { jobId: `chat-fanout:${data.messageId}` }),

  /** @param {object} data see recordingPipeline.#enqueueMux */
  muxRecording: (data) =>
    enqueue(recordingQueue, JOB.RECORDING_MUX, data, { jobId: `mux:${data.recordingId}` }),

  /** @param {{ recordingId: string, bucket: string, keyPrefix: string }} data */
  cleanupRecordingSegments: (data, delayMs = 24 * 3_600 * 1_000) =>
    enqueue(recordingQueue, JOB.RECORDING_CLEANUP, data, {
      jobId: `mux-cleanup:${data.recordingId}`,
      delay: delayMs,
    }),
};

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

export default { QUEUE, JOB, queues, jobs, getQueue, collectDepths, closeQueues };