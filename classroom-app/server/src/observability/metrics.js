// classroom-app/server/src/observability/metrics.js
/**
 * Metrics  (F7, F8)  [EXT]
 *
 * Counters, gauges and histograms aggregated in the process and written to
 * stdout as CloudWatch Embedded Metric Format, which the log agent turns into
 * metrics without a scrape endpoint, a sidecar or an open port. The TURN fleet
 * does the same through turn/agent/metricsBridge.js, so a dashboard mixes
 * application and relay series without a second system.
 *
 * Aggregation matters: one EMF line per event would put a log line in front of
 * every ICE restart. Values are summed per dimension set and flushed once a
 * minute, and on shutdown before the pools close.
 *
 * Version 7 adds the media-plane series from section 12:
 *
 *   ice_attempt / ice_success     ICE success rate, alarmed above 2 % failures
 *   ice_candidate_type            direct vs relayed, the relay share baseline
 *   ice_restart, ice_relay_retry  how hard recovery is working
 *   turn_credentials_issued       issuance rate per region and policy
 *   turn_allocations              live allocations, from the TURN registry
 *   sfu_load_score, rooms_live    placement and scale-out signals
 *
 * Dimensions stay low-cardinality on purpose. Region, transport and outcome are
 * dimensions; room ids, user ids and node ids are not — a per-room dimension
 * would create a CloudWatch metric per lesson and a bill to match. Node-level
 * detail belongs in the log line, not in the metric.
 */

import { env } from '../config/env.js';

const FLUSH_INTERVAL_MS = 60_000;
const NAMESPACE = 'Classroom';
/** Dimension values are bounded; anything else is a bug that costs money. */
const MAX_SERIES = 2_000;

const UNITS = Object.freeze({
  Count: 'Count',
  Milliseconds: 'Milliseconds',
  Percent: 'Percent',
  None: 'None',
});

/** Dimensions every series carries. Role and region are enough to route an alarm. */
const baseDimensions = () => ({
  Service: env.SERVICE_NAME,
  Role: env.SERVICE_ROLE,
  Environment: env.NODE_ENV,
});

const seriesKey = (name, dimensions) =>
  `${name}|${Object.entries(dimensions)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([key, value]) => `${key}=${value}`)
    .join(',')}`;

/**
 * @param {object} [options]
 * @param {(line: string) => void} [options.write]  injectable for tests
 * @param {(hook: () => Promise<void>) => () => void} [options.onShutdown]
 */
export const createMetrics = ({
  write = (line) => process.stdout.write(`${line}\n`),
  onShutdown = null,
  flushIntervalMs = FLUSH_INTERVAL_MS,
  enabled = env.METRICS_ENABLED,
  logger = console,
} = {}) => {
  /** @type {Map<string, { name: string, unit: string, dimensions: object, values: number[], sum: number, count: number, gauge: boolean }>} */
  const series = new Map();
  let timer = null;

  const schedule = () => {
    if (timer || !enabled) return;
    timer = setInterval(() => flush(), flushIntervalMs);
    timer.unref?.();
  };

  const upsert = (name, value, { unit = UNITS.Count, gauge = false, ...dimensions }) => {
    if (!enabled) return;
    const merged = { ...baseDimensions(), ...sanitise(dimensions) };
    const key = seriesKey(name, merged);

    let entry = series.get(key);
    if (!entry) {
      if (series.size >= MAX_SERIES) {
        logger.warn?.({ name }, 'metric cardinality ceiling reached; dropping the sample');
        return;
      }
      entry = { name, unit, dimensions: merged, values: [], sum: 0, count: 0, gauge };
      series.set(key, entry);
    }

    if (gauge) {
      entry.values = [value];
      entry.sum = value;
      entry.count = 1;
    } else {
      entry.values.push(value);
      entry.sum += value;
      entry.count += 1;
    }
    schedule();
  };

  /** Dimension values must be short strings; numbers and booleans are stringified. */
  const sanitise = (dimensions) =>
    Object.fromEntries(
      Object.entries(dimensions)
        .filter(([, value]) => value !== undefined && value !== null)
        .map(([key, value]) => [key, String(value).slice(0, 64)]),
    );

  const flush = () => {
    if (series.size === 0) return;
    const now = Date.now();
    const batch = [...series.values()];
    series.clear();

    for (const entry of batch) {
      const line = {
        _aws: {
          Timestamp: now,
          CloudWatchMetrics: [
            {
              Namespace: NAMESPACE,
              Dimensions: [Object.keys(entry.dimensions)],
              Metrics: [{ Name: entry.name, Unit: entry.unit }],
            },
          ],
        },
        ...entry.dimensions,
        [entry.name]: entry.gauge || entry.values.length === 1 ? entry.sum : entry.values,
        release: env.RELEASE_SHA,
      };
      write(JSON.stringify(line));
    }
  };

  // -------------------------------------------------------------------------
  // Primitive API — what the rest of the code calls
  // -------------------------------------------------------------------------

  const increment = (name, dimensions = {}, value = 1) =>
    upsert(name, value, { unit: UNITS.Count, ...dimensions });

  const gauge = (name, value, dimensions = {}) =>
    upsert(name, value, { unit: UNITS.None, gauge: true, ...dimensions });

  const timing = (name, ms, dimensions = {}) =>
    upsert(name, ms, { unit: UNITS.Milliseconds, ...dimensions });

  /** Times a promise and records success and failure separately. */
  const time = async (name, dimensions, work) => {
    const startedAt = Date.now();
    try {
      const result = await work();
      timing(name, Date.now() - startedAt, { ...dimensions, outcome: 'ok' });
      return result;
    } catch (cause) {
      timing(name, Date.now() - startedAt, { ...dimensions, outcome: 'error' });
      throw cause;
    }
  };

  // -------------------------------------------------------------------------
  // Connectivity (F8)
  // -------------------------------------------------------------------------

  /**
   * One per transport that finished ICE, successful or not. The alarm is the
   * ratio over ten minutes per region, so both halves must be recorded even
   * when nothing is wrong.
   *
   * @param {{ region: string, success: boolean, policy: 'all'|'relay', platform?: string }} sample
   */
  const recordIceOutcome = ({ region, success, policy, platform = 'web' }) => {
    increment('ice_attempt', { region, policy, platform });
    increment(success ? 'ice_success' : 'ice_failure', { region, policy, platform });
  };

  /**
   * The selected candidate pair, from rtcStats.ts. `relay` here is the relay
   * share: the alarm fires when it doubles against the seven-day baseline,
   * which usually means the direct UDP path to the SFU broke.
   *
   * @param {{ region: string, local: 'host'|'srflx'|'prflx'|'relay', remote?: string, transport?: 'udp'|'tcp'|'tls' }} sample
   */
  const recordCandidateType = ({ region, local, transport = 'udp' }) =>
    increment('ice_candidate_type', { region, candidateType: local, transport });

  const recordIceRestart = ({ region, reason = 'failed' }) =>
    increment('ice_restart', { region, reason });

  const recordRelayRetry = ({ region }) => increment('ice_relay_retry', { region });

  /**
   * Credential issuance. Counted per region and policy, never per user — the
   * per-user view is the audit log, which is the right place for it.
   */
  const recordTurnIssuance = ({ region, policy, denied = false, reason = null }) =>
    increment(denied ? 'turn_credentials_denied' : 'turn_credentials_issued', {
      region,
      policy,
      ...(denied ? { reason } : {}),
    });

  /** Published from the TURN registry by the pool selector, once per scrape. */
  const recordTurnPool = ({ region, allocations, relayedMbps, nodes }) => {
    gauge('turn_allocations', allocations, { region });
    gauge('turn_relayed_mbps', relayedMbps, { region });
    gauge('turn_nodes_healthy', nodes, { region });
  };

  // -------------------------------------------------------------------------
  // Classroom and media plane (F1)
  // -------------------------------------------------------------------------

  const recordRoomsLive = ({ region, rooms, peers }) => {
    gauge('rooms_live', rooms, { region });
    gauge('peers_live', peers, { region });
  };

  /** From loadReporter.js; the scale-out and placement signal. */
  const recordSfuLoad = ({ region, loadScore, producers, consumers, egressMbps }) => {
    gauge('sfu_load_score', loadScore, { region });
    gauge('sfu_producers', producers, { region });
    gauge('sfu_consumers', consumers, { region });
    gauge('sfu_egress_mbps', egressMbps, { region });
  };

  const detach = onShutdown?.(async () => {
    if (timer) clearInterval(timer);
    timer = null;
    flush();
  });

  return Object.freeze({
    increment,
    gauge,
    timing,
    time,
    flush,
    recordIceOutcome,
    recordCandidateType,
    recordIceRestart,
    recordRelayRetry,
    recordTurnIssuance,
    recordTurnPool,
    recordRoomsLive,
    recordSfuLoad,
    dispose: () => {
      if (timer) clearInterval(timer);
      timer = null;
      detach?.();
    },
    UNITS,
  });
};

export default createMetrics;