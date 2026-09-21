// server/src/queues/workers/index.js
/**
 * Worker registry  (F7)
 *
 * The one list of BullMQ workers the worker process runs. worker.js calls
 * createWorkers() and relies on the result being an array of BullMQ Worker
 * instances: it logs worker.name, polls worker.isRunning() for /healthz and
 * closes every worker on shutdown.
 *
 * Each factory builds its own Worker with its own queue name, Redis connection
 * and concurrency, so the options worker.js passes (connection, concurrency)
 * are accepted for compatibility but not forwarded. The factories are the
 * single place where a queue's settings are decided.
 *
 * Adding a queue means adding one line to FACTORIES. A factory that throws
 * stops the boot, and the workers already created are closed first, so a
 * half-started process never sits there looking healthy.
 */

import { createChatFanoutWorker } from './chatFanoutWorker.js';
import { createMaintenanceWorker } from './maintenanceWorker.js';
import { createNotificationWorker } from './notificationWorker.js';
import { createRecordingWorker } from './recordingWorker.js';
import { createTranscodeWorker } from './transcodeWorker.js';

const FACTORIES = Object.freeze({
  transcode: createTranscodeWorker, // F4
  notification: createNotificationWorker, // F2, F6
  chatFanout: createChatFanoutWorker, // F6
  recording: createRecordingWorker, // F1, F4
  maintenance: createMaintenanceWorker, // F7
});

/**
 * @param {{ logger?: import('pino').Logger }} [options]
 * @returns {Promise<import('bullmq').Worker[]>}
 */
export async function createWorkers({ logger } = {}) {
  const workers = [];

  try {
    for (const [key, factory] of Object.entries(FACTORIES)) {
      const worker = await factory();
      if (!worker || typeof worker.isRunning !== 'function') {
        throw new TypeError(`queues/workers: factory '${key}' did not return a BullMQ Worker`);
      }
      workers.push(worker);
      logger?.debug?.({ worker: key, queue: worker.name }, 'worker created');
    }
  } catch (err) {
    await Promise.allSettled(workers.map((worker) => worker.close()));
    throw err;
  }

  return workers;
}

export default createWorkers;