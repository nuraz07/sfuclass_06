// classroom-app/server/src/classroom/Peer.js
/**
 * Peer  (F1, F8)  [EXT]
 *
 * One person in one room: their role, their media and their two transports.
 * A plain domain model — no mediasoup objects, no socket, no Redis — because
 * the same shape is used in two places. The realtime service owns it as
 * session state (peer list, hand raise, presenter lock, moderation), the SFU
 * node keeps only the media objects it was asked to create, and the two are
 * joined by the ids stored here.
 *
 * Version 7 additions: the role, the producer set per source
 * (camera · microphone · screen · screen-audio) and the transport ids.
 *
 * A screen share is not a second peer. It is a second video producer on this
 * peer with `source: 'screen'`, on the same send transport, which is what lets
 * every client lay it out differently without a parallel code path.
 *
 * `toContract()` produces exactly PeerSchema from
 * packages/contracts/src/events/signaling.events.ts.
 */

export const PEER_ROLES = Object.freeze(['host', 'cohost', 'learner']);
export const MEDIA_SOURCES = Object.freeze(['camera', 'microphone', 'screen', 'screen-audio']);

const SOURCE_KEYS = Object.freeze({
  camera: 'camera',
  microphone: 'microphone',
  screen: 'screen',
  'screen-audio': 'screenAudio',
});

export class Peer {
  /**
   * @param {object} init
   * @param {string} init.peerId
   * @param {{ id: string, displayName?: string, avatarUrl?: string | null }} init.user  ActorRef
   * @param {'host'|'cohost'|'learner'} [init.role]
   * @param {string} [init.socketId]      the realtime connection carrying this peer
   * @param {{ platform: 'web'|'ios'|'android', supportsScreenShare: boolean }} [init.device]
   * @param {string|null} [init.breakoutId]
   * @param {string} [init.joinedAt]
   */
  constructor({
    peerId,
    user,
    role = 'learner',
    socketId = null,
    device = { platform: 'web', supportsScreenShare: false },
    breakoutId = null,
    joinedAt = new Date().toISOString(),
  }) {
    if (!peerId) throw new TypeError('a peer needs a peerId');
    if (!user?.id) throw new TypeError('a peer needs a user');
    if (!PEER_ROLES.includes(role)) throw new TypeError(`unknown peer role: ${role}`);

    this.peerId = peerId;
    this.user = user;
    this.role = role;
    this.socketId = socketId;
    this.device = device;
    this.breakoutId = breakoutId;
    this.joinedAt = joinedAt;

    this.handRaised = false;
    this.handRaisedAt = null;

    /** Transport ids on the owning SFU node. */
    this.transports = { send: null, recv: null };

    /** @type {Map<string, { producerId: string, kind: 'audio'|'video', source: string, paused: boolean, label?: string|null }>} */
    this.producers = new Map();
    /** Consumer ids, so a peer can be torn down without asking the node. */
    this.consumers = new Set();

    /** Set while the peer rebuilds its media; suppresses peer.left broadcasts. */
    this.rejoining = false;
  }

  get userId() {
    return this.user.id;
  }

  get isHost() {
    return this.role === 'host' || this.role === 'cohost';
  }

  get isSharingScreen() {
    return this.producerBySource('screen') !== null;
  }

  setRole(role) {
    if (!PEER_ROLES.includes(role)) throw new TypeError(`unknown peer role: ${role}`);
    this.role = role;
    return this;
  }

  setTransport(direction, transportId) {
    if (direction !== 'send' && direction !== 'recv') {
      throw new TypeError(`unknown transport direction: ${direction}`);
    }
    this.transports[direction] = transportId;
    return this;
  }

  hasTransport(transportId) {
    return this.transports.send === transportId || this.transports.recv === transportId;
  }

  // -------------------------------------------------------------------------
  // Media
  // -------------------------------------------------------------------------

  addProducer({ producerId, kind, source, paused = false, label = null }) {
    if (!MEDIA_SOURCES.includes(source)) throw new TypeError(`unknown media source: ${source}`);
    // One producer per source: publishing again replaces the previous one.
    const previous = this.producerBySource(source);
    if (previous) this.producers.delete(previous.producerId);
    this.producers.set(producerId, { producerId, kind, source, paused, label });
    return this.producers.get(producerId);
  }

  removeProducer(producerId) {
    return this.producers.delete(producerId);
  }

  producerBySource(source) {
    for (const producer of this.producers.values()) {
      if (producer.source === source) return producer;
    }
    return null;
  }

  setProducerPaused(producerId, paused) {
    const producer = this.producers.get(producerId);
    if (!producer) return null;
    producer.paused = paused;
    return producer;
  }

  /** `{ camera, microphone, screen, screenAudio }`, each a producer or null. */
  get media() {
    const media = { camera: null, microphone: null, screen: null, screenAudio: null };
    for (const producer of this.producers.values()) {
      media[SOURCE_KEYS[producer.source]] = producer;
    }
    return media;
  }

  /**
   * Drops every media object without touching identity, role, hand or the
   * presenter lock. This is what a `join { rejoin: true }` does: the node's
   * transports and producers are gone, the person is still in the lesson.
   */
  clearMedia() {
    this.producers.clear();
    this.consumers.clear();
    this.transports = { send: null, recv: null };
    return this;
  }

  // -------------------------------------------------------------------------
  // Interaction
  // -------------------------------------------------------------------------

  raiseHand(raised) {
    this.handRaised = raised;
    this.handRaisedAt = raised ? new Date().toISOString() : null;
    return this;
  }

  moveToBreakout(breakoutId) {
    this.breakoutId = breakoutId;
    return this;
  }

  // -------------------------------------------------------------------------
  // Serialisation
  // -------------------------------------------------------------------------

  /** PeerSchema, as every client receives it. */
  toContract() {
    return {
      peerId: this.peerId,
      user: this.user,
      role: this.role,
      handRaised: this.handRaised,
      producers: [...this.producers.values()].map(({ producerId, kind, source, paused }) => ({
        producerId,
        peerId: this.peerId,
        userId: this.userId,
        kind,
        source,
        paused,
      })),
      joinedAt: this.joinedAt,
      breakoutId: this.breakoutId,
    };
  }

  /** Full state, including what clients never see. For the session store. */
  toJSON() {
    return {
      peerId: this.peerId,
      user: this.user,
      role: this.role,
      socketId: this.socketId,
      device: this.device,
      breakoutId: this.breakoutId,
      joinedAt: this.joinedAt,
      handRaised: this.handRaised,
      handRaisedAt: this.handRaisedAt,
      transports: this.transports,
      producers: [...this.producers.values()],
      consumers: [...this.consumers],
    };
  }

  static fromJSON(data) {
    const peer = new Peer(data);
    peer.handRaised = data.handRaised ?? false;
    peer.handRaisedAt = data.handRaisedAt ?? null;
    peer.transports = data.transports ?? { send: null, recv: null };
    for (const producer of data.producers ?? []) peer.producers.set(producer.producerId, producer);
    for (const consumerId of data.consumers ?? []) peer.consumers.add(consumerId);
    return peer;
  }
}

export default Peer;