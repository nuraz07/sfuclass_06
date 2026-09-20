// classroom-app/server/src/classroom/Room.js
/**
 * Room  (F1, F8)  [EXT]
 *
 * One live session: its peers, its waiting room, its breakouts, its recording
 * state and the active screen share. Like Peer.js it is a plain domain model,
 * shared by the realtime service (session state, moderation, fan-out) and the
 * SFU node (which knows the same room by its router).
 *
 * Version 7 additions:
 *
 *   lessonId        the course lesson this session belongs to (F3), or null
 *   mode            lecture · seminar · office-hours; drives layout and defaults
 *   breakoutParent  set on a child room created by BreakoutManager
 *   mediaRegion     where the media lives, chosen by RoomPlacementService from
 *                   tenant residency policy and the host's region hint
 *
 * `nodeId` travels with `mediaRegion` because a room lives on exactly one node
 * at a time. Both change together when a drained node forces a re-placement —
 * `setPlacement()` is the only way they move, and RoomRegistry mirrors it into
 * the state cluster so any realtime task can find the room.
 *
 * `toRoomState()` produces exactly RoomStateSchema.
 */

import { Peer } from './Peer.js';

export const ROOM_MODES = Object.freeze(['lecture', 'seminar', 'office-hours']);

export class Room {
  /**
   * @param {object} init
   * @param {string} init.roomId
   * @param {string|null} [init.lessonId]
   * @param {'lecture'|'seminar'|'office-hours'} [init.mode]
   * @param {string} init.mediaRegion
   * @param {string|null} [init.nodeId]
   * @param {string|null} [init.breakoutParent]  parent room id for a breakout
   * @param {boolean} [init.waitingRoomEnabled]
   * @param {string} [init.startedAt]
   */
  constructor({
    roomId,
    lessonId = null,
    mode = 'seminar',
    mediaRegion,
    nodeId = null,
    breakoutParent = null,
    waitingRoomEnabled = false,
    startedAt = new Date().toISOString(),
  }) {
    if (!roomId) throw new TypeError('a room needs a roomId');
    if (!ROOM_MODES.includes(mode)) throw new TypeError(`unknown room mode: ${mode}`);

    this.roomId = roomId;
    this.lessonId = lessonId;
    this.mode = mode;
    this.mediaRegion = mediaRegion;
    this.nodeId = nodeId;
    this.breakoutParent = breakoutParent;
    this.waitingRoomEnabled = waitingRoomEnabled;
    this.startedAt = startedAt;

    /** @type {Map<string, Peer>} peerId → peer */
    this.peers = new Map();
    /** @type {Map<string, { peerId: string, user: object, knockedAt: string }>} */
    this.waiting = new Map();
    /** @type {Map<string, { breakoutId: string, name: string, roomId: string, endsAt: string|null }>} */
    this.breakouts = new Map();

    this.recording = { active: false, startedBy: null, startedAt: null };
    /** ScreenShareStarted, owned by ScreenShareManager; mirrored here for the room state. */
    this.screenShare = null;
    this.locked = false;
    this.closedAt = null;
  }

  // -------------------------------------------------------------------------
  // Placement
  // -------------------------------------------------------------------------

  get isPlaced() {
    return Boolean(this.nodeId);
  }

  /** Called by RoomPlacementService on the first join and after a re-placement. */
  setPlacement({ nodeId, mediaRegion = this.mediaRegion }) {
    const moved = this.nodeId !== null && this.nodeId !== nodeId;
    this.nodeId = nodeId;
    this.mediaRegion = mediaRegion;
    if (moved) {
      // Every media object lived on the old node; nothing here survives it.
      for (const peer of this.peers.values()) peer.clearMedia();
      this.screenShare = null;
    }
    return moved;
  }

  // -------------------------------------------------------------------------
  // Peers
  // -------------------------------------------------------------------------

  get size() {
    return this.peers.size;
  }

  get isEmpty() {
    return this.peers.size === 0;
  }

  addPeer(peer) {
    if (!(peer instanceof Peer)) throw new TypeError('addPeer expects a Peer');
    this.peers.set(peer.peerId, peer);
    return peer;
  }

  removePeer(peerId) {
    const peer = this.peers.get(peerId);
    if (!peer) return null;
    this.peers.delete(peerId);
    if (this.screenShare?.peerId === peerId) this.screenShare = null;
    return peer;
  }

  getPeer(peerId) {
    return this.peers.get(peerId) ?? null;
  }

  peerBySocket(socketId) {
    for (const peer of this.peers.values()) {
      if (peer.socketId === socketId) return peer;
    }
    return null;
  }

  /** A user may be in the room from one device at a time; the second replaces the first. */
  peerByUser(userId) {
    for (const peer of this.peers.values()) {
      if (peer.userId === userId) return peer;
    }
    return null;
  }

  hosts() {
    return [...this.peers.values()].filter((peer) => peer.isHost);
  }

  hasHost() {
    return this.hosts().length > 0;
  }

  /** Peers in the main room, i.e. not currently in a breakout. */
  mainRoomPeers() {
    return [...this.peers.values()].filter((peer) => peer.breakoutId === null);
  }

  /** Every producer in the room except the given peer's own. */
  producersExcept(peerId) {
    const producers = [];
    for (const peer of this.peers.values()) {
      if (peer.peerId === peerId) continue;
      for (const producer of peer.producers.values()) {
        producers.push({
          producerId: producer.producerId,
          peerId: peer.peerId,
          userId: peer.userId,
          kind: producer.kind,
          source: producer.source,
          paused: producer.paused,
        });
      }
    }
    return producers;
  }

  findProducer(producerId) {
    for (const peer of this.peers.values()) {
      const producer = peer.producers.get(producerId);
      if (producer) return { peer, producer };
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Waiting room, recording, breakouts
  // -------------------------------------------------------------------------

  knock({ peerId, user }) {
    const entry = { peerId, user, knockedAt: new Date().toISOString() };
    this.waiting.set(peerId, entry);
    return entry;
  }

  admit(peerId) {
    const entry = this.waiting.get(peerId);
    this.waiting.delete(peerId);
    return entry ?? null;
  }

  setRecording({ active, startedBy = null }) {
    this.recording = {
      active,
      startedBy: active ? startedBy : null,
      startedAt: active ? new Date().toISOString() : null,
    };
    return this.recording;
  }

  addBreakout(breakout) {
    this.breakouts.set(breakout.breakoutId, breakout);
    return breakout;
  }

  clearBreakouts() {
    this.breakouts.clear();
    for (const peer of this.peers.values()) peer.moveToBreakout(null);
  }

  // -------------------------------------------------------------------------
  // Serialisation
  // -------------------------------------------------------------------------

  /**
   * RoomStateSchema for one recipient. The router capabilities come from the
   * owning node with the join acknowledgement; the transports and the ICE
   * configuration are added by the signalling handler, not here.
   */
  toRoomState({ selfPeerId, routerRtpCapabilities }) {
    const self = this.getPeer(selfPeerId);
    return {
      roomId: this.roomId,
      lessonId: this.lessonId,
      mode: this.mode,
      mediaRegion: this.mediaRegion,
      routerRtpCapabilities,
      peers: [...this.peers.values()].map((peer) => peer.toContract()),
      selfPeerId,
      selfRole: self?.role ?? 'learner',
      recording: this.recording.active,
      screenShare: this.screenShare,
      waitingRoomEnabled: this.waitingRoomEnabled,
      startedAt: this.startedAt,
    };
  }

  toJSON() {
    return {
      roomId: this.roomId,
      lessonId: this.lessonId,
      mode: this.mode,
      mediaRegion: this.mediaRegion,
      nodeId: this.nodeId,
      breakoutParent: this.breakoutParent,
      waitingRoomEnabled: this.waitingRoomEnabled,
      startedAt: this.startedAt,
      locked: this.locked,
      recording: this.recording,
      screenShare: this.screenShare,
      peers: [...this.peers.values()].map((peer) => peer.toJSON()),
      waiting: [...this.waiting.values()],
      breakouts: [...this.breakouts.values()],
    };
  }

  static fromJSON(data) {
    const room = new Room(data);
    room.locked = data.locked ?? false;
    room.recording = data.recording ?? { active: false, startedBy: null, startedAt: null };
    room.screenShare = data.screenShare ?? null;
    for (const peer of data.peers ?? []) room.peers.set(peer.peerId, Peer.fromJSON(peer));
    for (const entry of data.waiting ?? []) room.waiting.set(entry.peerId, entry);
    for (const breakout of data.breakouts ?? []) room.breakouts.set(breakout.breakoutId, breakout);
    return room;
  }
}

export default Room;