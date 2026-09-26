// classroom-app/server/src/signaling/socketHandlers.js
/**
 * Classroom signalling  (F1)  [EXT]
 *
 * Namespace: `/classroom` (CLASSROOM_NAMESPACE)
 *
 * Event names come from packages/contracts/src/events/signaling.events.ts,
 * never from local literals, so the contract test catches drift rather than a
 * user discovering it. packages/core-client/src/rtc/SfuClient.ts is written
 * against the same constants, which is what makes the two halves fit.
 *
 * What this file is: a thin, rate-limited, role-checked adapter between
 * Socket.IO and the classroom domain.
 *
 * What it is not: a place where classroom rules live. The presenter lock is
 * ScreenShareManager's, admit/mute/remove are ModerationControls', splits are
 * BreakoutManager's. Those modules also *broadcast their own outcomes* through
 * `room.broadcast` / `room.sendTo`, so handlers here must not re-emit what they
 * already sent — a doubled `screenShare.stopped` makes a client tear down a
 * share twice.
 *
 * Contract with authSocket.js: by the time a handler runs the JWT handshake has
 * populated socket.data = { userId, tenantId, role, displayName, avatarUrl,
 * deviceId, sessionId } and rejected the connection otherwise. Handlers never
 * re-read identity from the payload.
 *
 * Ack envelope, matching SocketAck<T> in the contracts package:
 *     ack({ ok: true,  data })
 *     ack({ ok: false, error: { code, message, traceId } })
 */

import crypto from 'node:crypto';

import { SignalingEvents } from '@classroom/contracts';

import * as RoomManager from '../classroom/RoomManager.js';
import * as RoomRegistry from '../classroom/RoomRegistry.js';
import * as ScreenShareManager from '../classroom/ScreenShareManager.js';
import * as BreakoutManager from '../classroom/BreakoutManager.js';
import * as ModerationControls from '../classroom/ModerationControls.js';
import * as AttendanceService from '../classroom/AttendanceService.js';
import * as HandRaise from '../classroom/interaction/HandRaise.js';
import * as Reactions from '../classroom/interaction/Reactions.js';
import { Peer } from '../classroom/Peer.js';
import { createWebRtcTransport } from '../mediasoup/createWebRtcTransport.js';
import { isDraining } from '../lifecycle/drainSfu.js';
import { consumeSocketBudget } from '../middleware/rateLimit.js';
import * as CapacityGuard from '../capacity/CapacityGuard.js';
import { env } from '../config/env.js';
import { logger } from '../observability/logger.js';
import { metrics } from '../observability/metrics.js';

const {
  CLASSROOM_NAMESPACE,
  SIGNALING_CLIENT_EVENTS: CLIENT,
  SIGNALING_SERVER_EVENTS: SERVER,
  MEDIA_SOURCES,
} = SignalingEvents;

const log = logger.child({ component: 'signaling' });

/** Room roles from the contract, not tenant roles. */
const MODERATORS = Object.freeze(['host', 'cohost']);
const SCREEN_SOURCES = Object.freeze(['screen', 'screen-audio']);

/* ------------------------------------------------------------------ *
 * Ack plumbing
 * ------------------------------------------------------------------ */

class SignalError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const fail = (code, message) => {
  throw new SignalError(code, message);
};

const roomChannel = (roomId) => `room:${roomId}`;

/* ------------------------------------------------------------------ *
 * Handler table
 * ------------------------------------------------------------------ */

/**
 *   roles   undefined = any peer in the room; array = one of these room roles
 *   cost    token-bucket weight for realtime/socketRateLimit.js
 *   joined  false for events allowed before the peer is in a room
 */
const HANDLERS = [
  { event: CLIENT.join, cost: 5, joined: false, handler: onJoin },
  { event: CLIENT.leave, cost: 1, handler: onLeave },
  { event: CLIENT.createTransport, cost: 4, handler: onTransportCreate },
  { event: CLIENT.connectTransport, cost: 2, handler: onTransportConnect },
  { event: CLIENT.restartIce, cost: 2, handler: onRestartIce },
  { event: CLIENT.produce, cost: 4, handler: onProduce },
  { event: CLIENT.closeProducer, cost: 1, handler: onProducerClose },
  { event: CLIENT.pauseProducer, cost: 1, handler: onProducerPause },
  { event: CLIENT.resumeProducer, cost: 1, handler: onProducerResume },
  { event: CLIENT.consume, cost: 2, handler: onConsume },
  { event: CLIENT.resumeConsumer, cost: 1, handler: onConsumerResume },
  { event: CLIENT.startScreenShare, cost: 4, handler: onScreenShareStart },
  { event: CLIENT.stopScreenShare, cost: 2, handler: onScreenShareStop },
  { event: CLIENT.raiseHand, cost: 1, handler: onRaiseHand },
  { event: CLIENT.react, cost: 1, handler: onReact },
  { event: CLIENT.hostAction, cost: 3, roles: MODERATORS, handler: onHostAction },
  { event: CLIENT.breakout, cost: 5, roles: MODERATORS, handler: onBreakout },
  { event: CLIENT.roomSettings, cost: 2, roles: ['host'], handler: onRoomSettings },
];

/**
 * Attach the `/classroom` namespace.
 *
 * Also installs the room emitter. RoomManager builds every Room with an `emit`
 * that routes through here, which is what keeps classroom/ free of any socket
 * import and prevents a circular dependency — and what makes
 * `room.broadcast(...)` inside ScreenShareManager and ModerationControls
 * actually reach anybody.
 */
export function registerSocketHandlers(io) {
  const namespace = io.of(CLASSROOM_NAMESPACE);

  RoomManager.setEmitter((event, payload, options = {}) => {
    const { roomId, except, only } = options;
    // `only` is a socket id; Socket.IO treats every socket id as a room of one.
    if (only) {
      namespace.to(only).emit(event, payload);
      return;
    }
    const target = except
      ? namespace.to(roomChannel(roomId)).except(except)
      : namespace.to(roomChannel(roomId));
    target.emit(event, payload);
  });

  namespace.on('connection', (socket) => registerSocket(namespace, socket));
  return namespace;
}

function registerSocket(namespace, socket) {
  const ctx = { io: namespace, socket };

  for (const { event, roles, cost = 1, joined = true, handler } of HANDLERS) {
    socket.on(event, async (payload, ack) => {
      const respond = typeof ack === 'function' ? ack : () => {};
      const traceId = socket.data.traceId ?? crypto.randomUUID();
      const startedAt = process.hrtime.bigint();

      try {
        const budget = await consumeSocketBudget({
          socketId: socket.id,
          userId: socket.data.userId ?? socket.data.session?.userId,
          event,
        });
        if (!budget.allowed) fail('rate_limited', 'Too many signalling events');

        const session = socket.data.session ?? null;
        if (joined && !session) fail('not_in_room', 'Join a room first');
        if (joined && roles && !roles.includes(session.peer.role)) {
          fail('forbidden', 'Your role cannot perform this action');
        }

        const data = await handler(ctx, payload ?? {}, session);
        respond({ ok: true, data: data ?? null });
      } catch (error) {
        // Domain modules throw with `code` attached; SignalError carries its
        // own. Anything else is a bug and must not leak its message.
        const code =
          error instanceof SignalError ? error.code : (error?.code ?? 'internal_error');

        if (code === 'internal_error') {
          log.error({ err: error, event, socketId: socket.id, traceId }, 'handler failed');
        } else {
          log.debug({ event, code, traceId }, 'handler rejected');
        }

        respond({
          ok: false,
          error: {
            code,
            message: code === 'internal_error' ? 'Signalling error' : error.message,
            traceId,
          },
        });
      } finally {
        metrics.observe?.(
          'signaling_event_ms',
          Number(process.hrtime.bigint() - startedAt) / 1e6,
          { event },
        );
      }
    });
  }

  socket.on('disconnect', (reason) => {
    teardown(ctx, reason).catch((error) =>
      log.error({ err: error, socketId: socket.id }, 'teardown failed'),
    );
  });
}

/* ------------------------------------------------------------------ *
 * Media for one peer: transports and ICE configuration
 * ------------------------------------------------------------------ */

/**
 * ICE configuration in the contract shape (rtc.schema.ts, IceConfigSchema).
 *
 * The TURN service and IceServerService (F8, section 4) do not exist in this
 * codebase yet, so this hands out STUN only: enough for every client that can
 * reach the SFU directly, and the schema's minimum of one server. When
 * rtc/IceServerService.js lands, it replaces this function and nothing else
 * changes. ICE_DEV_STUN_URL overrides the server, e.g. for an offline lab.
 */
const ICE_TTL_MS = 8 * 60 * 60 * 1000;

function iceConfigFor() {
  const now = Date.now();
  const stunUrl = process.env.ICE_DEV_STUN_URL || 'stun:stun.l.google.com:19302';
  return {
    iceServers: [{ urls: [stunUrl] }],
    iceTransportPolicy: 'all',
    expiresAt: new Date(now + ICE_TTL_MS).toISOString(),
    // 80 % of the TTL, when IceConfigProvider starts refreshing.
    refreshAfter: new Date(now + ICE_TTL_MS * 0.8).toISOString(),
  };
}

/** Closes a peer's transports (optionally one direction); their producers and consumers go with them. */
function closeTransports(peer, direction = null) {
  for (const [id, entry] of peer.transports) {
    if (direction && entry.direction !== direction) continue;
    try {
      entry.transport.close();
    } catch {
      // Already closed with its router.
    }
    peer.transports.delete(id);
  }
}

/**
 * One WebRTC transport for this peer, in the contract shape
 * (TransportOptionsSchema). The mediasoup object stays on the server; only its
 * parameters cross to the client.
 */
async function openTransport(room, peer, direction, forceRelay = false) {
  const { transport, params } = await createWebRtcTransport(room.router, { direction, forceRelay });
  transport.appData = { ...transport.appData, peerId: peer.id, direction };
  peer.addTransport(transport, direction);

  return {
    transportId: params.transportId,
    iceParameters: params.iceParameters,
    iceCandidates: params.iceCandidates,
    dtlsParameters: params.dtlsParameters,
    ...(params.sctpParameters ? { sctpParameters: params.sctpParameters } : {}),
  };
}

/** Send and receive transport plus the ICE configuration, as JoinAckSchema carries them. */
async function openMedia(room, peer, { forceRelay = false } = {}) {
  const [sendTransport, recvTransport] = await Promise.all([
    openTransport(room, peer, 'send', forceRelay),
    openTransport(room, peer, 'recv', forceRelay),
  ]);
  return { sendTransport, recvTransport, ice: iceConfigFor() };
}

/** RoomState for this peer. selfPeerId and mediaRegion are filled if Room does not set them. */
function roomStateFor(room, peer) {
  const state = room.toState(peer.id);
  return {
    ...state,
    selfPeerId: state.selfPeerId ?? peer.id,
    mediaRegion: state.mediaRegion ?? env.MEDIA_REGION ?? null,
  };
}

/* ------------------------------------------------------------------ *
 * Session lifecycle
 * ------------------------------------------------------------------ */

/**
 * @returns {import('@classroom/contracts').SignalingEvents.JoinAck}
 *   { room, sendTransport, recvTransport, ice } — everything the client needs
 *   to start media in one round trip.
 */
async function onJoin({ socket }, payload) {
  const roomId = String(payload.roomId ?? '');
  if (!roomId) fail('invalid_payload', 'roomId is required');

  // SfuClient.rejoinMedia(): same socket, same room, fresh transports. The peer
  // keeps its place, seat and role; only media is rebuilt (after a failed ICE
  // path or a draining node). Closing the old transports closes their
  // producers, which tells the other participants through producerClosed.
  const existing = socket.data.session;
  if (existing) {
    if (!payload.rejoin || existing.roomId !== roomId) {
      fail('already_joined', 'This socket is already in a room');
    }
    closeTransports(existing.peer);
    const media = await openMedia(existing.room, existing.peer, {
      forceRelay: Boolean(payload.forceRelay),
    });
    return { room: roomStateFor(existing.room, existing.peer), ...media };
  }

  // A draining node must not take a room it is not already carrying; the client
  // re-resolves through GET /rooms/:id/node and connects elsewhere.
  const alreadyHere = Boolean(RoomManager.getRoom(roomId));
  if (isDraining() && !alreadyHere) {
    fail('node_draining', 'This node is draining — resolve the room node again');
  }

  // A room lives on exactly one node, because its peers share one router.
  const assignedNodeId = await RoomRegistry.whereIs(roomId);
  if (assignedNodeId && assignedNodeId !== env.SFU_NODE_ID && !alreadyHere) {
    fail('wrong_node', 'This room lives on another SFU node');
  }

  const { userId, tenantId, displayName, avatarUrl } = socket.data;

  const user = {
    userId,
    displayName: payload.displayName ?? displayName,
    avatarUrl: avatarUrl ?? null,
  };

  const seat = await CapacityGuard.reserveSeat({ tenantId, roomId, userId });
  if (!seat.granted) fail('room_full', 'The room is full for this plan');

  let room;
  let peer;
  try {
    room =
      RoomManager.getRoom(roomId) ??
      (await RoomManager.createRoom({
        roomId,
        lessonId: payload.lessonId ?? null,
        hostUserId: userId, // whoever opens the room owns it
      }));

    // Waiting room and lock belong to ModerationControls. A knock allocates no
    // router resources, so a flood of them costs nothing.
    const knocked = ModerationControls.knock(room, { peerId: socket.id, user });

    if (!knocked.admitted) {
      if (knocked.waiting) {
        socket.data.waiting = { roomId, room, since: Date.now() };
        // Joining the channel lets `classroom:waiting.admitted` reach them.
        await socket.join(roomChannel(roomId));
        fail('waiting_room', 'Waiting for a host to admit you');
      }
      fail(knocked.code ?? 'room_locked', knocked.reason ?? 'The room is locked');
    }

    // Room.addPeer takes a constructed Peer, which keeps Room free of any
    // knowledge about sockets or identity.
    peer = room.addPeer(
      new Peer({
        id: socket.id,
        user,
        role: room.hostUserId === userId ? 'host' : 'learner',
        device: payload.device ?? {},
      }),
    );
  } catch (error) {
    await CapacityGuard.releaseSeat({ tenantId, roomId, userId }).catch(() => {});
    throw error;
  }

  // Both transports and the ICE configuration travel in the join ack, before
  // anyone is told this peer exists. If they cannot be created, the join is
  // undone completely: peer, seat and — when it was the only one — the room.
  let media;
  try {
    media = await openMedia(room, peer);
  } catch (error) {
    closeTransports(peer);
    room.removePeer(peer.id, 'disconnected');
    await CapacityGuard.releaseSeat({ tenantId, roomId, userId }).catch(() => {});
    if (room.peerCount === 0) await RoomManager.closeRoom(roomId, 'ended-by-host').catch(() => {});
    throw error;
  }

  socket.data.session = { roomId, room, peer, tenantId, userId, joinedAt: Date.now() };
  socket.data.waiting = null;

  await socket.join(roomChannel(roomId));

  await Promise.resolve(AttendanceService.recordJoin(room, peer)).catch((error) =>
    log.warn({ err: error, roomId }, 'attendance join failed'),
  );

  room.broadcast(SERVER.peerJoined, peer.toJSON(), { except: socket.id });
  metrics.increment?.('classroom_peer_joined', 1, { role: peer.role });

  // JoinAckSchema: the room state (router capabilities, peers, any share in
  // progress) plus both transports and the ICE configuration.
  return { room: roomStateFor(room, peer), ...media };
}

async function onLeave(ctx) {
  await teardown(ctx, 'left');
  return { left: true };
}

async function teardown({ socket }, reason) {
  const waiting = socket.data.waiting;
  if (waiting) {
    waiting.room?.waiting.delete(socket.id);
    socket.data.waiting = null;
  }

  const session = socket.data.session;
  if (!session) return;
  socket.data.session = null;

  const { room, peer, roomId, tenantId, userId } = session;

  // The lock must go before the peer, or it outlives its holder and nobody
  // else in the room can share. releaseForPeer broadcasts the stop itself.
  ScreenShareManager.releaseForPeer(room, peer.id);

  // Room.removePeer broadcasts classroom:peer.left through the injected
  // emitter, so nothing to emit here.
  room.removePeer(peer.id, normaliseLeaveReason(reason));

  await CapacityGuard.releaseSeat({ tenantId, roomId, userId }).catch(() => {});
  await Promise.resolve(AttendanceService.recordLeave(room, peer)).catch((error) =>
    log.warn({ err: error, roomId }, 'attendance leave failed'),
  );

  if (room.peerCount === 0) {
    await RoomManager.closeRoom(roomId, 'ended-by-host').catch(() => {});
  }
  metrics.increment?.('classroom_peer_left', 1, { reason });
}

/** PeerLeftSchema allows exactly these four. */
function normaliseLeaveReason(reason) {
  if (reason === 'left' || reason === 'removed' || reason === 'timeout') return reason;
  return 'disconnected';
}

/* ------------------------------------------------------------------ *
 * Transports
 * ------------------------------------------------------------------ */

/**
 * CreateTransportAckSchema: { transport, ice }. Used by
 * SfuClient.recreateTransports() (for example the relay-only retry). The
 * peer's previous transport in this direction is closed first: the client has
 * already dropped its side, and keeping ours would leak ports and producers.
 */
async function onTransportCreate(_ctx, payload, session) {
  const direction = payload.direction === 'recv' ? 'recv' : 'send';
  closeTransports(session.peer, direction);

  const transport = await openTransport(
    session.room,
    session.peer,
    direction,
    Boolean(payload.forceRelay),
  );
  return { transport, ice: iceConfigFor() };
}

async function onTransportConnect(_ctx, payload, session) {
  const transport = session.peer.getTransport(payload.transportId);
  if (!transport) fail('no_transport', 'Unknown transport');
  await transport.connect({ dtlsParameters: payload.dtlsParameters });
  return { connected: true };
}

/**
 * IceRestartedSchema: { iceParameters }. SfuClient.restartIce() calls this
 * when a path fails; producers and consumers stay, only ICE starts over.
 */
async function onRestartIce(_ctx, payload, session) {
  const transport = session.peer.getTransport(payload.transportId);
  if (!transport) fail('no_transport', 'Unknown transport');
  const iceParameters = await transport.restartIce();
  return { iceParameters };
}

/* ------------------------------------------------------------------ *
 * Producers
 * ------------------------------------------------------------------ */

/** Contract source ('screen-audio') to Peer.js slot name ('screenAudio'). */
const slotOf = (source) => (source === 'screen-audio' ? 'screenAudio' : source);

/**
 * One producer per source. A screen share is a *second* video producer on the
 * same peer, tagged `source: 'screen'` — not a second connection. What differs
 * is the lock, which must already be held before the producer exists.
 */
async function onProduce({ socket }, payload, session) {
  const source = String(payload.source ?? (payload.kind === 'audio' ? 'microphone' : 'camera'));
  if (!MEDIA_SOURCES.includes(source)) {
    fail('invalid_payload', `Unknown producer source: ${source}`);
  }

  if (
    SCREEN_SOURCES.includes(source) &&
    !ScreenShareManager.isSharing(session.roomId, session.peer.id)
  ) {
    fail('no_presenter_lock', 'Request the presenter lock before producing a screen track');
  }

  const transport = session.peer.getTransport(payload.transportId);
  if (!transport) fail('no_transport', 'Unknown transport');

  const producer = await transport.produce({
    kind: payload.kind,
    rtpParameters: payload.rtpParameters,
    appData: {
      ...payload.appData,
      source,
      peerId: session.peer.id,
      userId: session.userId,
    },
  });

  // Peer.addProducer replaces and closes whatever was in the slot, so a client
  // re-producing after a camera switch leaves nothing behind consuming
  // bandwidth for every subscriber.
  session.peer.addProducer(slotOf(source), producer);

  producer.observer.once('close', () => {
    session.room.broadcast(SERVER.producerClosed, { producerId: producer.id });
  });

  session.room.broadcast(
    SERVER.newProducer,
    {
      producerId: producer.id,
      peerId: session.peer.id,
      userId: session.userId,
      kind: producer.kind,
      source,
      paused: producer.paused,
    },
    { except: socket.id },
  );

  // Turns the reserved lock into a live share: it stamps appData, broadcasts
  // classroom:screenShare.started and points the recorder at the new source.
  // Without this call the lock is never confirmed and expires after a minute.
  if (source === 'screen') {
    const attached = ScreenShareManager.attachProducer(session.room, session.peer, producer, {
      label: payload.appData?.label ?? null,
    });
    if (!attached.ok) fail(attached.code ?? 'screen_share_taken', 'Someone else is sharing');
  }

  session.room.broadcast(SERVER.peerUpdated, session.peer.toJSON());
  metrics.increment?.('classroom_producer_created', 1, { source });

  return { producerId: producer.id, source };
}

async function onProducerPause(_ctx, payload, session) {
  const producer = session.peer.findProducer(payload.producerId);
  if (!producer) fail('no_producer', 'Unknown producer');
  await producer.pause();
  session.room.broadcast(SERVER.peerUpdated, session.peer.toJSON());
  return { paused: true };
}

/**
 * NOTE: there is no server-side check here that a host mute is still in force.
 * ModerationControls.mute() pauses the producer but records no flag, so a
 * client that calls resume immediately un-mutes itself. Closing that hole needs
 * a `mutedBy` marker on the peer — deliberately not invented here, because
 * guessing at the shape would put the rule in this file instead of in
 * ModerationControls where it belongs.
 */
async function onProducerResume(_ctx, payload, session) {
  const producer = session.peer.findProducer(payload.producerId);
  if (!producer) fail('no_producer', 'Unknown producer');
  await producer.resume();
  session.room.broadcast(SERVER.peerUpdated, session.peer.toJSON());
  return { paused: false };
}

async function onProducerClose(_ctx, payload, session) {
  const slot = session.peer.sourceOf(payload.producerId);
  if (!slot) return { closed: true };

  if (slot === 'screen') {
    // release() closes the share and broadcasts screenShare.stopped itself.
    ScreenShareManager.release(session.room, session.peer.id, 'stopped');
  } else {
    session.peer.closeProducer(slot);
  }

  session.room.broadcast(SERVER.peerUpdated, session.peer.toJSON());
  return { closed: true };
}

/* ------------------------------------------------------------------ *
 * Consumers
 * ------------------------------------------------------------------ */

async function onConsume(_ctx, payload, session) {
  const { producerId, rtpCapabilities, transportId } = payload;

  if (!session.room.router.canConsume({ producerId, rtpCapabilities })) {
    fail('cannot_consume', 'Incompatible capabilities for this producer');
  }

  const transport = session.peer.getTransport(transportId);
  if (!transport) fail('no_transport', 'Unknown transport');

  const owner = session.room.producerOwner(producerId);
  const slot = owner?.sourceOf(producerId) ?? null;

  const consumer = await transport.consume({
    producerId,
    rtpCapabilities,
    // Resumed by the client once the element is attached, so the first frames
    // are not thrown away before anything can render them.
    paused: true,
  });
  session.peer.addConsumer(consumer);

  return {
    consumerId: consumer.id,
    producerId,
    kind: consumer.kind,
    source: slot === 'screenAudio' ? 'screen-audio' : (slot ?? 'camera'),
    rtpParameters: consumer.rtpParameters,
    producerPaused: consumer.producerPaused,
  };
}

async function onConsumerResume(_ctx, payload, session) {
  const consumer = session.peer.consumers.get(payload.consumerId);
  if (!consumer) fail('no_consumer', 'Unknown consumer');
  await consumer.resume();
  return { paused: false };
}

/* ------------------------------------------------------------------ *
 * Screen share (F1)
 * ------------------------------------------------------------------ */

/**
 * Two steps on purpose: take the lock, then produce. A user who is going to be
 * refused must never see the platform's screen picker first, and a dismissed
 * picker releases the lock again rather than blocking the room.
 *
 * `screenShare.started` is broadcast by attachProducer in onProduce, not here —
 * until a producer exists there is nothing for anyone to consume.
 */
async function onScreenShareStart(_ctx, payload, session) {
  const result = ScreenShareManager.acquire(session.room, session.peer, {
    label: payload.label ?? null,
  });

  if (!result.ok) {
    fail(
      result.code ?? 'screen_share_taken',
      result.reason ?? 'Someone else is sharing their screen',
    );
  }

  metrics.increment?.('classroom_screenshare_started');

  // The client is told what to encode; it does not get to choose. Simulcast
  // off, low frame rate, contentHint 'detail' — text over motion.
  return { granted: true, profile: result.profile };
}

async function onScreenShareStop(_ctx, _payload, session) {
  // Closes the producers and broadcasts screenShare.stopped on its own.
  ScreenShareManager.release(session.room, session.peer.id, 'stopped');
  session.room.broadcast(SERVER.peerUpdated, session.peer.toJSON());
  return { stopped: true };
}

/* ------------------------------------------------------------------ *
 * Interaction (F1)
 * ------------------------------------------------------------------ */

async function onRaiseHand(_ctx, payload, session) {
  const raised = Boolean(payload.raised);

  // The peer object, not its id: HandRaise keeps a queue ordered by when each
  // hand went up, and it needs the peer to record who is in it.
  HandRaise.set(session.room, session.peer, raised);

  session.peer.handRaised = raised;
  session.peer.handRaisedAt = raised ? new Date().toISOString() : null;

  session.room.broadcast(SERVER.handRaised, { peerId: session.peer.id, raised });
  return { raised };
}

/** Ephemeral by design: reactions are never written to the chat history. */
async function onReact(_ctx, payload, session) {
  // Reactions owns both the allowlist and the rate limit — validating here as
  // well would put the same rule in two files and let them disagree.
  const result = Reactions.send(session.room, session.peer, payload.emoji);

  if (result && result.ok === false) {
    fail(result.code ?? 'rate_limited', result.reason ?? 'Slow down on the reactions');
  }

  // Reactions.send has broadcast it already; a second broadcast showed every
  // reaction twice.
  return { sent: true };
}

/* ------------------------------------------------------------------ *
 * Moderation (F1)
 * ------------------------------------------------------------------ */

/**
 * One event, nine actions, one implementation. ModerationControls owns every
 * rule and every broadcast; this handler adds only the two things that need a
 * socket rather than a room: disconnecting a removed peer, and admitting a
 * peer who is not a peer yet.
 */
async function onHostAction({ io }, payload, session) {
  const { targetPeerId, action, reason = null } = payload;
  if (!targetPeerId || !action) fail('invalid_payload', 'targetPeerId and action are required');

  const result = await ModerationControls.applyHostAction(session.room, session.peer, {
    targetPeerId,
    action,
    reason,
  });

  if (action === 'remove') {
    // Disconnect the socket, or it simply keeps its transports open and its
    // media flowing to everyone who is still subscribed.
    const sockets = await io.in(roomChannel(session.roomId)).fetchSockets();
    for (const other of sockets) {
      if (other.id === targetPeerId) other.disconnect(true);
    }
  }

  if (action === 'admit') {
    // The admitted person is still on the waiting screen with no session. The
    // `classroom:waiting.admitted` that ModerationControls sent is their cue to
    // retry the join; nothing else to do here.
    log.debug({ roomId: session.roomId, targetPeerId }, 'peer admitted, awaiting rejoin');
  }

  return { applied: Boolean(result), action, targetPeerId };
}

/* ------------------------------------------------------------------ *
 * Breakout rooms (F1)
 * ------------------------------------------------------------------ */

/**
 * Child rooms are real rooms with `breakoutParent` set. The client leaves and
 * rejoins through the normal join path — no second transport model, no
 * special-cased peer.
 *
 * UNVERIFIED: BreakoutManager's exported surface was not available when this
 * was written. The four calls below follow the contract's BreakoutActionSchema;
 * if the manager names them differently, this is the file to change, not the
 * contract.
 */
async function onBreakout(_ctx, payload, session) {
  switch (payload.action) {
    case 'create':
      return BreakoutManager.create(session.room, {
        groups: payload.groups,
        durationMin: payload.durationMin ?? null,
        by: session.peer.id,
      });

    case 'broadcast': {
      const message = String(payload.message ?? '').trim();
      if (!message) fail('invalid_payload', 'Empty broadcast');
      return BreakoutManager.broadcast(session.room, { message, by: session.peer.id });
    }

    case 'recall':
      return BreakoutManager.recall(session.room, { by: session.peer.id });

    case 'join':
      return BreakoutManager.assign(session.room, {
        peerId: session.peer.id,
        breakoutId: payload.breakoutId,
        by: session.peer.id,
      });

    default:
      return fail('invalid_payload', `Unknown breakout action: ${payload.action}`);
  }
}

/* ------------------------------------------------------------------ *
 * Room settings (host)
 * ------------------------------------------------------------------ */

/** { reactionsEnabled: boolean }. ModerationControls broadcasts the change. */
async function onRoomSettings(_ctx, payload, session) {
  if (typeof payload.reactionsEnabled !== 'boolean') {
    fail('invalid_payload', 'reactionsEnabled must be true or false');
  }
  const reactionsEnabled = ModerationControls.setReactionsEnabled(
    session.room,
    session.peer,
    payload.reactionsEnabled,
  );
  return { reactionsEnabled };
}

export default registerSocketHandlers;
