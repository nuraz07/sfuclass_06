import { readFileSync, writeFileSync } from 'node:fs';

const file = 'server/src/signaling/socketHandlers.js';
let src = readFileSync(file, 'utf8');

if (src.includes('function openMedia(')) {
  console.log('already patched, nothing to do');
  process.exit(0);
}

const edits = [
  {
    name: 'register the ICE restart handler',
    find: '  { event: CLIENT.connectTransport, cost: 2, handler: onTransportConnect },\n',
    replace:
      '  { event: CLIENT.connectTransport, cost: 2, handler: onTransportConnect },\n' +
      '  { event: CLIENT.restartIce, cost: 2, handler: onRestartIce },\n',
  },
  {
    name: 'media helpers: transports, ICE configuration, room state',
    find:
      '/* ------------------------------------------------------------------ *\n' +
      ' * Session lifecycle\n' +
      ' * ------------------------------------------------------------------ */\n',
    replace:
      `/* ------------------------------------------------------------------ *
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
`,
  },
  {
    name: 'join returns JoinAck; rejoin rebuilds media on the same socket',
    find:
      "/** @returns {import('@classroom/contracts').SignalingEvents.RoomState} */\n" +
      'async function onJoin({ socket }, payload) {\n' +
      "  if (socket.data.session) fail('already_joined', 'This socket is already in a room');\n" +
      '\n' +
      "  const roomId = String(payload.roomId ?? '');\n" +
      "  if (!roomId) fail('invalid_payload', 'roomId is required');\n",
    replace:
      `/**
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
`,
  },
  {
    name: 'remove the temporary debug log (it wrote socket.data.auth to the log)',
    find:
      '  // Temporary: shows what actually survives the middleware chain.\n' +
      "  log.info({ keys: Object.keys(socket.data), displayName, auth: socket.data.auth }, 'onJoin socket.data');\n",
    replace: '',
  },
  {
    name: 'open both transports before the peer is announced',
    find:
      '  socket.data.session = { roomId, room, peer, tenantId, userId, joinedAt: Date.now() };\n' +
      '  socket.data.waiting = null;\n',
    replace:
      `  // Both transports and the ICE configuration travel in the join ack, before
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
`,
  },
  {
    name: 'answer in the JoinAck shape',
    find:
      '  // RoomState carries routerRtpCapabilities, the peer list and any share\n' +
      '  // already in progress, so a late joiner needs exactly one round trip.\n' +
      '  return room.toState(peer.id);\n',
    replace:
      '  // JoinAckSchema: the room state (router capabilities, peers, any share in\n' +
      '  // progress) plus both transports and the ICE configuration.\n' +
      '  return { room: roomStateFor(room, peer), ...media };\n',
  },
  {
    name: 'transport.create answers in the CreateTransportAck shape',
    find:
      `async function onTransportCreate(_ctx, payload, session) {
  const direction = payload.direction === 'recv' ? 'recv' : 'send';

  // Returns { transport, params } — the transport stays here, the params are
  // the only thing that crosses to the client.
  const { transport, params } = await createWebRtcTransport(session.room.router, {
    direction,
    forceRelay: Boolean(payload.forceRelay),
  });

  transport.appData = { ...transport.appData, peerId: session.peer.id, direction };
  session.peer.addTransport(transport, direction);

  return {
    ...params,
    // mediasoup-client's createSendTransport/createRecvTransport read \`id\`,
    // and SfuClient passes this object straight through. The contract field is
    // \`transportId\`; both are sent so neither side needs a translation step.
    id: params.transportId,
  };
}
`,
    replace:
      `/**
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
`,
  },
  {
    name: 'ICE restart handler',
    find:
      '  await transport.connect({ dtlsParameters: payload.dtlsParameters });\n' +
      '  return { connected: true };\n' +
      '}\n',
    replace:
      '  await transport.connect({ dtlsParameters: payload.dtlsParameters });\n' +
      '  return { connected: true };\n' +
      '}\n' +
      '\n' +
      '/**\n' +
      ' * IceRestartedSchema: { iceParameters }. SfuClient.restartIce() calls this\n' +
      ' * when a path fails; producers and consumers stay, only ICE starts over.\n' +
      ' */\n' +
      'async function onRestartIce(_ctx, payload, session) {\n' +
      '  const transport = session.peer.getTransport(payload.transportId);\n' +
      "  if (!transport) fail('no_transport', 'Unknown transport');\n" +
      '  const iceParameters = await transport.restartIce();\n' +
      '  return { iceParameters };\n' +
      '}\n',
  },
];

for (const edit of edits) {
  const count = src.split(edit.find).length - 1;
  if (count !== 1) {
    console.error(`"${edit.name}": expected the anchor exactly once, found ${count}. Nothing was changed.`);
    process.exit(1);
  }
}
for (const edit of edits) src = src.replace(edit.find, edit.replace);

writeFileSync(file, src);
console.log('patched', file);
for (const edit of edits) console.log('  -', edit.name);
