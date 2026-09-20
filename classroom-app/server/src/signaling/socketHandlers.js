// classroom-app/server/src/signaling/socketHandlers.js
/**
 * Classroom signalling handlers  (F1, F8)  [EXT]
 *
 * Runs in realtime.js only, on the `/classroom` namespace. This is the whole
 * client-facing surface of a live session: every event in
 * SIGNALING_CLIENT_EVENTS is answered here and nowhere else.
 *
 * Version 7 shape:
 *
 *   - The client sends `classroom:join` and gets the placement back as data:
 *     the room state, both transports and the ICE configuration. It never
 *     learns a node id, a node URL or a control address (Appendix A #6).
 *   - Media objects are created through sfuControlClient over the private mTLS
 *     control RPC. This file never touches mediasoup.
 *   - `transport.restartIce` and a freshly minted ICE configuration on
 *     `transport.create` carry ICE recovery; `classroom:ice.update` pushes a
 *     new one when a TURN node drains or a secret rotates.
 *   - `join { rejoin: true }` rebuilds a peer's media without announcing a
 *     leave and a join, so a node drain looks like a pause, not a departure.
 *
 * The handlers stay thin on purpose: validation, permission, one call into the
 * domain, one fan-out. Presenter locks live in ScreenShareManager, moderation
 * in ModerationControls, breakouts in BreakoutManager, placement in
 * RoomPlacementService. If a rule has to be decided here, it belongs somewhere
 * else.
 */

import {
  ApiError,
  BreakoutActionSchema,
  CLASSROOM_NAMESPACE,
  ConnectTransportSchema,
  ConsumeSchema,
  ConsumerActionSchema,
  CreateTransportSchema,
  HostActionSchema,
  JoinRoomSchema,
  ProduceSchema,
  ProducerActionSchema,
  RaiseHandSchema,
  ReactionSchema,
  RestartIceSchema,
  SIGNALING_CLIENT_EVENTS as CLIENT,
  SIGNALING_SERVER_EVENTS as SERVER,
  StartScreenShareSchema,
} from '@classroom/contracts';

// ---------------------------------------------------------------------------
// Acknowledgement envelope
// ---------------------------------------------------------------------------

const toErrorResponse = (error) => {
  if (ApiError.is(error)) {
    return typeof error.toResponse === 'function'
      ? error.toResponse()
      : { code: error.code, detail: error.detail ?? null };
  }
  return { code: 'internal_error', detail: null };
};

const ok = (data = {}) => ({ ok: true, data });
const fail = (error) => ({ ok: false, error: toErrorResponse(error) });

const isZodError = (cause) => Array.isArray(cause?.issues);

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

/**
 * One connected client. The socket carries the authenticated user from
 * authSocket.js (`socket.data.user`, `socket.data.deviceSessionId`).
 */
class SignalingSession {
  /**
   * @param {import('socket.io').Socket} socket
   * @param {object} deps
   */
  constructor(socket, deps) {
    this.socket = socket;
    this.deps = deps;
    this.logger = deps.logger ?? console;

    this.roomId = null;
    this.peerId = null;
  }

  get user() {
    const user = this.socket.data?.user;
    if (!user?.id) throw new ApiError('unauthorized', { detail: 'The socket is not authenticated' });
    return user;
  }

  get deviceSessionId() {
    return this.socket.data?.deviceSessionId ?? null;
  }

  // -------------------------------------------------------------------------
  // Wiring
  // -------------------------------------------------------------------------

  bind() {
    const on = (event, schema, handler) =>
      this.socket.on(event, this.#guard(event, schema, handler.bind(this)));

    on(CLIENT.join, JoinRoomSchema, this.onJoin);
    on(CLIENT.leave, null, this.onLeave);

    on(CLIENT.createTransport, CreateTransportSchema, this.onCreateTransport);
    on(CLIENT.connectTransport, ConnectTransportSchema, this.onConnectTransport);
    on(CLIENT.restartIce, RestartIceSchema, this.onRestartIce);

    on(CLIENT.produce, ProduceSchema, this.onProduce);
    on(CLIENT.closeProducer, ProducerActionSchema, this.onCloseProducer);
    on(CLIENT.pauseProducer, ProducerActionSchema, this.onPauseProducer);
    on(CLIENT.resumeProducer, ProducerActionSchema, this.onResumeProducer);

    on(CLIENT.consume, ConsumeSchema, this.onConsume);
    on(CLIENT.resumeConsumer, ConsumerActionSchema, this.onResumeConsumer);

    on(CLIENT.startScreenShare, StartScreenShareSchema, this.onStartScreenShare);
    on(CLIENT.stopScreenShare, null, this.onStopScreenShare);

    on(CLIENT.raiseHand, RaiseHandSchema, this.onRaiseHand);
    on(CLIENT.react, ReactionSchema, this.onReact);
    on(CLIENT.hostAction, HostActionSchema, this.onHostAction);
    on(CLIENT.breakout, BreakoutActionSchema, this.onBreakout);

    this.socket.on('disconnect', (reason) => {
      void this.#teardown(reason === 'client namespace disconnect' ? 'left' : 'disconnected');
    });

    return this;
  }

  /** Validates, runs, and turns anything thrown into an ack. Never crashes the socket. */
  #guard(event, schema, handler) {
    return async (payload, ack) => {
      const respond = typeof ack === 'function' ? ack : typeof payload === 'function' ? payload : null;
      const body = typeof payload === 'function' ? {} : payload;

      try {
        const parsed = schema ? schema.parse(body ?? {}) : {};
        const data = (await handler(parsed)) ?? {};
        respond?.(ok(data));
      } catch (cause) {
        const error = isZodError(cause)
          ? new ApiError('validation_error', { detail: `Invalid payload for ${event}` })
          : cause;

        if (!ApiError.is(error)) {
          this.logger.error?.(
            { event, roomId: this.roomId, err: error },
            'signalling handler failed',
          );
        }
        this.deps.metrics?.increment?.('signaling_error', {
          event,
          code: ApiError.is(error) ? error.code : 'internal_error',
        });
        respond?.(fail(error));
      }
    };
  }

  // -------------------------------------------------------------------------
  // Room access helpers
  // -------------------------------------------------------------------------

  async #room() {
    if (!this.roomId) throw new ApiError('not_joined', { detail: 'Join a room first' });
    const room = await this.deps.sessions.get(this.roomId);
    if (!room) throw new ApiError('not_found', { detail: 'This room is no longer open' });
    return room;
  }

  async #peer(room) {
    const peer = room.getPeer(this.peerId);
    if (!peer) throw new ApiError('not_joined', { detail: 'This peer is no longer in the room' });
    return peer;
  }

  #requireHost(peer) {
    if (!peer.isHost) throw new ApiError('forbidden', { detail: 'Only a host can do this' });
    return peer;
  }

  /** Everyone in the room except this socket. */
  #others() {
    return this.socket.to(this.roomId);
  }

  #broadcast(event, payload) {
    this.#others().emit(event, payload);
  }

  #toHosts(room, event, payload) {
    for (const host of room.hosts()) {
      if (host.socketId) this.deps.namespace.to(host.socketId).emit(event, payload);
    }
  }

  // -------------------------------------------------------------------------
  // Join
  // -------------------------------------------------------------------------

  /**
   * Placement, transports and ICE in one acknowledgement (section 4.6, steps
   * 2–6). The order matters: the room is placed first, the node creates both
   * transports, and only then are TURN credentials minted — an admitted peer
   * that could not get a transport should not get a credential either.
   */
  async onJoin(payload) {
    const user = this.user;
    const { roomId, rejoin, regionHint, device } = payload;

    if (this.roomId && this.roomId !== roomId) {
      throw new ApiError('already_joined', { detail: 'This socket is already in another room' });
    }

    return this.deps.sessions.lock(roomId, async () => {
      const { room } = await this.deps.placement.place({
        roomId,
        user,
        regionHint,
        rejoin,
      });

      if (room.locked && !rejoin) {
        throw new ApiError('room_locked', { detail: 'The host locked this room' });
      }

      const existing = room.peerByUser(user.id);
      const isRejoin = rejoin && Boolean(existing);

      // Waiting room: a learner without admission is parked, the hosts are
      // told, and the client retries the join once it is let in.
      if (!isRejoin && room.waitingRoomEnabled) {
        const admitted = await this.deps.moderation.isAdmitted(room, user);
        if (!admitted) {
          const entry = room.knock({
            peerId: this.deps.ids.peerId(),
            user: this.deps.profiles.toActorRef(user),
          });
          await this.deps.sessions.save(room);
          this.#toHosts(room, SERVER.waitingPeer, entry);
          throw new ApiError('waiting_for_admission', {
            detail: 'The host has been notified',
          });
        }
      }

      const peer = isRejoin
        ? existing
        : this.deps.peers.create({
            user: this.deps.profiles.toActorRef(user),
            role: await this.deps.rbac.roleInRoom(user, room),
            device,
            socketId: this.socket.id,
          });

      if (isRejoin) {
        // The old node's producers are gone; tell everyone before new ones appear.
        for (const producer of peer.producers.values()) {
          this.#broadcast(SERVER.producerClosed, { producerId: producer.producerId });
        }
        peer.clearMedia();
        peer.socketId = this.socket.id;
      } else if (existing) {
        // One device per person: the previous connection is replaced.
        await this.#removePeer(room, existing, 'replaced');
      }

      room.addPeer(peer);
      this.roomId = room.roomId;
      this.peerId = peer.peerId;
      await this.socket.join(room.roomId);

      // Transports first, then credentials.
      const [sendTransport, recvTransport] = await Promise.all([
        this.deps.control.createTransport(room, { peerId: peer.peerId, direction: 'send' }),
        this.deps.control.createTransport(room, { peerId: peer.peerId, direction: 'recv' }),
      ]);
      peer.setTransport('send', sendTransport.transportId);
      peer.setTransport('recv', recvTransport.transportId);

      const ice = await this.deps.ice.issue({
        user,
        room,
        deviceSessionId: this.deviceSessionId,
        regionHint,
      });

      const routerRtpCapabilities = await this.deps.control.routerCapabilities(room);

      await this.deps.sessions.save(room);
      await this.deps.rooms.touch(room.roomId);

      if (!isRejoin) {
        this.#broadcast(SERVER.peerJoined, peer.toContract());
        void this.deps.attendance.recordJoin(room, peer);
        void this.deps.presence.setInClass(user.id, room.roomId);
      }

      this.deps.metrics?.increment?.('classroom_join', {
        region: room.mediaRegion,
        rejoin: String(isRejoin),
      });

      return {
        room: room.toRoomState({ selfPeerId: peer.peerId, routerRtpCapabilities }),
        sendTransport,
        recvTransport,
        ice,
      };
    });
  }

  async onLeave() {
    await this.#teardown('left');
    return {};
  }

  // -------------------------------------------------------------------------
  // Transports
  // -------------------------------------------------------------------------

  /**
   * Rebuilds one direction outside the join — IceRecovery's relay-only retry.
   * Creating a transport for a direction that already has one replaces it: the
   * node closes the old transport and everything on it, and the producers that
   * went with it are announced as closed.
   */
  async onCreateTransport({ direction, forceRelay }) {
    const room = await this.#room();
    const peer = await this.#peer(room);

    const previous = peer.transports[direction];
    if (previous) {
      await this.deps.control.closeTransport(room, { transportId: previous }).catch(() => undefined);
      if (direction === 'send') {
        for (const producer of peer.producers.values()) {
          this.#broadcast(SERVER.producerClosed, { producerId: producer.producerId });
          peer.removeProducer(producer.producerId);
        }
        if (room.screenShare?.peerId === peer.peerId) {
          await this.#releaseScreenShare(room, peer, 'disconnected');
        }
      }
    }

    const transport = await this.deps.control.createTransport(room, {
      peerId: peer.peerId,
      direction,
    });
    peer.setTransport(direction, transport.transportId);

    const ice = await this.deps.ice.issue({
      user: this.user,
      room,
      deviceSessionId: this.deviceSessionId,
      forceRelay,
    });

    await this.deps.sessions.save(room);
    if (forceRelay) this.deps.metrics?.increment?.('ice_relay_retry', { region: room.mediaRegion });

    return { transport, ice };
  }

  async onConnectTransport({ transportId, dtlsParameters }) {
    const room = await this.#room();
    const peer = await this.#peer(room);
    if (!peer.hasTransport(transportId)) {
      throw new ApiError('forbidden', { detail: 'That transport belongs to someone else' });
    }
    await this.deps.control.connectTransport(room, { transportId, dtlsParameters });
    return {};
  }

  /** New ICE parameters from the node; the client restarts ICE against them. */
  async onRestartIce({ transportId }) {
    const room = await this.#room();
    const peer = await this.#peer(room);
    if (!peer.hasTransport(transportId)) {
      throw new ApiError('forbidden', { detail: 'That transport belongs to someone else' });
    }

    const { iceParameters } = await this.deps.control.restartIce(room, { transportId });
    this.deps.metrics?.increment?.('ice_restart', { region: room.mediaRegion });
    return { iceParameters };
  }

  // -------------------------------------------------------------------------
  // Producing
  // -------------------------------------------------------------------------

  async onProduce({ transportId, kind, rtpParameters, source, appData }) {
    const room = await this.#room();
    const peer = await this.#peer(room);

    if (peer.transports.send !== transportId) {
      throw new ApiError('forbidden', { detail: 'Produce on your own send transport' });
    }
    await this.deps.moderation.assertMayProduce(room, peer, source);

    const { producerId } = await this.deps.control.produce(room, {
      transportId,
      peerId: peer.peerId,
      kind,
      rtpParameters,
      source,
      appData,
    });

    const producer = peer.addProducer({ producerId, kind, source });
    await this.deps.sessions.save(room);

    this.#broadcast(SERVER.newProducer, {
      producerId,
      peerId: peer.peerId,
      userId: peer.userId,
      kind,
      source,
      paused: producer.paused,
    });

    // The share becomes visible to the room only once its producer exists,
    // which is why this is here and not in screenShare.start.
    if (source === 'screen') {
      const started = await this.deps.screenShare.started(room, peer, { producerId });
      room.screenShare = started;
      await this.deps.sessions.save(room);
      this.deps.namespace.to(room.roomId).emit(SERVER.screenShareStarted, started);
    }
    if (source === 'screen-audio' && room.screenShare) {
      room.screenShare = { ...room.screenShare, audioProducerId: producerId };
      await this.deps.sessions.save(room);
    }

    return { producerId };
  }

  async onCloseProducer({ producerId }) {
    const room = await this.#room();
    const peer = await this.#peer(room);
    const producer = peer.producers.get(producerId);
    if (!producer) return {};

    await this.deps.control.closeProducer(room, { producerId }).catch(() => undefined);
    peer.removeProducer(producerId);
    await this.deps.sessions.save(room);
    this.#broadcast(SERVER.producerClosed, { producerId });
    return {};
  }

  async onPauseProducer({ producerId }) {
    return this.#setProducerPaused(producerId, true);
  }

  async onResumeProducer({ producerId }) {
    return this.#setProducerPaused(producerId, false);
  }

  async #setProducerPaused(producerId, paused) {
    const room = await this.#room();
    const peer = await this.#peer(room);
    if (!peer.producers.has(producerId)) {
      throw new ApiError('forbidden', { detail: 'That producer belongs to someone else' });
    }

    await this.deps.control.setProducerPaused(room, { producerId, paused });
    peer.setProducerPaused(producerId, paused);
    await this.deps.sessions.save(room);

    // Pausing keeps the producer alive, so the room only needs the peer update.
    this.#broadcast(SERVER.peerUpdated, peer.toContract());
    return {};
  }

  // -------------------------------------------------------------------------
  // Consuming
  // -------------------------------------------------------------------------

  async onConsume({ transportId, producerId, rtpCapabilities }) {
    const room = await this.#room();
    const peer = await this.#peer(room);

    if (peer.transports.recv !== transportId) {
      throw new ApiError('forbidden', { detail: 'Consume on your own receive transport' });
    }

    const found = room.findProducer(producerId);
    if (!found) throw new ApiError('not_found', { detail: 'That producer is gone' });
    if (found.peer.peerId === peer.peerId) {
      throw new ApiError('validation_error', { detail: 'A peer does not consume itself' });
    }
    // Breakouts are separate audiences: media does not leak between groups.
    if (found.peer.breakoutId !== peer.breakoutId) {
      throw new ApiError('forbidden', { detail: 'That peer is in another breakout room' });
    }

    const consumer = await this.deps.control.consume(room, {
      transportId,
      producerId,
      rtpCapabilities,
    });

    peer.consumers.add(consumer.consumerId);
    await this.deps.sessions.save(room);

    return {
      consumerId: consumer.consumerId,
      producerId,
      kind: found.producer.kind,
      source: found.producer.source,
      rtpParameters: consumer.rtpParameters,
      producerPaused: found.producer.paused,
    };
  }

  /** Consumers are created paused so the client can attach the track first. */
  async onResumeConsumer({ consumerId }) {
    const room = await this.#room();
    const peer = await this.#peer(room);
    if (!peer.consumers.has(consumerId)) {
      throw new ApiError('forbidden', { detail: 'That consumer belongs to someone else' });
    }
    await this.deps.control.resumeConsumer(room, { consumerId });
    return {};
  }

  // -------------------------------------------------------------------------
  // Screen sharing
  // -------------------------------------------------------------------------

  /**
   * Only the lock. The client opens its picker afterwards and publishes a
   * second producer on the transport it already has; a refused request never
   * reaches a picker.
   */
  async onStartScreenShare({ label, withAudio }) {
    const room = await this.#room();
    const peer = await this.#peer(room);

    await this.deps.screenShare.acquire(room, peer, { label, withAudio });
    await this.deps.sessions.save(room);
    return {};
  }

  async onStopScreenShare() {
    const room = await this.#room();
    const peer = await this.#peer(room);
    await this.#releaseScreenShare(room, peer, 'stopped');
    return {};
  }

  async #releaseScreenShare(room, peer, reason) {
    const released = await this.deps.screenShare.release(room, peer, reason);
    if (!released) return;

    room.screenShare = null;
    await this.deps.sessions.save(room);
    this.deps.namespace.to(room.roomId).emit(SERVER.screenShareStopped, {
      peerId: peer.peerId,
      producerId: released.producerId,
      reason,
    });
  }

  // -------------------------------------------------------------------------
  // Interaction
  // -------------------------------------------------------------------------

  async onRaiseHand({ raised }) {
    const room = await this.#room();
    const peer = await this.#peer(room);

    this.deps.handRaise.set(room, peer, raised);
    await this.deps.sessions.save(room);

    this.deps.namespace.to(room.roomId).emit(SERVER.handRaised, { peerId: peer.peerId, raised });
    return {};
  }

  /** Ephemeral: never persisted, never in the chat history. */
  async onReact({ emoji }) {
    const room = await this.#room();
    const peer = await this.#peer(room);
    this.deps.namespace.to(room.roomId).emit(SERVER.reaction, { peerId: peer.peerId, emoji });
    return {};
  }

  // -------------------------------------------------------------------------
  // Moderation and breakouts
  // -------------------------------------------------------------------------

  async onHostAction(action) {
    const room = await this.#room();
    const actor = this.#requireHost(await this.#peer(room));

    const effects = await this.deps.moderation.apply(room, actor, action);
    await this.deps.sessions.save(room);
    await this.deps.audit.record({
      actorId: actor.userId,
      action: `classroom.${action.action}`,
      roomId: room.roomId,
      targetPeerId: action.targetPeerId,
      reason: action.reason ?? null,
    });

    for (const effect of effects) await this.#applyEffect(room, effect);
    return {};
  }

  /**
   * ModerationControls decides; this only carries the result to the room. The
   * effect names are its vocabulary, not a second rule set.
   */
  async #applyEffect(room, effect) {
    switch (effect.type) {
      case 'peer-updated':
        this.deps.namespace.to(room.roomId).emit(SERVER.peerUpdated, effect.peer.toContract());
        break;
      case 'producer-closed':
        this.deps.namespace.to(room.roomId).emit(SERVER.producerClosed, {
          producerId: effect.producerId,
        });
        break;
      case 'screen-share-revoked':
        this.deps.namespace.to(room.roomId).emit(SERVER.screenShareStopped, {
          peerId: effect.peerId,
          producerId: effect.producerId,
          reason: 'revoked',
        });
        break;
      case 'peer-removed':
        await this.#removePeer(room, effect.peer, 'removed');
        if (effect.peer.socketId) {
          this.deps.namespace.to(effect.peer.socketId).emit(SERVER.roomClosed, {
            reason: 'ended-by-host',
          });
          this.deps.namespace.sockets.get(effect.peer.socketId)?.leave(room.roomId);
        }
        break;
      case 'recording-changed':
        this.deps.namespace.to(room.roomId).emit(SERVER.recordingChanged, {
          recording: effect.recording,
          startedBy: effect.startedBy ?? null,
        });
        break;
      case 'waiting-peer':
        this.#toHosts(room, SERVER.waitingPeer, effect.entry);
        break;
      default:
        this.logger.warn?.({ type: effect.type }, 'unknown moderation effect');
    }
  }

  async onBreakout(action) {
    const room = await this.#room();
    const peer = await this.#peer(room);
    if (action.action !== 'join') this.#requireHost(peer);

    const changes = await this.deps.breakouts.apply(room, peer, action);
    await this.deps.sessions.save(room);

    for (const change of changes) {
      const target = change.socketId
        ? this.deps.namespace.to(change.socketId)
        : this.deps.namespace.to(room.roomId);
      target.emit(SERVER.breakoutChanged, {
        breakoutId: change.breakoutId,
        endsAt: change.endsAt ?? null,
      });
    }
    return {};
  }

  // -------------------------------------------------------------------------
  // Teardown
  // -------------------------------------------------------------------------

  async #teardown(reason) {
    if (!this.roomId || !this.peerId) return;
    const roomId = this.roomId;
    const peerId = this.peerId;
    this.roomId = null;
    this.peerId = null;

    try {
      await this.deps.sessions.lock(roomId, async () => {
        const room = await this.deps.sessions.get(roomId);
        const peer = room?.getPeer(peerId);
        if (!room || !peer) return;
        await this.#removePeer(room, peer, reason);
      });
    } catch (cause) {
      this.logger.error?.({ roomId, peerId, err: cause }, 'teardown failed');
    }
  }

  async #removePeer(room, peer, reason) {
    if (room.screenShare?.peerId === peer.peerId) {
      await this.#releaseScreenShare(room, peer, 'disconnected');
    }

    await this.deps.control
      .closePeer(room, { peerId: peer.peerId })
      .catch((cause) => this.logger.warn?.({ err: cause }, 'closing peer media failed'));

    room.removePeer(peer.peerId);
    await this.deps.sessions.save(room);

    this.deps.namespace.to(room.roomId).emit(SERVER.peerLeft, { peerId: peer.peerId, reason });
    void this.deps.attendance.recordLeave(room, peer, reason);
    void this.deps.presence.clearInClass(peer.userId, room.roomId);

    // An empty room frees its node, which is what lets a drain finish.
    if (room.isEmpty) {
      await this.deps.placement.releaseRoom(room);
    } else {
      await this.deps.rooms.touch(room.roomId);
    }
  }
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

/**
 * @param {object} options
 * @param {import('socket.io').Server} options.io
 * @param {(socket: any, next: Function) => void} options.authenticate  signaling/authSocket.js
 * @param {(socket: any, next: Function) => void} [options.rateLimit]   realtime/socketRateLimit.js
 * @param {object} options.deps  placement · control · ice · sessions · rooms ·
 *   screenShare · moderation · breakouts · handRaise · attendance · presence ·
 *   audit · rbac · profiles · peers · ids · metrics · logger
 */
export const registerSignalingHandlers = ({ io, authenticate, rateLimit, deps }) => {
  const namespace = io.of(CLASSROOM_NAMESPACE);

  namespace.use(authenticate);
  if (rateLimit) namespace.use(rateLimit);

  const scoped = { ...deps, namespace };

  namespace.on('connection', (socket) => {
    new SignalingSession(socket, scoped).bind();
  });

  /**
   * Pushed, not asked for: a TURN node drained, the secret ring rotated or a
   * tenant changed its ICE policy. Never counted against the user's issuance
   * budget — nobody should be locked out of a replacement they did not request.
   */
  const pushIceUpdate = (roomId, ice, reason) => {
    namespace.to(roomId).emit(SERVER.iceUpdate, { ice, reason });
  };

  /**
   * The room's SFU node is draining. Clients rebuild media with
   * `join { rejoin: true }`; the signalling socket is untouched.
   */
  const announceNodeDraining = (roomId, graceSec) => {
    namespace.to(roomId).emit(SERVER.nodeDraining, { graceSec });
  };

  const closeRoom = (roomId, reason) => {
    namespace.to(roomId).emit(SERVER.roomClosed, { reason });
  };

  return Object.freeze({ namespace, pushIceUpdate, announceNodeDraining, closeRoom });
};

export default registerSignalingHandlers;