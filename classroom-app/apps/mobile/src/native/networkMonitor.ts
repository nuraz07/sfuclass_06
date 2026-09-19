// apps/mobile/src/native/networkMonitor.ts
//
// Keeps a live lesson connected when the phone changes networks. Leaving Wi-Fi for cellular (or joining a
// different Wi-Fi) changes the device's IP address; the existing ICE candidate pair dies silently and media would
// freeze until ICE consent expires (~30 s). This monitor notices the change within a second and asks the core
// client to restart ICE right away, so the call recovers in about the time of one round trip.
//
//   Wi-Fi ↔ cellular, Wi-Fi A → Wi-Fi B, VPN on/off   → restartIce('network-change')
//   offline                                             → no restart; status 'offline' (UI shows reconnecting)
//   back online after offline                           → restartIce('network-restored')
//   app returns to foreground after ≥ 30 s             → restartIce('foreground') if the network identity changed
//                                                         while suspended (iOS delivers no events in background)
//
// Changes are debounced (default 1 s) because a handover emits several events, and restarts are serialised and
// rate-limited (at most one every 3 s). If a change arrives while a restart runs, exactly one more restart follows.
//
// Contract with packages/core-client (IceRecovery.ts):
//   iceRecovery.restartAll({ reason }) → Promise<void>
//     restarts ICE on every open transport (fresh credentials via IceConfigProvider when they are close to expiry,
//     relay-only fallback after repeated failures). The monitor never touches transports itself.
//
// Usage (ClassroomScreen.tsx):
//   useEffect(() => startNetworkMonitor({ iceRecovery, onStatusChange: setNetworkStatus }), [iceRecovery]);
//
// Dependencies: @react-native-community/netinfo (Expo SDK compatible), react-native AppState.
// Owner: F8 Real-Time Connectivity + F5 Multi-Platform.

import NetInfo, { type NetInfoState, type NetInfoSubscription } from '@react-native-community/netinfo';
import { AppState, type AppStateStatus, type NativeEventSubscription } from 'react-native';

export type NetworkStatus = 'online' | 'offline' | 'switching';
export type RestartReason = 'network-change' | 'network-restored' | 'foreground';

export interface IceRecoveryLike {
  restartAll(options: { reason: RestartReason }): Promise<void>;
}

export interface NetworkMonitorLogger {
  info(fields: Record<string, unknown>, message: string): void;
  warn(fields: Record<string, unknown>, message: string): void;
}

export interface NetworkMonitorOptions {
  iceRecovery: IceRecoveryLike;
  onStatusChange?: (status: NetworkStatus, details: { type: string; reason?: RestartReason }) => void;
  debounceMs?: number;
  minRestartIntervalMs?: number;
  foregroundThresholdMs?: number;
  logger?: NetworkMonitorLogger;
  /** Injection points for tests. */
  netInfo?: Pick<typeof NetInfo, 'addEventListener' | 'fetch'>;
  appState?: Pick<typeof AppState, 'addEventListener'>;
  now?: () => number;
}

interface Snapshot {
  connected: boolean;
  identity: string;
  type: string;
}

/**
 * The part of a network state that changes when the device's routable address changes.
 * Wi-Fi exposes the local IP (and BSSID when the location permission is granted); cellular exposes no IP, so a
 * cellular-to-cellular address change is left to ICE consent freshness, which catches it within its timeout.
 */
export function networkIdentity(state: Pick<NetInfoState, 'type' | 'details'>): string {
  const details = (state.details ?? {}) as Record<string, unknown>;
  const ip = typeof details.ipAddress === 'string' ? details.ipAddress : '';
  const bssid = typeof details.bssid === 'string' ? details.bssid : '';
  return `${state.type}|${ip}|${bssid}`;
}

function snapshotOf(state: NetInfoState): Snapshot {
  // isInternetReachable is null while unknown: only an explicit false counts as offline.
  const connected = state.isConnected === true && state.isInternetReachable !== false && state.type !== 'none';
  return { connected, identity: networkIdentity(state), type: state.type };
}

const silentLogger: NetworkMonitorLogger = { info: () => {}, warn: () => {} };

/**
 * Starts monitoring. Returns a function that stops it (suitable as a React effect cleanup).
 */
export function startNetworkMonitor({
  iceRecovery,
  onStatusChange,
  debounceMs = 1_000,
  minRestartIntervalMs = 3_000,
  foregroundThresholdMs = 30_000,
  logger = silentLogger,
  netInfo = NetInfo,
  appState = AppState,
  now = Date.now,
}: NetworkMonitorOptions): () => void {
  let current: Snapshot | null = null;
  let status: NetworkStatus = 'online';
  let debounceTimer: ReturnType<typeof setTimeout> | null = null;
  let pendingReason: RestartReason | null = null;
  let restarting = false;
  let rerunReason: RestartReason | null = null;
  let lastRestartAt = 0;
  let backgroundSince: number | null = null;
  let identityAtBackground: string | null = null;
  let stopped = false;

  const setStatus = (next: NetworkStatus, reason?: RestartReason) => {
    if (next === status) return;
    status = next;
    onStatusChange?.(next, { type: current?.type ?? 'unknown', reason });
  };

  const restart = async (reason: RestartReason): Promise<void> => {
    if (stopped) return;
    if (restarting) {
      rerunReason = reason; // one more restart after the running one, never a queue
      return;
    }
    const wait = lastRestartAt + minRestartIntervalMs - now();
    if (wait > 0) {
      schedule(reason, wait);
      return;
    }
    restarting = true;
    lastRestartAt = now();
    setStatus('switching', reason);
    logger.info({ reason, type: current?.type }, 'restarting ICE after network change');
    try {
      await iceRecovery.restartAll({ reason });
    } catch (err) {
      logger.warn({ reason, error: err instanceof Error ? err.message : String(err) }, 'ICE restart after network change failed');
    } finally {
      restarting = false;
    }
    if (stopped) return;
    if (rerunReason) {
      const next = rerunReason;
      rerunReason = null;
      schedule(next, debounceMs);
      return;
    }
    setStatus(current?.connected === false ? 'offline' : 'online');
  };

  function schedule(reason: RestartReason, delayMs: number) {
    // A restored network outranks a plain change: it is the more informative reason for telemetry.
    pendingReason = pendingReason === 'network-restored' ? pendingReason : reason;
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => {
      debounceTimer = null;
      const next = pendingReason;
      pendingReason = null;
      // Only restart on a usable network; an offline device restarts when it comes back.
      if (next && current?.connected) void restart(next);
    }, delayMs);
  }

  const onNetInfo = (state: NetInfoState) => {
    if (stopped) return;
    const next = snapshotOf(state);
    const previous = current;
    current = next;

    if (!previous) {
      // First event describes the starting network; nothing changed yet.
      setStatus(next.connected ? 'online' : 'offline');
      return;
    }
    if (!next.connected) {
      if (debounceTimer) clearTimeout(debounceTimer);
      debounceTimer = null;
      pendingReason = null;
      setStatus('offline');
      return;
    }
    if (!previous.connected) {
      setStatus('switching', 'network-restored');
      schedule('network-restored', debounceMs);
      return;
    }
    if (previous.identity !== next.identity) {
      setStatus('switching', 'network-change');
      schedule('network-change', debounceMs);
    }
  };

  const onAppState = (state: AppStateStatus) => {
    if (stopped) return;
    if (state === 'background') {
      backgroundSince = now();
      identityAtBackground = current?.identity ?? null;
      return;
    }
    if (state === 'active' && backgroundSince !== null) {
      const away = now() - backgroundSince;
      backgroundSince = null;
      if (away < foregroundThresholdMs) return;
      // Ask for a fresh state: events may have been dropped while suspended.
      netInfo.fetch().then((fresh) => {
        if (stopped) return;
        onNetInfo(fresh);
        if (current?.connected && identityAtBackground !== null && current.identity !== identityAtBackground) {
          schedule('foreground', debounceMs);
        }
      }).catch((err: unknown) => {
        logger.warn({ error: err instanceof Error ? err.message : String(err) }, 'NetInfo.fetch failed on foreground');
      });
    }
  };

  const netInfoSubscription: NetInfoSubscription = netInfo.addEventListener(onNetInfo);
  const appStateSubscription: NativeEventSubscription = appState.addEventListener('change', onAppState);

  return () => {
    stopped = true;
    if (debounceTimer) clearTimeout(debounceTimer);
    netInfoSubscription();
    appStateSubscription.remove();
  };
}