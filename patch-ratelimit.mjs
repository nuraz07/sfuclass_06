import { readFileSync, writeFileSync } from 'node:fs';

const file = 'server/src/middleware/rateLimit.js';
let src = readFileSync(file, 'utf8');

if (src.includes('FALLBACK_SOCKET_LIMITS')) {
  console.log('already patched, nothing to do');
  process.exit(0);
}

const docAnchor = '/**\n * The socket equivalent, used by realtime/socketRateLimit.js.';
const oldLines =
  '  const perEvent = rateLimitConfig.socket.perEvent[event];\n' +
  '  const capacity = perEvent ?? rateLimitConfig.socket.maxEventsPerMinute;';

if (!src.includes(docAnchor) || !src.includes(oldLines)) {
  console.error('expected code not found, file left unchanged');
  process.exit(1);
}

const fallback = `/**
 * Socket limits for a process that serves sockets without being the realtime
 * role. config/rateLimit.config.js builds \`socket\` only for SERVICE_ROLE
 * realtime; in development the api process hosts the socket gateways as well,
 * and without this every socket event failed on \`null.perEvent\`.
 * Same numbers as the realtime role: SOCKET_MAX_EVENTS_PER_MIN, else 240.
 */
const FALLBACK_SOCKET_LIMITS = Object.freeze({
  maxEventsPerMinute: Number(process.env.SOCKET_MAX_EVENTS_PER_MIN) || 240,
  perEvent: Object.freeze({}),
});

`;

src = src
  .replace(docAnchor, fallback + docAnchor)
  .replace(
    oldLines,
    '  const socketLimits = rateLimitConfig.socket ?? FALLBACK_SOCKET_LIMITS;\n' +
      '  const perEvent = socketLimits.perEvent?.[event];\n' +
      '  const capacity = perEvent ?? socketLimits.maxEventsPerMinute;',
  );

writeFileSync(file, src);
console.log('patched', file);
