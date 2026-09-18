// server/src/sfu-node/rpcHandlers.js
//
// The control API of one SFU node. Called only by the realtime service (signaling/sfuControlClient.js)
// through sfu-node/controlServer.js (HTTP/2, mTLS, private IP). Clients never reach this code.
//
// Returns { methods, events }:
//   methods   name → async (params) => result. Every input is validated here; mediasoup validates media
//             parameters again. Errors carry { code, status } and are mapped to HTTP by controlServer.
//   events    EventEmitter; each 'event' is pushed to the realtime service over the /events stream so it
//             can notify clients (e.g. a consumer closed because its producer went away).
//
// Methods
//   room.ensure            { roomId, mode }                          → { routerRtpCapabilities, created }
//   room.close             { roomId, reason }                        → {}
//   peer.leave             { roomId, peerId }                        → {}
//   transport.create       { roomId, peerId, userId, role, direction } → { id, iceParameters, iceCandidates, dtlsParameters }
//   transport.connect      { roomId, peerId, transportId, dtlsParameters } → {}
//   transport.restartIce   { roomId, peerId, transportId }            → { iceParameters }
//   produce                { roomId, peerId, transportId, kind, rtpParameters, source } → { id }
//   producer.pause/resume/close { roomId, peerId, producerId }        → {}
//   consume                { roomId, peerId, transportId, producerId, rtpCapabilities }
//                                                                     → { id, producerId, kind, rtpParameters, type, producerPaused }
//   consumer.resume        { roomId, peerId, consumerId }             → {}
//   consumer.setPreferredLayers { roomId, peerId, consumerId, spatialLayer, temporalLayer? } → {}
//   pipe.open / pipe.connect / pipe.consume / pipe.produce           node-to-node cascading (RouterPipeManager)
//   node.stats             {}                                         → counts for ops tooling
//
// Consumers are always created PAUSED and resumed by the client after it has set up its receiver — the
// mediasoup-recommended order that guarantees the first frame is a key frame.
//
// RoomManager contract (classroom/RoomManager.js, Room.js, Peer.js — extension points of v6 files):
//   roomManager.getRoom(roomId) → Room | undefined
//   roomManager.getOrCreateRoom({ roomId, mode }) → Promise<Room>   picks the least-loaded worker
//   roomManager.closeRoom(roomId, { reason }) · roomCount() · closeAll({ reason })
//   Room: { id, router, webRtcServer, getPeer(peerId), addPeer({ peerId, userId, role }) → Peer, removePeer(peerId) }
//   Peer: { id, userId, role, transports: Map, producers: Map, consumers: Map }
//
// Owner: F1 Live Classrooms (+ F8 for restartIce / transport addressing).

import { EventEmitter } from 'node:events';
import { z } from 'zod';

const id = z.string().min(1).max(128).regex(/^[A-Za-z0-9._:-]+$/);
const plainObject = z.record(z.string(), z.unknown());
const SOURCES = ['mic', 'cam', 'screen', 'screen-audio'];

const schemas = {
  'room.ensure': z.object({ roomId: id, mode: z.enum(['lesson', 'breakout', 'webinar']).default('lesson') }),
  'room.close': z.object({ roomId: id, reason: z.string().max(64).default('closed') }),
  'peer.leave': z.object({ roomId: id, peerId: id }),
  'transport.create': z.object({
    roomId: id, peerId: id, userId: id,
    role: z.enum(['owner', 'teacher', 'learner']),
    direction: z.enum(['send', 'recv']),
  }),
  'transport.connect': z.object({ roomId: id, peerId: id, transportId: id, dtlsParameters: plainObject }),
  'transport.restartIce': z.object({ roomId: id, peerId: id, transportId: id }),
  produce: z.object({
    roomId: id, peerId: id, transportId: id,
    kind: z.enum(['audio', 'video']),
    rtpParameters: plainObject,
    source: z.enum(SOURCES),
    paused: z.boolean().default(false),
  }),
  'producer.pause': z.object({ roomId: id, peerId: id, producerId: id }),
  'producer.resume': z.object({ roomId: id, peerId: id, producerId: id }),
  'producer.close': z.object({ roomId: id, peerId: id, producerId: id }),
  consume: z.object({ roomId: id, peerId: id, transportId: id, producerId: id, rtpCapabilities: plainObject }),
  'consumer.resume': z.object({ roomId: id, peerId: id, consumerId: id }),
  'consumer.setPreferredLayers': z.object({
    roomId: id, peerId: id, consumerId: id,
    spatialLayer: z.number().int().min(0).max(3),
    temporalLayer: z.number().int().min(0).max(3).optional(),
  }),
  'pipe.open': z.object({ roomId: id, peerNode: id }),
  'pipe.connect': z.object({
    pipeId: id,
    ip: z.string().regex(/^\d{1,3}(\.\d{1,3}){3}$/),
    port: z.number().int().min(1).max(65_535),
    srtpParameters: plainObject,
  }),
  'pipe.consume': z.object({ pipeId: id, producerId: id }),
  'pipe.produce': z.object({
    roomId: id, pipeId: id, producerId: id,
    kind: z.enum(['audio', 'video']),
    rtpParameters: plainObject,
    paused: z.boolean(),
    appData: plainObject.default({}),
  }),
  'node.stats': z.object({}).passthrough(),
};

/**
 * @param {object} deps
 * @param {object} deps.roomManager   see contract above
 * @param {import('../mediasoup/pipe/RouterPipeManager.js').RouterPipeManager} deps.pipeManager
 * @param {() => boolean} deps.isAccepting   false while draining: no NEW rooms, existing rooms continue
 * @param {object} [deps.webRtcTransportOptions]  from config/mediasoup.config.js (webRtcTransport)
 * @param {{ info: Function, warn: Function }} [deps.logger]
 * @param {{ increment: Function }} [deps.metrics]
 */
export function createRpcHandlers({ roomManager, pipeManager, isAccepting, webRtcTransportOptions = {}, logger = console, metrics }) {
  if (!roomManager || !pipeManager || typeof isAccepting !== 'function') {
    throw new TypeError('createRpcHandlers: roomManager, pipeManager and isAccepting are required');
  }
  const m = metrics ?? { increment: () => {} };
  const events = new EventEmitter();
  events.setMaxListeners(0);
  const emit = (type, payload) => events.emit('event', { type, ...payload, at: Date.now() });

  pipeManager.on('pipeClosed', (e) => emit('pipe.closed', e));

  const transportOptions = {
    enableUdp: true,
    enableTcp: true,
    preferUdp: true,
    iceConsentTimeout: 30,
    initialAvailableOutgoingBitrate: 1_000_000,
    ...webRtcTransportOptions,
  };
  const { maxIncomingBitrate = 3_000_000 } = webRtcTransportOptions;

  // ---------------------------------------------------------------- lookups
  const room = (roomId) => roomManager.getRoom(roomId) ?? fail('ROOM_NOT_FOUND', `room ${roomId} is not on this node`, 404);
  const peer = (r, peerId) => r.getPeer(peerId) ?? fail('PEER_NOT_FOUND', `peer ${peerId} not in room`, 404);
  const owned = (map, key, what) => map.get(key) ?? fail(`${what.toUpperCase()}_NOT_FOUND`, `${what} ${key} not owned by peer`, 404);

  const closePeer = (r, p, reason) => {
    for (const transport of p.transports.values()) transport.close(); // closes its producers and consumers
    r.removePeer(p.id);
    emit('peer.closed', { roomId: r.id, peerId: p.id, reason });
  };

  /** @type {Record<string, (params: any) => Promise<any>>} */
  const methods = {
    async 'room.ensure'({ roomId, mode }) {
      const existing = roomManager.getRoom(roomId);
      if (!existing && !isAccepting()) fail('NODE_DRAINING', 'node is draining and accepts no new rooms', 503);
      const r = existing ?? (await roomManager.getOrCreateRoom({ roomId, mode }));
      if (!existing) {
        m.increment('sfu.rooms.created', { mode });
        r.router.observer.once('close', () => {
          pipeManager.closeRoom(roomId);
          emit('room.closed', { roomId });
        });
      }
      return { routerRtpCapabilities: r.router.rtpCapabilities, created: !existing };
    },

    async 'room.close'({ roomId, reason }) {
      if (roomManager.getRoom(roomId)) await roomManager.closeRoom(roomId, { reason });
      return {};
    },

    async 'peer.leave'({ roomId, peerId }) {
      const r = roomManager.getRoom(roomId);
      const p = r?.getPeer(peerId);
      if (r && p) closePeer(r, p, 'left');
      return {};
    },

    async 'transport.create'({ roomId, peerId, userId, role, direction }) {
      const r = room(roomId);
      const p = r.getPeer(peerId) ?? r.addPeer({ peerId, userId, role });
      if (p.userId !== userId) fail('PEER_CONFLICT', 'peer id belongs to another user', 409);
      for (const t of p.transports.values()) {
        if (t.appData.direction === direction) fail('TRANSPORT_EXISTS', `peer already has a ${direction} transport`, 409);
      }

      const transport = await r.router.createWebRtcTransport({
        ...transportOptions,
        webRtcServer: r.webRtcServer,
        appData: { peerId, direction },
      });
      if (direction === 'send') await transport.setMaxIncomingBitrate(maxIncomingBitrate);

      p.transports.set(transport.id, transport);
      transport.observer.once('close', () => p.transports.delete(transport.id));
      transport.on('icestatechange', (iceState) => {
        emit('transport.iceState', { roomId, peerId, transportId: transport.id, iceState });
      });
      transport.on('dtlsstatechange', (dtlsState) => {
        if (dtlsState === 'failed' || dtlsState === 'closed') {
          emit('transport.closed', { roomId, peerId, transportId: transport.id, reason: `dtls-${dtlsState}` });
          transport.close();
        }
      });
      m.increment('sfu.transports.created', { direction });

      return {
        id: transport.id,
        iceParameters: transport.iceParameters,
        iceCandidates: transport.iceCandidates,
        dtlsParameters: transport.dtlsParameters,
      };
    },

    async 'transport.connect'({ roomId, peerId, transportId, dtlsParameters }) {
      const p = peer(room(roomId), peerId);
      const transport = owned(p.transports, transportId, 'transport');
      if (transport.dtlsState !== 'new') return {}; // idempotent retry
      await transport.connect({ dtlsParameters });
      return {};
    },

    async 'transport.restartIce'({ roomId, peerId, transportId }) {
      const p = peer(room(roomId), peerId);
      const transport = owned(p.transports, transportId, 'transport');
      const iceParameters = await transport.restartIce();
      m.increment('sfu.ice_restarts');
      return { iceParameters };
    },

    async produce({ roomId, peerId, transportId, kind, rtpParameters, source, paused }) {
      const r = room(roomId);
      const p = peer(r, peerId);
      const transport = owned(p.transports, transportId, 'transport');
      if (transport.appData.direction !== 'send') fail('WRONG_DIRECTION', 'produce requires a send transport', 400);
      const expectedKind = source === 'mic' || source === 'screen-audio' ? 'audio' : 'video';
      if (kind !== expectedKind) fail('KIND_MISMATCH', `source ${source} must be ${expectedKind}`, 400);
      for (const existing of p.producers.values()) {
        if (existing.appData.source === source) fail('SOURCE_EXISTS', `peer already produces ${source}`, 409);
      }

      const producer = await transport.produce({ kind, rtpParameters, paused, appData: { peerId, source } });
      p.producers.set(producer.id, producer);
      producer.observer.once('close', () => {
        p.producers.delete(producer.id);
        emit('producer.closed', { roomId, peerId, producerId: producer.id, source });
      });
      emit('producer.new', { roomId, peerId, producerId: producer.id, kind, source, paused });
      m.increment('sfu.producers.created', { kind, source });
      return { id: producer.id };
    },

    async 'producer.pause'({ roomId, peerId, producerId }) {
      const producer = owned(peer(room(roomId), peerId).producers, producerId, 'producer');
      await producer.pause();
      emit('producer.paused', { roomId, peerId, producerId });
      return {};
    },

    async 'producer.resume'({ roomId, peerId, producerId }) {
      const producer = owned(peer(room(roomId), peerId).producers, producerId, 'producer');
      await producer.resume();
      emit('producer.resumed', { roomId, peerId, producerId });
      return {};
    },

    async 'producer.close'({ roomId, peerId, producerId }) {
      const producer = peer(room(roomId), peerId).producers.get(producerId);
      producer?.close();
      return {};
    },

    async consume({ roomId, peerId, transportId, producerId, rtpCapabilities }) {
      const r = room(roomId);
      const p = peer(r, peerId);
      const transport = owned(p.transports, transportId, 'transport');
      if (transport.appData.direction !== 'recv') fail('WRONG_DIRECTION', 'consume requires a recv transport', 400);
      if (!r.router.canConsume({ producerId, rtpCapabilities })) {
        fail('CANNOT_CONSUME', 'producer unknown on this router or codecs incompatible', 409);
      }

      const consumer = await transport.consume({ producerId, rtpCapabilities, paused: true });
      p.consumers.set(consumer.id, consumer);
      const base = { roomId, peerId, consumerId: consumer.id, producerId };
      consumer.observer.once('close', () => p.consumers.delete(consumer.id));
      consumer.on('producerclose', () => emit('consumer.closed', { ...base, reason: 'producer-closed' }));
      consumer.on('producerpause', () => emit('consumer.producerPaused', base));
      consumer.on('producerresume', () => emit('consumer.producerResumed', base));
      m.increment('sfu.consumers.created', { kind: consumer.kind });

      return {
        id: consumer.id,
        producerId,
        kind: consumer.kind,
        rtpParameters: consumer.rtpParameters,
        type: consumer.type,
        producerPaused: consumer.producerPaused,
      };
    },

    async 'consumer.resume'({ roomId, peerId, consumerId }) {
      const consumer = owned(peer(room(roomId), peerId).consumers, consumerId, 'consumer');
      await consumer.resume();
      return {};
    },

    async 'consumer.setPreferredLayers'({ roomId, peerId, consumerId, spatialLayer, temporalLayer }) {
      const consumer = owned(peer(room(roomId), peerId).consumers, consumerId, 'consumer');
      if (consumer.type === 'simulcast' || consumer.type === 'svc') {
        await consumer.setPreferredLayers({ spatialLayer, temporalLayer });
      }
      return {};
    },

    async 'pipe.open'({ roomId, peerNode }) {
      const r = room(roomId);
      return pipeManager.open({ roomId, router: r.router, peerNode });
    },

    async 'pipe.connect'(params) {
      await pipeManager.connect(params);
      return {};
    },

    async 'pipe.consume'({ pipeId, producerId }) {
      return pipeManager.consume({ pipeId, producerId });
    },

    async 'pipe.produce'({ roomId, pipeId, producerId, kind, rtpParameters, paused, appData }) {
      room(roomId); // the edge room must exist (room.ensure first)
      const producer = await pipeManager.produce({ pipeId, producerId, kind, rtpParameters, paused, appData });
      producer.observer.once('close', () => emit('producer.closed', { roomId, producerId, piped: true }));
      emit('producer.new', { roomId, producerId, kind, source: appData.source, paused, piped: true });
      return { id: producer.id };
    },

    async 'node.stats'() {
      return { rooms: roomManager.roomCount(), accepting: isAccepting(), ...pipeManager.stats() };
    },
  };

  // Validate every call before it reaches mediasoup.
  const validated = Object.fromEntries(
    Object.entries(methods).map(([name, fn]) => [name, async (params) => {
      const parsed = schemas[name].safeParse(params ?? {});
      if (!parsed.success) {
        fail('BAD_REQUEST', parsed.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`).join('; '), 400);
      }
      return fn(parsed.data);
    }]),
  );

  logger.info({ methods: Object.keys(validated).length }, 'sfu rpc handlers ready');
  return { methods: Object.freeze(validated), events };
}

function fail(code, message, status) {
  const err = new Error(message);
  err.code = code;
  err.status = status;
  err.expose = true;
  throw err;
}