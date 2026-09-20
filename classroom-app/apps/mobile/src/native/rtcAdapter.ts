// classroom-app/apps/mobile/src/native/rtcAdapter.ts
/**
 * React Native device adapter  (F1, F5, F8)  [EXT]
 *
 * Implements DeviceAdapter from packages/core-client for react-native-webrtc,
 * so SfuClient runs unchanged on iOS and Android. Everything platform-specific
 * about capture lives here; everything about signalling, transports, ICE and
 * recovery stays in the shared client.
 *
 * Version 7: nothing about ICE is decided here. The ICE configuration —
 * STUN/TURN servers, temporary credentials and the transport policy — arrives
 * from the API in the join acknowledgement and is applied by SfuClient to both
 * transports, exactly as on the web. A phone on a carrier network is the most
 * likely client to end up relayed, which is precisely why it must not have its
 * own copy of the rules.
 *
 * `registerGlobals()` puts RTCPeerConnection, MediaStream and friends on the
 * global object, which is what mediasoup-client's ReactNative handler expects.
 * It runs once, at module load, before any Device is created.
 *
 * Wi-Fi ↔ cellular handover is not handled here: networkMonitor.ts watches the
 * connection and asks SfuClient for an ICE restart, because a handover is a
 * connectivity event, not a device event.
 */

import { Platform } from 'react-native';
import { Device, type types as MediasoupTypes } from 'mediasoup-client';
import {
  MediaStream,
  MediaStreamTrack,
  mediaDevices,
  registerGlobals,
} from 'react-native-webrtc';
import type {
  DeviceAdapter,
  DeviceCapabilities,
  MediaStreamTrackLike,
} from '@classroom/core-client';

registerGlobals();

type CameraFacing = 'user' | 'environment';

export interface RtcAdapterOptions {
  /** Starting camera; the classroom screen can flip it later. */
  facing?: CameraFacing;
  /** Capture size requested from the camera; the SFU never upscales. */
  video?: { width: number; height: number; frameRate: number };
  logger?: { debug(...args: unknown[]): void; warn(...args: unknown[]): void };
}

const DEFAULT_VIDEO = { width: 1280, height: 720, frameRate: 24 } as const;

/**
 * Simulcast is off on React Native. react-native-webrtc supports it unevenly
 * across encoders, and a half-working spatial layer set is worse for a lesson
 * than one honest stream: the SFU can forward what it gets, but it cannot
 * repair layers that were never produced.
 */
const capabilities: DeviceCapabilities = Object.freeze({
  supportsSimulcast: false,
  supportsScreenShare: Platform.OS === 'ios' || Platform.OS === 'android',
  supportsBackgroundAudio: true,
  maxVideoHeight: 720,
});

export class RtcAdapter implements DeviceAdapter {
  readonly platform: 'ios' | 'android';
  readonly capabilities = capabilities;

  private readonly options: Required<Pick<RtcAdapterOptions, 'video'>> & RtcAdapterOptions;
  private facing: CameraFacing;
  private cameraStream: MediaStream | null = null;
  private microphoneStream: MediaStream | null = null;

  constructor(options: RtcAdapterOptions = {}) {
    this.platform = Platform.OS === 'ios' ? 'ios' : 'android';
    this.options = { video: DEFAULT_VIDEO, ...options };
    this.facing = options.facing ?? 'user';
  }

  /**
   * mediasoup-client picks its handler from the environment; on React Native
   * the handler has to be named explicitly, because there is no browser to
   * sniff. One Device per session, loaded by SfuClient from the router
   * capabilities in the join acknowledgement.
   */
  createMediasoupDevice(): MediasoupTypes.Device {
    return new Device({ handlerName: 'ReactNative' });
  }

  // -------------------------------------------------------------------------
  // Capture
  // -------------------------------------------------------------------------

  async getCameraTrack(): Promise<MediaStreamTrackLike> {
    const { width, height, frameRate } = this.options.video;
    const stream = (await mediaDevices.getUserMedia({
      audio: false,
      video: {
        width,
        height,
        frameRate,
        facingMode: this.facing,
      },
    })) as unknown as MediaStream;

    this.stopStream(this.cameraStream);
    this.cameraStream = stream;

    const [track] = stream.getVideoTracks();
    if (!track) throw new Error('The camera returned no video track');
    return track as unknown as MediaStreamTrackLike;
  }

  async getMicrophoneTrack(): Promise<MediaStreamTrackLike> {
    const stream = (await mediaDevices.getUserMedia({
      audio: {
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true,
      },
      video: false,
    })) as unknown as MediaStream;

    this.stopStream(this.microphoneStream);
    this.microphoneStream = stream;

    const [track] = stream.getAudioTracks();
    if (!track) throw new Error('The microphone returned no audio track');
    return track as unknown as MediaStreamTrackLike;
  }

  /**
   * Flips the camera in place. `_switchCamera` keeps the same track, so the
   * producer is untouched: no renegotiation, no black frame for everyone else.
   */
  async switchCamera(): Promise<CameraFacing> {
    const [track] = this.cameraStream?.getVideoTracks() ?? [];
    if (!track) return this.facing;

    const switchable = track as unknown as MediaStreamTrack & { _switchCamera?: () => void };
    if (typeof switchable._switchCamera === 'function') {
      switchable._switchCamera();
      this.facing = this.facing === 'user' ? 'environment' : 'user';
      return this.facing;
    }

    // Older builds have no in-place switch: re-capture and let the caller
    // replace the producer's track.
    this.facing = this.facing === 'user' ? 'environment' : 'user';
    await this.getCameraTrack();
    return this.facing;
  }

  async listDevices(): Promise<Array<{ deviceId: string; kind: string; label: string }>> {
    const devices = (await mediaDevices.enumerateDevices()) as unknown as Array<{
      deviceId: string;
      kind: string;
      label: string;
    }>;
    return devices;
  }

  /**
   * Called when the lesson ends. Tracks belong to the caller (SfuClient
   * produces with stopTracks: false), so this is the only place the camera
   * light goes out.
   */
  release(): void {
    this.stopStream(this.cameraStream);
    this.stopStream(this.microphoneStream);
    this.cameraStream = null;
    this.microphoneStream = null;
  }

  private stopStream(stream: MediaStream | null): void {
    if (!stream) return;
    for (const track of stream.getTracks()) {
      try {
        track.stop();
      } catch (cause) {
        this.options.logger?.warn?.('stopping a track failed', cause);
      }
    }
  }
}

export const createRtcAdapter = (options?: RtcAdapterOptions): DeviceAdapter =>
  new RtcAdapter(options);

export default createRtcAdapter;