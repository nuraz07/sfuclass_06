// server/src/mediasoup/pipe/RouterPipeManager.js
//
// Cascading: lets one room span several routers so a session is not capped by one CPU core or one node.
//
//   Within a node   routers on different workers: mediasoup router.pipeToRouter() (loopback pipe).
//   Across nodes    two PipeTransports, one per node, connected to each other over private IPs with SRTP.
//                   The four-step handshake is driven by the realtime service (signaling/sfuControlClient.js
//                   → pipeProducer), which calls these RPCs on both nodes:
//
//        origin node                                 edge node
//        1. pipe.open            → { ip, port, srtp }
//                                                     2. pipe.open            → { ip, port, srtp }
//        3. pipe.connect (edge tuple)                 3. pipe.connect (origin tuple)
//        4. pipe.consume(producerId) → rtpParameters
//                                                     5. pipe.produce(producerId, rtpParameters)
//
//   The producer on the edge node keeps the ORIGIN producer id, so consumers on any node reference the same
//   id and signalling does not need to translate ids.
//
// One pipe per (room, peer node) pair is reused for every producer of that room. Closing the room closes
// its pipes; a pipe that fails (DTLS/SRTP or remote node gone) is closed and reported so the realtime
// service can re-pipe or move the edge.
//
// Owner: F1 Live Classrooms. Used by sfu-node/rpcHandlers.js and classroom/RoomManager.js.

import { EventEmitter } from 'node:events';
import { randomUUID } from 'node:crypto';

export class RouterPipeManager extends EventEmitter {
  /**
   * @param {object} options
   * @param {import('./pipeTransportFactory.js').PipeTransportFactory} options.pipeTransportFactory
   * @param {{ info: Function, warn: Function }} [options.logger]
   */
  constructor({ pipeTransportFactory, logger = console }) {
    super();
    if (!pipeTransportFactory) throw new TypeError('RouterPipeManager: pipeTransportFactory is required');
    this.#factory = pipeTransportFactory;
    this.#logger = logger;
  }

  #factory;
  #logger;
  /** @type {Map<string, { pipeId: string, roomId: string, peerNode: string, transport: any }>} */
  #pipes = new Map();
  /** @type {Map<string, string>} `${roomId}|${peerNode}` → pipeId */
  #byPeer = new Map();

  // ------------------------------------------------------------------ within one node

  /**
   * Makes `producerId` of `fromRouter` available on `toRouter` (different worker, same node).
   * Idempotent: mediasoup reuses the existing pipe pair and rejects duplicates, which is treated as success.
   */
  async pipeWithinNode({ producerId, fromRouter, toRouter }) {
    if (fromRouter.id === toRouter.id) return;
    try {
      await fromRouter.pipeToRouter({ producerId, router: toRouter });
    } catch (err) {
      if (!/already exists/i.test(err?.message ?? '')) throw err;
    }
  }

  // ------------------------------------------------------------------ across nodes

  /**
   * Step 1/2: creates (or reuses) the local end of the pipe towards `peerNode` for `roomId`.
   * @returns {Promise<{ pipeId: string, ip: string, port: number, srtpParameters: object, reused: boolean }>}
   */
  async open({ roomId, router, peerNode }) {
    const key = `${roomId}|${peerNode}`;
    const existing = this.#byPeer.get(key);
    if (existing) {
      const pipe = this.#pipes.get(existing);
      return { pipeId: pipe.pipeId, ...this.#localTuple(pipe.transport), reused: true };
    }

    const pipeId = randomUUID();
    const transport = await this.#factory.create(router, { roomId, peerNode, pipeId });
    const pipe = { pipeId, roomId, peerNode, transport };
    this.#pipes.set(pipeId, pipe);
    this.#byPeer.set(key, pipeId);

    transport.observer.once('close', () => this.#forget(pipe, 'closed'));
    router.observer.once('close', () => transport.close());
    this.#logger.info({ roomId, peerNode, pipeId }, 'pipe transport opened');
    return { pipeId, ...this.#localTuple(transport), reused: false };
  }

  /** Step 3: points the local end at the remote end. Safe to call again with the same tuple. */
  async connect({ pipeId, ip, port, srtpParameters }) {
    const pipe = this.#get(pipeId);
    const tuple = pipe.transport.tuple;
    if (tuple?.remoteIp === ip && tuple?.remotePort === port) return;
    await pipe.transport.connect({ ip, port, srtpParameters });
  }

  /** Step 4 (origin): consumes a local producer into the pipe. */
  async consume({ pipeId, producerId }) {
    const pipe = this.#get(pipeId);
    const consumer = await pipe.transport.consume({ producerId });
    consumer.observer.once('close', () => this.emit('pipeConsumerClosed', { roomId: pipe.roomId, pipeId, producerId }));
    return {
      kind: consumer.kind,
      rtpParameters: consumer.rtpParameters,
      paused: consumer.producerPaused,
      appData: consumer.appData,
    };
  }

  /** Step 5 (edge): re-creates the origin producer on this node with the same id. */
  async produce({ pipeId, producerId, kind, rtpParameters, paused, appData }) {
    const pipe = this.#get(pipeId);
    const producer = await pipe.transport.produce({
      id: producerId,
      kind,
      rtpParameters,
      paused,
      appData: { ...appData, pipedFrom: pipe.peerNode },
    });
    return producer;
  }

  /** Closes every pipe of a room (room closed or moved). */
  closeRoom(roomId) {
    for (const pipe of [...this.#pipes.values()]) {
      if (pipe.roomId === roomId) pipe.transport.close();
    }
  }

  closePipe(pipeId) {
    this.#pipes.get(pipeId)?.transport.close();
  }

  stats() {
    return { pipes: this.#pipes.size };
  }

  #localTuple(transport) {
    const { localAddress, localIp, localPort } = transport.tuple;
    return { ip: localAddress ?? localIp, port: localPort, srtpParameters: transport.srtpParameters };
  }

  #get(pipeId) {
    const pipe = this.#pipes.get(pipeId);
    if (!pipe) {
      const err = new Error(`pipe ${pipeId} not found`);
      err.code = 'PIPE_NOT_FOUND';
      err.status = 404;
      throw err;
    }
    return pipe;
  }

  #forget(pipe, reason) {
    this.#pipes.delete(pipe.pipeId);
    this.#byPeer.delete(`${pipe.roomId}|${pipe.peerNode}`);
    this.emit('pipeClosed', { roomId: pipe.roomId, pipeId: pipe.pipeId, peerNode: pipe.peerNode, reason });
  }
}