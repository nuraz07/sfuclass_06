/**
 * Live events for the signed-in person  (Settings, Phase B)
 *
 * The server sends per-person events (server/src/realtime/userEvents.js) on
 * the app's socket:
 *
 *   notification:new    a bell entry arrived        { notification, unread }
 *   settings:changed    changed on another device   { section, fields }
 *   session:revoked     this device was signed out  { reason }
 *
 * The socket object the core exposes has had more than one shape; this finds
 * the one that can listen and returns an unsubscribe function. Without a
 * socket it returns a no-op: the pages still work, they just refresh on focus
 * instead of live.
 */

const candidatesOf = (core) => {
  const socket = core?.socket ?? core?.socketClient ?? null;
  const list = [
    core?.chatSocket,
    core?.sockets?.chat,
    typeof socket?.namespace === 'function' ? safe(() => socket.namespace('/chat')) : null,
    typeof socket?.of === 'function' ? safe(() => socket.of('/chat')) : null,
    typeof socket?.get === 'function' ? safe(() => socket.get('/chat')) : null,
    socket?.chat,
    socket,
  ];
  return list.filter((candidate) => candidate && typeof candidate.on === 'function');
};

function safe(fn) {
  try {
    return fn();
  } catch {
    return null;
  }
}

/** Listens on every socket that can; the server delivers on /chat and /. */
export const onUserEvent = (core, event, handler) => {
  const targets = [...new Set(candidatesOf(core))];
  const offs = targets.map((target) => {
    const result = target.on(event, handler);
    if (typeof result === 'function') return result;
    return () => {
      if (typeof target.off === 'function') target.off(event, handler);
      else if (typeof target.removeListener === 'function') target.removeListener(event, handler);
    };
  });
  return () => offs.forEach((off) => safe(off));
};

export const liveEventsAvailable = (core) => candidatesOf(core).length > 0;
