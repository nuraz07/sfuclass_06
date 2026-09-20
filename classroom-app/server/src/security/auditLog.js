// classroom-app/server/src/security/auditLog.js
/**
 * Audit log  (F7, F8)  [EXT]
 *
 * Append-only record of things somebody may later have to answer for: who
 * signed in, who removed whom from a lesson, who downloaded which attachment,
 * who was issued TURN credentials. Rows are inserted and never updated or
 * deleted by the application; retention is a database job, not a code path.
 *
 * Version 7 adds ICE credential issuance (section 4.5). A TURN credential
 * cannot be revoked individually, so the audit trail is one of the four
 * mitigations: bounded TTL, per-user quota, audit trail, secret rotation as the
 * kill switch. The record keeps what an investigation needs — who, when, which
 * room, which TURN nodes, which secret version signed it — and none of what it
 * does not: never the credential, never the raw username, never a client IP.
 *
 * Writes are batched. An audit insert per event would put a round trip in front
 * of every credential mint, and issuance sits directly in the join path. The
 * queue is bounded, flushed on an interval, flushed on shutdown before the
 * pools close (registerShutdown runs onShutdown hooks before the first
 * `phase: 'stores'` step), and mirrored to the structured log so a dropped
 * batch is still reconstructable from CloudWatch.
 */

import { scrub } from './piiRedaction.js';

const FLUSH_INTERVAL_MS = 2_000;
const MAX_BATCH = 100;
/** Beyond this the database is not keeping up; older entries are dropped loudly. */
const MAX_QUEUE = 5_000;

export const AUDIT_ACTIONS = Object.freeze({
  // identity
  AUTH_LOGIN: 'auth.login',
  AUTH_LOGOUT: 'auth.logout',
  AUTH_REFRESH_REUSE: 'auth.refresh.reuse-detected',
  // classroom (F1)
  ROOM_JOIN: 'classroom.join',
  ROOM_REMOVE: 'classroom.remove',
  ROOM_RECORDING: 'classroom.recording',
  // connectivity (F8)
  ICE_ISSUED: 'rtc.ice.issued',
  ICE_DENIED: 'rtc.ice.denied',
  TURN_SECRET_ROTATED: 'rtc.turn.secret-rotated',
  // media and chat
  ASSET_DOWNLOAD: 'media.download',
  MESSAGE_DELETE: 'messaging.delete',
  REPORT_CREATED: 'moderation.report',
});

/**
 * @param {object} deps
 * @param {{ query: (text: string, values: unknown[]) => Promise<unknown> }} deps.db  db/pool.js
 * @param {object} deps.logger
 * @param {{ increment?: Function, gauge?: Function }} [deps.metrics]
 * @param {(hook: () => Promise<void>) => () => void} [deps.onShutdown]  lifecycle/gracefulShutdown.js
 * @param {() => string} [deps.now]
 */
export const createAuditLog = ({
  db,
  logger = console,
  metrics = {},
  onShutdown = null,
  now = () => new Date().toISOString(),
  flushIntervalMs = FLUSH_INTERVAL_MS,
}) => {
  /** @type {object[]} */
  let queue = [];
  let timer = null;
  let flushing = null;

  const schedule = () => {
    if (timer) return;
    timer = setTimeout(() => {
      timer = null;
      void flush();
    }, flushIntervalMs);
    timer.unref?.();
  };

  const insert = async (rows) => {
    // One multi-row INSERT: the batch is small and the statement is fixed.
    const columns = 8;
    const values = rows.flatMap((row) => [
      row.at,
      row.tenantId,
      row.actorId,
      row.action,
      row.targetType,
      row.targetId,
      row.requestId,
      JSON.stringify(row.metadata),
    ]);
    const placeholders = rows
      .map(
        (_row, index) =>
          `($${index * columns + 1}, $${index * columns + 2}, $${index * columns + 3}, $${index * columns + 4}, $${index * columns + 5}, $${index * columns + 6}, $${index * columns + 7}, $${index * columns + 8})`,
      )
      .join(', ');

    await db.query(
      `INSERT INTO audit_log (created_at, tenant_id, actor_id, action, target_type, target_id, request_id, metadata)
       VALUES ${placeholders}`,
      values,
    );
  };

  const flush = async () => {
    if (flushing) return flushing;
    if (queue.length === 0) return undefined;

    const batch = queue.slice(0, MAX_BATCH);
    queue = queue.slice(batch.length);

    flushing = insert(batch)
      .then(() => {
        metrics.increment?.('audit_rows_written', { count: String(batch.length) });
      })
      .catch((cause) => {
        // The rows are already in the structured log; losing the table copy is
        // bad, losing the request that triggered it would be worse.
        logger.error?.({ err: cause, rows: batch.length }, 'audit batch insert failed');
        metrics.increment?.('audit_write_failed');
      })
      .finally(() => {
        flushing = null;
        if (queue.length > 0) schedule();
      });

    return flushing;
  };

  /**
   * @param {object} entry
   * @param {string} entry.action            one of AUDIT_ACTIONS
   * @param {string|null} [entry.actorId]    null for system actions
   * @param {string|null} [entry.tenantId]
   * @param {string|null} [entry.targetType]
   * @param {string|null} [entry.targetId]
   * @param {string|null} [entry.requestId]  requestContext.js
   * @param {object} [entry.metadata]        scrubbed before it is stored
   */
  const record = (entry) => {
    const row = {
      at: entry.at ?? now(),
      tenantId: entry.tenantId ?? null,
      actorId: entry.actorId ?? null,
      action: entry.action,
      targetType: entry.targetType ?? null,
      targetId: entry.targetId ?? entry.roomId ?? entry.targetPeerId ?? null,
      requestId: entry.requestId ?? null,
      metadata: scrub({
        ...(entry.metadata ?? {}),
        ...(entry.roomId ? { roomId: entry.roomId } : {}),
        ...(entry.reason ? { reason: entry.reason } : {}),
      }),
    };

    if (queue.length >= MAX_QUEUE) {
      queue.shift();
      logger.error?.({ action: row.action }, 'audit queue full, dropping the oldest entry');
      metrics.increment?.('audit_dropped');
    }

    queue.push(row);
    // The log is the second copy and it is written immediately.
    logger.info?.({ audit: row }, 'audit');
    schedule();
    return row;
  };

  // -------------------------------------------------------------------------
  // Connectivity (F8)
  // -------------------------------------------------------------------------

  /**
   * One record per minted ICE configuration. The pseudonymous id is the same
   * opaque id that appears in the TURN username, which is what lets a TURN
   * allocation in coturn's logs be traced back to a session here without ever
   * putting a user id, a name or an address into those logs.
   *
   * @param {object} entry
   * @param {string} entry.userId
   * @param {string|null} entry.tenantId
   * @param {string} entry.roomId
   * @param {string} entry.opaqueId          pseudonym from OpaqueUserId.js
   * @param {string|null} entry.deviceSessionId
   * @param {string[]} entry.turnNodes       node names handed out
   * @param {'all'|'relay'} entry.policy
   * @param {number} entry.ttlSec
   * @param {string} entry.secretVersionId   the ring version that signed it
   * @param {boolean} [entry.forcedRelay]    a relay-only recovery retry
   */
  const recordIceIssuance = (entry) =>
    record({
      action: AUDIT_ACTIONS.ICE_ISSUED,
      actorId: entry.userId,
      tenantId: entry.tenantId ?? null,
      targetType: 'room',
      targetId: entry.roomId,
      requestId: entry.requestId ?? null,
      metadata: {
        opaqueId: entry.opaqueId,
        deviceSessionId: entry.deviceSessionId ?? null,
        turnNodes: entry.turnNodes,
        policy: entry.policy,
        ttlSec: entry.ttlSec,
        secretVersionId: entry.secretVersionId,
        forcedRelay: Boolean(entry.forcedRelay),
        region: entry.region ?? null,
      },
    });

  /** A refusal is as interesting as an issuance: quota, policy, not admitted. */
  const recordIceDenied = (entry) =>
    record({
      action: AUDIT_ACTIONS.ICE_DENIED,
      actorId: entry.userId ?? null,
      tenantId: entry.tenantId ?? null,
      targetType: 'room',
      targetId: entry.roomId ?? null,
      metadata: { reason: entry.reason, policy: entry.policy ?? null },
    });

  const detach = onShutdown?.(async () => {
    if (timer) clearTimeout(timer);
    timer = null;
    while (queue.length > 0) await flush();
  });

  return Object.freeze({
    record,
    recordIceIssuance,
    recordIceDenied,
    flush,
    /** Tests and hot reload. */
    dispose: () => {
      if (timer) clearTimeout(timer);
      timer = null;
      detach?.();
    },
    get pending() {
      return queue.length;
    },
    ACTIONS: AUDIT_ACTIONS,
  });
};

export default createAuditLog;