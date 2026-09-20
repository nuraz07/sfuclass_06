// classroom-app/packages/core-client/src/rtc/SfuClient.ts
/**
 * SFU client  (F1, F8)  [EXT]
 *
 * Owns one live session: the signalling socket to the realtime service, the
 * two mediasoup transports, every producer this peer publishes and every
 * consumer it subscribes to. It is the only place in the client that knows
 * mediasoup exists.
 *
 * The decisions everything else follows from:
 *
 *   1. Clients never address an SFU node (architecture v7, Appendix A #6).
 *      The socket goes to the realtime service; `classroom:join` returns the
 *      placement result as data: router capabilities, both transports and the
 *      ICE configuration. There is no node resolver and no per-node URL.
 *
 *   2. Every transport is created with the `iceServers` and
 *      `iceTransportPolicy` from the server. ICE evaluates direct UDP, direct
 *      TCP and TURN over UDP / TCP / TLS 443 in parallel; there is no
 *      sequential fallback in application code. A 'relay' policy — tenant
 *      policy or a forced relay retry — is never weakened here.
 *
 *   3. A screen share is a second producer on this same peer, tagged
 *      `source: 'screen'`. Not a second connection, not a second client
 *      instance. It inherits whatever ICE path the send transport uses.
 *
 *   4. This class holds no UI state and no framework types. It emits events;
 *      state/useClassroom.ts turns those into whatever React needs. That is
 *      what lets apps/mobile reuse it unchanged.
 *
 *   5. ICE policy lives outside this file. IceConfigProvider (credential
 *      refresh at 80 % of the TTL) and IceRecovery (restartIce → relay-only
 *      retry → rejoin) attach as plugins and drive the primitives below:
 *      applyIceConfig(), restartIce(), recreateTransports(), rejoinMedia().
 *      Without an IceRecovery plugin a bounded built-in fallback runs, so a
 *      bare client (tests, early boot) still recovers from a failed transport.
 *
 * Local tracks belong to the caller. Producers are created with
 * `stopTracks: false`, so transports can be rebuilt and the same camera and
 * microphone tracks republished without asking for devices again. Tracks are
 * stopped only when the session ends (leave, room closed, fatal error).
 *
 * Nothing here logs ICE candidates or addresses: they are personal data
 * (piiRedaction.js) and rtcStats.ts reports candidate types, not IPs.
 */

import type { types as MediasoupTypes } from 'mediasoup-client';
import { ApiError, SignalingEvents, type SocketAck } from '@classroom/contracts';
import type { DeviceAdapter, MediaStreamTrackLike } from './DeviceAdapter.js';
import { CAMERA_ENCODINGS, SCREEN_ENCODINGS } from './DeviceAdapter.js';
import type { ScreenShareAdapter, ScreenShareHandle } from './ScreenShareAdapter.js';

const { SIGNALING_CLIENT_EVENTS: CLIENT, SIGNALING_SERVER_EVENTS: SERVER } = SignalingEvents;

type IceConfig = SignalingEvents.IceConfig;
type IceTransportPolicy = SignalingEvents.IceTransportPolicy;
type RegionHint = SignalingEvents.RegionHint;
type TransportOptions = SignalingEvents.TransportOptions;
type ProducerInfo = SignalingEvents.ProducerInfo;

export type TransportDirection = SignalingEvents.TransportDirection;
export type TransportConnectionState = MediasoupTypes.ConnectionState;

/** Steps of the built-in fallback: restartIce, relay-only transports, media rejoin. */
const FALLBACK_RECOVERY_STEPS = 3;

/**
 * In development the realtime service is proxied by Vite, so a localhost URL
 * is rewritten to the page origin. Production URLs pass through untouched.
 */
const signalingUrlForBrowser = (url: string): string => {
  if (typeof globalThis.location === 'undefined' || !url) return url;

  try {
    const parsed = new URL(url, globalThis.location.origin);
    if (parsed.hostname === 'localhost' || parsed.hostname === '127.0.0.1') {
      return globalThis.location.origin;
    }
  } catch {
    return url;
  }

  return url;
};

const isLiveTrack = (track: unknown): boolean =>
  Boolean(track) && (track as { readyState?: string }).readyState !== 'ended';

// ---------------------------------------------------------------------------
// Transport seam
// ---------------------------------------------------------------------------

/**
 * The minimum this class needs from a socket. socket/socketClient.ts implements
 * it over Socket.IO; tests implement it with a stub. Keeping the dependency
 * structural means this file never imports socket.io-client, and neither does a
 * consumer that only wants the types.
 */
export interface SignalingTransport {
  emitWithAck<TResponse = unknown>(event: string, payload: unknown): Promise<SocketAck<TResponse>>;
  on(event: string, listener: (payload: never) => void): void;
  off(event: string, listener?: (payload: never) => void): void;
  connect(url: string, auth: Record<string, unknown>): Promise<void>;
  disconnect(): void;
  readonly connected: boolean;
}

export type SignalingTransportFactory = () => SignalingTransport;

// ---------------------------------------------------------------------------
// Public shapes
// ---------------------------------------------------------------------------

/**
 * 'resolving'    access token and region hint are being gathered
 * 'connecting'   socket to the realtime service, then the join
 * 'joined'       signalling is up; media state is in transportStateChanged
 * 'reconnecting' media is being rebuilt (ICE restart excluded: that is silent)
 */
export type SfuConnectionState =
  | 'idle'
  | 'resolving'
  | 'connecting'
  | 'joined'
  | 'reconnecting'
  | 'closed';

export interface RemoteStream {
  consumerId: string;
  producerId: string;
  peerId: string;
  userId: string;
  kind: 'audio' | 'video';
  source: SignalingEvents.MediaSource;
  track: MediaStreamTrackLike;
  paused: boolean;
}

export interface LocalProducers {
  camera: MediasoupTypes.Producer | null;
  microphone: MediasoupTypes.Producer | null;
  screen: MediasoupTypes.Producer | null;
  screenAudio: MediasoupTypes.Producer | null;
}

export interface SfuClientEvents {
  stateChanged: (state: SfuConnectionState) => void;
  roomState: (state: SignalingEvents.RoomState) => void;
  peerJoined: (peer: SignalingEvents.Peer) => void;
  peerLeft: (event: { peerId: string; reason: string }) => void;
  peerUpdated: (peer: SignalingEvents.Peer) => void;
  streamAdded: (stream: RemoteStream) => void;
  streamRemoved: (event: { consumerId: string; producerId: string }) => void;
  screenShareStarted: (event: SignalingEvents.ScreenShareStarted) => void;
  screenShareStopped: (event: SignalingEvents.ScreenShareStopped) => void;
  /** The local share ended, including via the browser's own stop bar. */
  localScreenShareEnded: (reason: string) => void;
  handRaised: (event: { peerId: string; raised: boolean }) => void;
  reaction: (event: { peerId: string; emoji: string }) => void;
  recordingChanged: (event: { recording: boolean }) => void;
  /** A new ICE configuration is in effect (join, refresh, push, recreate). */
  iceConfigChanged: (ice: Readonly<IceConfig>) => void;
  /** Raw mediasoup transport state; IceRecovery and useConnectionQuality listen. */
  transportStateChanged: (event: {
    direction: TransportDirection;
    state: TransportConnectionState;
    iceTransportPolicy: IceTransportPolicy;
  }) => void;
  /** The server announced that the room's node is draining. */
  nodeDraining: (event: SignalingEvents.NodeDraining) => void;
  error: (error: ApiError) => void;
  closed: (reason: string) => void;
}

type Listener = (...args: never[]) => void;

/**
 * Extension point for IceConfigProvider, IceRecovery and rtcStats. attach()
 * runs once in the constructor and returns its own detach function.
 */
export interface SfuClientPlugin {
  readonly name: string;
  /** Set by IceRecovery. Disables the built-in fallback recovery. */
  readonly handlesIceRecovery?: boolean;
  attach(client: SfuClient): () => void;
}

export interface SfuClientOptions {
  deviceAdapter: DeviceAdapter;
  screenShareAdapter: ScreenShareAdapter;
  createTransport: SignalingTransportFactory;
  /**
   * The realtime service's WebSocket URL (PUBLIC_WS_URL). This is never an
   * SFU node: placement happens on the server and arrives in the join ack.
   */
  signalingUrl: string;
  /** Supplies the current access token for the socket handshake. */
  getAccessToken(): string | null | Promise<string | null>;
  /** Region hint from ConnectivityProbe. Failures are ignored; it is advisory. */
  getRegionHint?(): RegionHint | null | Promise<RegionHint | null>;
  plugins?: readonly SfuClientPlugin[];
  logger?: { debug(...args: unknown[]): void; warn(...args: unknown[]): void };
  /** Attempts before a drained-node media rejoin is given up on. */
  rejoinAttempts?: number;
}

interface LocalMediaSnapshot {
  camera: { track: MediaStreamTrackLike; paused: boolean } | null;
  microphone: { track: MediaStreamTrackLike; paused: boolean } | null;
  wasSharing: boolean;
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

export class SfuClient {
  private readonly options: SfuClientOptions;
  private readonly listeners = new Map<keyof SfuClientEvents, Set<Listener>>();
  private readonly detachPlugins: Array<() => void> = [];
  private readonly builtInRecovery: boolean;

  private socket: SignalingTransport | null = null;
  private device: MediasoupTypes.Device | null = null;
  private sendTransport: MediasoupTypes.Transport | null = null;
  private recvTransport: MediasoupTypes.Transport | null = null;

  private readonly consumers = new Map<string, MediasoupTypes.Consumer>();
  /** Producer ids that are consumed or being consumed; prevents double consumes. */
  private readonly consuming = new Set<string>();
  /** Every remote producer in the room, so media can be re-consumed after a rebuild. */
  private readonly remoteProducers = new Map<string, ProducerInfo>();
  private readonly producers: LocalProducers = {
    camera: null,
    microphone: null,
    screen: null,
    screenAudio: null,
  };

  private screenHandle: ScreenShareHandle | null = null;
  private stopScreenListener: (() => void) | null = null;

  private roomId: string | null = null;
  private peerId: string | null = null;
  private region: string | null = null;
  private regionHint: RegionHint | null = null;
  private state: SfuConnectionState = 'idle';

  private ice: IceConfig | null = null;
  /** Set by a relay-only retry; lasts for the rest of the session. */
  private relayForced = false;
  /** The policy the current transports were built with. */
  private transportPolicy: IceTransportPolicy = 'all';

  /** Local media captured before a rebuild; survives a failed attempt. */
  private pendingLocalMedia: LocalMediaSnapshot | null = null;
  /** Rebuilds run one at a time, in order. */
  private recoveryChain: Promise<void> = Promise.resolve();
  private fallbackInFlight = false;
  /** Consecutive failures without a transport reaching 'connected'. */
  private consecutiveFailures = 0;

  constructor(options: SfuClientOptions) {
    this.options = options;
    const plugins = options.plugins ?? [];
    this.builtInRecovery = !plugins.some((plugin) => plugin.handlesIceRecovery);
    for (const plugin of plugins) {
      this.detachPlugins.push(plugin.attach(this));
    }
  }

  // -------------------------------------------------------------------------
  // Events
  // -------------------------------------------------------------------------

  on<K extends keyof SfuClientEvents>(event: K, listener: SfuClientEvents[K]): () => void {
    const set = this.listeners.get(event) ?? new Set<Listener>();
    set.add(listener as Listener);
    this.listeners.set(event, set);
    return () => set.delete(listener as Listener);
  }

  private emit<K extends keyof SfuClientEvents>(
    event: K,
    ...args: Parameters<SfuClientEvents[K]>
  ): void {
    for (const listener of this.listeners.get(event) ?? []) {
      try {
        (listener as (...a: unknown[]) => void)(...args);
      } catch (cause) {
        this.options.logger?.warn('listener threw', event, cause);
      }
    }
  }

  private setState(next: SfuConnectionState): void {
    if (this.state === next) return;
    this.state = next;
    this.emit('stateChanged', next);
  }

  // -------------------------------------------------------------------------
  // Read-only view
  // -------------------------------------------------------------------------

  get connectionState(): SfuConnectionState {
    return this.state;
  }

  get localProducers(): Readonly<LocalProducers> {
    return this.producers;
  }

  get isScreenSharing(): boolean {
    return this.producers.screen !== null;
  }

  get currentRoomId(): string | null {
    return this.roomId;
  }

  get mediaRegion(): string | null {
    return this.region;
  }

  get iceConfig(): Readonly<IceConfig> | null {
    return this.ice;
  }

  get iceTransportPolicy(): IceTransportPolicy {
    return this.transportPolicy;
  }

  get isRelayForced(): boolean {
    return this.relayForced;
  }

  // -------------------------------------------------------------------------
  // Join and leave
  // -------------------------------------------------------------------------

  async join(roomId: string): Promise<SignalingEvents.RoomState> {
    if (this.state !== 'idle' && this.state !== 'closed') {
      throw new ApiError('internal_error', { detail: 'This client is already in a session' });
    }

    this.roomId = roomId;
    this.relayForced = false;
    this.consecutiveFailures = 0;
    this.setState('resolving');

    try {
      const [token, regionHint] = await Promise.all([
        this.options.getAccessToken(),
        this.resolveRegionHint(),
      ]);
      this.regionHint = regionHint;

      this.setState('connecting');
      await this.openSocket(token);

      const room = await this.joinMedia(false);
      this.setState('joined');
      return room;
    } catch (cause) {
      const error = this.toApiError(cause, 'Could not join the room');
      this.teardown('error');
      this.emit('error', error);
      throw error;
    }
  }

  async leave(): Promise<void> {
    if (this.state === 'closed' || this.state === 'idle') return;
    try {
      await this.request(CLIENT.leave, {});
    } catch {
      // Leaving a room that already ended is not an error worth surfacing.
    }
    this.teardown('left');
  }

  /** Leaves if needed and detaches every plugin. The instance is done after this. */
  async dispose(): Promise<void> {
    await this.leave();
    for (const detach of this.detachPlugins.splice(0)) {
      try {
        detach();
      } catch (cause) {
        this.options.logger?.warn('plugin detach threw', cause);
      }
    }
    this.listeners.clear();
  }

  private async resolveRegionHint(): Promise<RegionHint | null> {
    if (!this.options.getRegionHint) return null;
    try {
      return (await this.options.getRegionHint()) ?? null;
    } catch (cause) {
      this.options.logger?.debug('region hint unavailable', cause);
      return null;
    }
  }

  private async openSocket(token: string | null): Promise<void> {
    if (this.socket?.connected) return;
    const socket = this.options.createTransport();
    this.socket = socket;
    this.bindServerEvents(socket);
    await socket.connect(signalingUrlForBrowser(this.options.signalingUrl), { token });
  }

  /**
   * Sends `classroom:join` and builds media from the acknowledgement. Used for
   * the first join and, with `rejoin`, for rebuilding media on the same socket.
   */
  private async joinMedia(rejoin: boolean): Promise<SignalingEvents.RoomState> {
    const roomId = this.requireRoomId();

    const ack = await this.request<SignalingEvents.JoinAck>(CLIENT.join, {
      roomId,
      rejoin,
      ...(this.regionHint ? { regionHint: this.regionHint } : {}),
      device: {
        platform: this.options.deviceAdapter.platform,
        supportsScreenShare: this.options.screenShareAdapter.isSupported(),
      },
    } satisfies SignalingEvents.SignalingClientPayloads['classroom:join']);

    const device = this.device ?? this.options.deviceAdapter.createMediasoupDevice();
    this.device = device;
    if (!device.loaded) {
      await device.load({
        routerRtpCapabilities:
          ack.room.routerRtpCapabilities as unknown as MediasoupTypes.RtpCapabilities,
      });
    }

    this.peerId = ack.room.selfPeerId;
    this.region = ack.room.mediaRegion;
    this.setIce(ack.ice);

    this.sendTransport = this.buildTransport('send', ack.sendTransport, ack.ice);
    this.recvTransport = this.buildTransport('recv', ack.recvTransport, ack.ice);

    this.rememberRoomProducers(ack.room);
    this.emit('roomState', ack.room);

    // A late joiner has to see an ongoing share, not just future ones.
    if (ack.room.screenShare) {
      this.emit('screenShareStarted', ack.room.screenShare);
    }

    // A late joiner also has to receive media that was already flowing.
    void this.consumeKnownProducers();

    return ack.room;
  }

  // -------------------------------------------------------------------------
  // Publishing
  // -------------------------------------------------------------------------

  async publishCamera(track: MediaStreamTrackLike): Promise<MediasoupTypes.Producer> {
    const existing = this.producers.camera;
    if (existing && !existing.closed) {
      await existing.replaceTrack({ track: track as unknown as MediaStreamTrack });
      return existing;
    }

    const sendTransport = this.requireSendTransport();
    const producer = await sendTransport.produce({
      track: track as unknown as MediaStreamTrack,
      encodings: this.options.deviceAdapter.capabilities.supportsSimulcast
        ? CAMERA_ENCODINGS
        : undefined,
      codecOptions: { videoGoogleStartBitrate: 300 },
      stopTracks: false,
      appData: { source: 'camera' satisfies SignalingEvents.MediaSource },
    });
    this.holdProducer('camera', producer);
    return producer;
  }

  async publishMicrophone(track: MediaStreamTrackLike): Promise<MediasoupTypes.Producer> {
    const existing = this.producers.microphone;
    if (existing && !existing.closed) {
      await existing.replaceTrack({ track: track as unknown as MediaStreamTrack });
      return existing;
    }

    const sendTransport = this.requireSendTransport();
    const producer = await sendTransport.produce({
      track: track as unknown as MediaStreamTrack,
      codecOptions: { opusDtx: true, opusFec: true },
      stopTracks: false,
      appData: { source: 'microphone' satisfies SignalingEvents.MediaSource },
    });
    this.holdProducer('microphone', producer);
    return producer;
  }

  /** Pausing keeps the producer alive, so unmuting does not renegotiate. */
  async setCameraEnabled(enabled: boolean): Promise<void> {
    await this.setProducerEnabled(this.producers.camera, enabled);
  }

  async setMicrophoneEnabled(enabled: boolean): Promise<void> {
    await this.setProducerEnabled(this.producers.microphone, enabled);
  }

  private async setProducerEnabled(
    producer: MediasoupTypes.Producer | null,
    enabled: boolean,
  ): Promise<void> {
    if (!producer || producer.closed) return;
    if (enabled) {
      producer.resume();
      await this.request(CLIENT.resumeProducer, { producerId: producer.id });
    } else {
      producer.pause();
      await this.request(CLIENT.pauseProducer, { producerId: producer.id });
    }
  }

  private holdProducer(key: keyof LocalProducers, producer: MediasoupTypes.Producer): void {
    this.producers[key] = producer;
    producer.on('transportclose', () => {
      if (this.producers[key] === producer) this.producers[key] = null;
    });
  }

  // -------------------------------------------------------------------------
  // Screen sharing
  // -------------------------------------------------------------------------

  /**
   * Asks for the presenter lock, opens the platform picker, then publishes the
   * capture as a second producer.
   *
   * Order matters: the lock is requested first, so a user who is going to be
   * refused never sees a picker. The lock is released again if the capture
   * fails or is cancelled — otherwise a dismissed dialog would block the room's
   * share for everyone.
   */
  async startScreenShare(options: { withAudio?: boolean } = {}): Promise<void> {
    if (!this.options.screenShareAdapter.isSupported()) {
      throw new ApiError('not_implemented', {
        detail: 'This device cannot share its screen.',
      });
    }
    if (this.producers.screen) return;

    await this.request(CLIENT.startScreenShare, {
      withAudio: options.withAudio ?? false,
    });

    let handle: ScreenShareHandle;
    try {
      handle = await this.options.screenShareAdapter.start({
        withAudio: options.withAudio,
      });
    } catch (cause) {
      // Give the lock back before rethrowing; a cancelled picker must not leave
      // the room unable to share.
      await this.request(CLIENT.stopScreenShare, {}).catch(() => undefined);
      throw cause;
    }

    this.screenHandle = handle;

    try {
      const sendTransport = this.requireSendTransport();
      const producer = await sendTransport.produce({
        track: handle.videoTrack as unknown as MediaStreamTrack,
        // One layer, not simulcast: the bitrate belongs to detail, not to
        // resolution variants nobody will subscribe to.
        encodings: SCREEN_ENCODINGS,
        codecOptions: { videoGoogleStartBitrate: 1_000 },
        // The capture belongs to the handle; handle.stop() ends it.
        stopTracks: false,
        appData: {
          source: 'screen' satisfies SignalingEvents.MediaSource,
          label: handle.label,
        },
      });
      this.holdProducer('screen', producer);

      if (handle.audioTrack) {
        const audioProducer = await sendTransport.produce({
          track: handle.audioTrack as unknown as MediaStreamTrack,
          stopTracks: false,
          appData: { source: 'screen-audio' satisfies SignalingEvents.MediaSource },
        });
        this.holdProducer('screenAudio', audioProducer);
      }

      // The browser's own stop bar ends the track without going through us.
      this.stopScreenListener = handle.onEnded((reason) => {
        void this.stopScreenShare(reason);
      });
    } catch (cause) {
      this.producers.screen?.close();
      this.producers.screen = null;
      handle.stop();
      this.screenHandle = null;
      await this.request(CLIENT.stopScreenShare, {}).catch(() => undefined);
      throw cause;
    }
  }

  async stopScreenShare(reason = 'user'): Promise<void> {
    const handle = this.screenHandle;
    const producer = this.producers.screen;

    this.stopScreenListener?.();
    this.stopScreenListener = null;

    producer?.close();
    this.producers.screenAudio?.close();
    this.producers.screen = null;
    this.producers.screenAudio = null;

    handle?.stop();
    this.screenHandle = null;

    if (producer) {
      await this.request(CLIENT.closeProducer, { producerId: producer.id }).catch(() => undefined);
    }
    await this.request(CLIENT.stopScreenShare, {}).catch(() => undefined);

    this.emit('localScreenShareEnded', reason);
  }

  // -------------------------------------------------------------------------
  // In-session actions
  // -------------------------------------------------------------------------

  async raiseHand(raised: boolean): Promise<void> {
    await this.request(CLIENT.raiseHand, { raised });
  }

  async react(emoji: string): Promise<void> {
    await this.request(CLIENT.react, { emoji });
  }

  async hostAction(
    payload: SignalingEvents.SignalingClientPayloads['classroom:host.action'],
  ): Promise<void> {
    await this.request(CLIENT.hostAction, payload);
  }

  // -------------------------------------------------------------------------
  // ICE primitives — driven by IceConfigProvider and IceRecovery
  // -------------------------------------------------------------------------

  /**
   * Applies a fresh ICE configuration. Servers and credentials are swapped in
   * place with updateIceServers(); existing allocations keep working and new
   * ones use the new credential. A policy cannot be changed on a live
   * transport, so a tightening to 'relay' rebuilds the transports; a
   * loosening is ignored until the next rebuild.
   */
  async applyIceConfig(ice: IceConfig): Promise<void> {
    const tightened = this.effectivePolicy(ice) === 'relay' && this.transportPolicy !== 'relay';
    this.setIce(ice);

    if (tightened && (this.sendTransport || this.recvTransport)) {
      await this.recreateTransports();
      return;
    }

    const iceServers = ice.iceServers as unknown as RTCIceServer[];
    await Promise.all(
      [this.sendTransport, this.recvTransport]
        .filter((transport): transport is MediasoupTypes.Transport =>
          Boolean(transport && !transport.closed),
        )
        .map((transport) => transport.updateIceServers({ iceServers })),
    );
  }

  /**
   * ICE restart for one transport: the owning node issues new ICE parameters,
   * the client restarts ICE against them. Media keeps its producers and
   * consumers; nothing is renegotiated.
   */
  async restartIce(direction: TransportDirection): Promise<void> {
    const transport = direction === 'send' ? this.sendTransport : this.recvTransport;
    if (!transport || transport.closed) {
      throw new ApiError('dependency_unavailable', {
        detail: `No ${direction} transport to restart`,
      });
    }

    const { iceParameters } = await this.request<SignalingEvents.IceRestarted>(
      CLIENT.restartIce,
      { transportId: transport.id },
    );
    await transport.restartIce({
      iceParameters: iceParameters as unknown as MediasoupTypes.IceParameters,
    });
  }

  /**
   * Replaces both transports on the same node and republishes local media.
   * With `forceRelay` the new transports, and every later one in this session,
   * use iceTransportPolicy 'relay'.
   */
  async recreateTransports(options: { forceRelay?: boolean } = {}): Promise<void> {
    await this.runRecovery(async () => {
      if (options.forceRelay) this.relayForced = true;

      this.pendingLocalMedia ??= this.captureLocalMedia();
      this.closeMedia({ stopLocalTracks: false });

      const [send, recv] = await Promise.all([
        this.request<SignalingEvents.CreateTransportAck>(CLIENT.createTransport, {
          direction: 'send',
          forceRelay: this.relayForced,
        }),
        this.request<SignalingEvents.CreateTransportAck>(CLIENT.createTransport, {
          direction: 'recv',
          forceRelay: this.relayForced,
        }),
      ]);

      this.setIce(recv.ice);
      this.sendTransport = this.buildTransport('send', send.transport, send.ice);
      this.recvTransport = this.buildTransport('recv', recv.transport, recv.ice);

      await this.restoreLocalMedia();
      await this.consumeKnownProducers();
    });
  }

  /**
   * Rebuilds media through a fresh placement on the same signalling socket.
   * Used when the node is draining or when the node itself is gone. Other
   * participants see a short media gap, not a leave and a join.
   */
  async rejoinMedia(): Promise<void> {
    await this.runRecovery(async () => {
      this.pendingLocalMedia ??= this.captureLocalMedia();
      this.closeMedia({ stopLocalTracks: false });
      await this.joinMedia(true);
      await this.restoreLocalMedia();
    });
  }

  private async runRecovery(task: () => Promise<void>): Promise<void> {
    const run = async (): Promise<void> => {
      if (this.state === 'idle' || this.state === 'closed') {
        throw new ApiError('dependency_unavailable', { detail: 'The session is not active' });
      }
      this.setState('reconnecting');
      await task();
      if (this.state === 'reconnecting') this.setState('joined');
    };

    const next = this.recoveryChain.then(run, run);
    this.recoveryChain = next.catch(() => undefined);
    return next;
  }

  private effectivePolicy(ice: IceConfig): IceTransportPolicy {
    return this.relayForced || ice.iceTransportPolicy === 'relay' ? 'relay' : 'all';
  }

  private setIce(ice: IceConfig): void {
    this.ice = ice;
    this.emit('iceConfigChanged', ice);
  }

  // -------------------------------------------------------------------------
  // Transports
  // -------------------------------------------------------------------------

  private buildTransport(
    direction: TransportDirection,
    params: TransportOptions,
    ice: IceConfig,
  ): MediasoupTypes.Transport {
    const device = this.requireDevice();
    const iceTransportPolicy = this.effectivePolicy(ice);

    const options: MediasoupTypes.TransportOptions = {
      // The wire name is transportId; mediasoup-client wants id.
      id: params.transportId,
      iceParameters: params.iceParameters as unknown as MediasoupTypes.IceParameters,
      iceCandidates: params.iceCandidates as unknown as MediasoupTypes.IceCandidate[],
      dtlsParameters: params.dtlsParameters as unknown as MediasoupTypes.DtlsParameters,
      iceServers: ice.iceServers as unknown as RTCIceServer[],
      iceTransportPolicy,
      appData: { direction },
    };

    const transport =
      direction === 'send' ? device.createSendTransport(options) : device.createRecvTransport(options);

    this.transportPolicy = iceTransportPolicy;
    this.wireTransport(transport, direction, iceTransportPolicy);
    return transport;
  }

  private wireTransport(
    transport: MediasoupTypes.Transport,
    direction: TransportDirection,
    iceTransportPolicy: IceTransportPolicy,
  ): void {
    transport.on('connect', ({ dtlsParameters }, callback, errback) => {
      this.request(CLIENT.connectTransport, { transportId: transport.id, dtlsParameters })
        .then(() => callback())
        .catch((cause: Error) => errback(cause));
    });

    if (direction === 'send') {
      transport.on('produce', ({ kind, rtpParameters, appData }, callback, errback) => {
        const source = (appData as { source?: SignalingEvents.MediaSource }).source ?? 'camera';
        this.request<SignalingEvents.Produced>(CLIENT.produce, {
          transportId: transport.id,
          kind,
          rtpParameters: rtpParameters as unknown as Record<string, unknown>,
          source,
          appData: source === 'screen' ? { contentHint: 'detail' } : {},
        })
          .then(({ producerId }) => callback({ id: producerId }))
          .catch((cause: Error) => errback(cause));
      });
    }

    transport.on('connectionstatechange', (state) => {
      this.options.logger?.debug('transport', direction, state);
      this.emit('transportStateChanged', { direction, state, iceTransportPolicy });

      if (state === 'connected') {
        // A path works again; earlier failures were transient.
        this.consecutiveFailures = 0;
        return;
      }

      if (state === 'failed' && this.builtInRecovery && this.state === 'joined') {
        void this.fallbackRecover(direction);
      }
    });
  }

  /**
   * Bounded recovery used only when no IceRecovery plugin is attached:
   * restartIce, then relay-only transports, then a media rejoin. Bounded,
   * because an endless rebuild loop looks to everyone else like a person being
   * thrown out repeatedly and hides the real cause. After the last step the
   * signalling socket stays up, so chat, hand raise and the peer list keep
   * working without media.
   */
  private async fallbackRecover(direction: TransportDirection): Promise<void> {
    if (this.fallbackInFlight) return;
    this.fallbackInFlight = true;

    try {
      while (this.consecutiveFailures < FALLBACK_RECOVERY_STEPS) {
        this.consecutiveFailures += 1;
        try {
          if (this.consecutiveFailures === 1) {
            await this.restartIce(direction);
          } else if (this.consecutiveFailures === 2) {
            await this.recreateTransports({ forceRelay: true });
          } else {
            await this.rejoinMedia();
          }
          return;
        } catch (cause) {
          this.options.logger?.warn('media recovery step failed', this.consecutiveFailures, cause);
        }
      }

      this.emitError(
        new ApiError('sfu_unavailable', {
          detail:
            'Could not establish a media connection. Audio and video are unavailable; ' +
            'the rest of the lesson still works.',
        }),
      );
      if (this.state === 'reconnecting') this.setState('joined');
    } finally {
      this.fallbackInFlight = false;
    }
  }

  private requireSendTransport(): MediasoupTypes.Transport {
    if (!this.sendTransport || this.sendTransport.closed) {
      throw new ApiError('dependency_unavailable', { detail: 'Not joined: no send transport' });
    }
    return this.sendTransport;
  }

  private requireDevice(): MediasoupTypes.Device {
    if (!this.device?.loaded) throw new Error('join() must run first');
    return this.device;
  }

  private requireRoomId(): string {
    if (!this.roomId) throw new Error('join() must run first');
    return this.roomId;
  }

  // -------------------------------------------------------------------------
  // Consuming
  // -------------------------------------------------------------------------

  private rememberRoomProducers(room: SignalingEvents.RoomState): void {
    this.remoteProducers.clear();
    for (const peer of room.peers) {
      if (peer.peerId === room.selfPeerId) continue;
      for (const producer of peer.producers) {
        this.remoteProducers.set(producer.producerId, producer);
      }
    }
  }

  private async consumeKnownProducers(): Promise<void> {
    await Promise.all(
      [...this.remoteProducers.values()].map((producer) =>
        this.consume(producer).catch((cause) => this.emitError(cause)),
      ),
    );
  }

  private async consume(producer: ProducerInfo): Promise<void> {
    if (producer.peerId === this.peerId) return;
    if (this.consuming.has(producer.producerId)) return;

    const device = this.device;
    const recvTransport = this.recvTransport;
    // Not ready yet: consumeKnownProducers() picks it up once transports exist.
    if (!device?.loaded || !recvTransport || recvTransport.closed) return;

    this.consuming.add(producer.producerId);
    try {
      const info = await this.request<SignalingEvents.ConsumerCreated>(CLIENT.consume, {
        transportId: recvTransport.id,
        producerId: producer.producerId,
        rtpCapabilities: device.rtpCapabilities as unknown as Record<string, unknown>,
      });

      const consumer = await recvTransport.consume({
        id: info.consumerId,
        producerId: info.producerId,
        kind: info.kind,
        rtpParameters: info.rtpParameters as unknown as MediasoupTypes.RtpParameters,
      });

      this.consumers.set(consumer.id, consumer);

      // The server creates consumers paused so the client can attach the track
      // before any media flows; resuming here avoids the first frames being lost.
      await this.request(CLIENT.resumeConsumer, { consumerId: consumer.id });

      this.emit('streamAdded', {
        consumerId: consumer.id,
        producerId: info.producerId,
        peerId: producer.peerId,
        userId: producer.userId,
        kind: info.kind,
        source: info.source,
        track: consumer.track as unknown as MediaStreamTrackLike,
        paused: info.producerPaused,
      });
    } catch (cause) {
      this.consuming.delete(producer.producerId);
      throw cause;
    }
  }

  private closeConsumersOf(producerId: string): void {
    this.consuming.delete(producerId);
    for (const [consumerId, consumer] of this.consumers) {
      if (consumer.producerId !== producerId) continue;
      consumer.close();
      this.consumers.delete(consumerId);
      this.emit('streamRemoved', { consumerId, producerId });
    }
  }

  // -------------------------------------------------------------------------
  // Server events
  // -------------------------------------------------------------------------

  private bindServerEvents(socket: SignalingTransport): void {
    socket.on(SERVER.peerJoined, (peer: SignalingEvents.Peer) => this.emit('peerJoined', peer));

    socket.on(SERVER.peerLeft, (event: SignalingEvents.PeerLeft) => {
      for (const [producerId, producer] of this.remoteProducers) {
        if (producer.peerId === event.peerId) this.remoteProducers.delete(producerId);
      }
      this.emit('peerLeft', event);
    });

    socket.on(SERVER.peerUpdated, (peer: SignalingEvents.Peer) => this.emit('peerUpdated', peer));

    socket.on(SERVER.newProducer, (producer: ProducerInfo) => {
      if (producer.peerId === this.peerId) return;
      this.remoteProducers.set(producer.producerId, producer);
      void this.consume(producer).catch((cause) => this.emitError(cause));
    });

    socket.on(SERVER.producerClosed, ({ producerId }: { producerId: string }) => {
      this.remoteProducers.delete(producerId);
      this.closeConsumersOf(producerId);
    });

    socket.on(SERVER.screenShareStarted, (event: SignalingEvents.ScreenShareStarted) =>
      this.emit('screenShareStarted', event),
    );
    socket.on(SERVER.screenShareStopped, (event: SignalingEvents.ScreenShareStopped) =>
      this.emit('screenShareStopped', event),
    );

    socket.on(SERVER.handRaised, (event: { peerId: string; raised: boolean }) =>
      this.emit('handRaised', event),
    );
    socket.on(SERVER.reaction, (event: { peerId: string; emoji: string }) =>
      this.emit('reaction', event),
    );
    socket.on(SERVER.recordingChanged, (event: { recording: boolean }) =>
      this.emit('recordingChanged', event),
    );

    // TURN node drained, secret rotation or tenant policy change.
    socket.on(SERVER.iceUpdate, (event: SignalingEvents.IceUpdate) => {
      void this.applyIceConfig(event.ice).catch((cause) => this.emitError(cause));
    });

    socket.on(SERVER.roomClosed, (event: SignalingEvents.RoomClosed) => {
      this.teardown(event.reason);
    });

    // A deployment or scale-in is replacing the room's node. The socket is
    // fine; only media moves.
    socket.on(SERVER.nodeDraining, (event: SignalingEvents.NodeDraining) => {
      this.emit('nodeDraining', event);
      void this.handleNodeDraining();
    });
  }

  // -------------------------------------------------------------------------
  // Recovery
  // -------------------------------------------------------------------------

  private async handleNodeDraining(): Promise<void> {
    if (this.state !== 'joined') return;
    const attempts = this.options.rejoinAttempts ?? 3;

    for (let attempt = 1; attempt <= attempts; attempt += 1) {
      try {
        await this.rejoinMedia();
        return;
      } catch (cause) {
        this.options.logger?.warn('media rejoin failed', attempt, cause);
        if (this.state === 'closed') return;
        // Placement may still point at the draining node for a moment; backing
        // off and asking again is the whole strategy.
        await new Promise((resolve) => setTimeout(resolve, attempt * 3_000));
      }
    }

    this.emitError(
      new ApiError('sfu_unavailable', {
        detail: 'Could not move this session to another server.',
      }),
    );
    this.teardown('node-drained');
  }

  private captureLocalMedia(): LocalMediaSnapshot {
    const pick = (producer: MediasoupTypes.Producer | null) =>
      producer && isLiveTrack(producer.track)
        ? {
            track: producer.track as unknown as MediaStreamTrackLike,
            paused: producer.paused,
          }
        : null;

    return {
      camera: pick(this.producers.camera),
      microphone: pick(this.producers.microphone),
      wasSharing: this.isScreenSharing,
    };
  }

  /**
   * Republishes camera and microphone with their previous paused state. The
   * screen share is ended instead: the room's presenter lock and layout would
   * otherwise point at a producer that no longer exists, and re-capturing
   * someone's screen without a fresh gesture would be wrong.
   */
  private async restoreLocalMedia(): Promise<void> {
    const snapshot = this.pendingLocalMedia;
    if (!snapshot) return;

    if (snapshot.camera && isLiveTrack(snapshot.camera.track)) {
      await this.publishCamera(snapshot.camera.track);
      if (snapshot.camera.paused) await this.setCameraEnabled(false);
    }
    if (snapshot.microphone && isLiveTrack(snapshot.microphone.track)) {
      await this.publishMicrophone(snapshot.microphone.track);
      if (snapshot.microphone.paused) await this.setMicrophoneEnabled(false);
    }
    if (snapshot.wasSharing || this.screenHandle) {
      await this.stopScreenShare('reconnected');
    }

    this.pendingLocalMedia = null;
  }

  // -------------------------------------------------------------------------
  // Teardown
  // -------------------------------------------------------------------------

  private closeMedia({ stopLocalTracks }: { stopLocalTracks: boolean }): void {
    for (const [consumerId, consumer] of this.consumers) {
      consumer.close();
      this.emit('streamRemoved', { consumerId, producerId: consumer.producerId });
    }
    this.consumers.clear();
    this.consuming.clear();

    for (const key of ['camera', 'microphone', 'screen', 'screenAudio'] as const) {
      const producer = this.producers[key];
      if (!producer) continue;
      if (stopLocalTracks && (key === 'camera' || key === 'microphone')) {
        producer.track?.stop();
      }
      producer.close();
      this.producers[key] = null;
    }

    this.sendTransport?.close();
    this.recvTransport?.close();
    this.sendTransport = null;
    this.recvTransport = null;
  }

  private teardown(reason: string): void {
    this.stopScreenListener?.();
    this.stopScreenListener = null;
    this.screenHandle?.stop();
    this.screenHandle = null;

    this.closeMedia({ stopLocalTracks: true });
    for (const snapshot of [this.pendingLocalMedia?.camera, this.pendingLocalMedia?.microphone]) {
      (snapshot?.track as { stop?: () => void } | undefined)?.stop?.();
    }
    this.pendingLocalMedia = null;
    this.remoteProducers.clear();

    this.socket?.disconnect();
    this.socket = null;
    this.device = null;
    this.peerId = null;
    this.roomId = null;
    this.region = null;
    this.ice = null;
    this.relayForced = false;
    this.transportPolicy = 'all';
    this.consecutiveFailures = 0;

    this.setState('closed');
    this.emit('closed', reason);
  }

  // -------------------------------------------------------------------------
  // Request helper
  // -------------------------------------------------------------------------

  /**
   * Every signalling call is an ack, and every ack is `{ ok }`. Unwrapping it
   * here means the rest of this class deals in values and exceptions rather
   * than in envelopes.
   */
  private async request<TResponse = unknown>(event: string, payload: unknown): Promise<TResponse> {
    const socket = this.socket;
    if (!socket) {
      throw new ApiError('dependency_unavailable', { detail: 'Signalling socket is closed' });
    }
    const ack = await socket.emitWithAck<TResponse>(event, payload);
    if (!ack.ok) throw ApiError.fromResponse(ack.error);
    return ack.data;
  }

  private toApiError(cause: unknown, fallback: string): ApiError {
    return ApiError.is(cause)
      ? cause
      : new ApiError('internal_error', {
          detail: cause instanceof Error ? cause.message : fallback,
          cause,
        });
  }

  private emitError(cause: unknown): void {
    this.emit('error', this.toApiError(cause, 'Unknown media error'));
  }
}