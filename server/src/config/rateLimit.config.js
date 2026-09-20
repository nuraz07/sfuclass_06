// classroom-app/server/src/config/rateLimit.config.js
/**
 * Rate limits  (F6, F7, F8)  [EXT]
 *
 * Two budgets, because the two transports fail differently.
 *
 *   HTTP    a token bucket in Redis (state cluster), keyed by user where there
 *           is one and by IP where there is not. Shared across tasks, so
 *           scaling out does not multiply the limit.
 *
 *   Socket  a per-connection event budget. A socket that exceeds it is not
 *           disconnected on the first offence — chat clients legitimately burst
 *           while typing — but a sustained flood ends the connection.
 *
 * Version 7 adds the ICE credential issuance budget: 30 issuances per user per
 * minute, whichever path mints them. It is one named bucket shared by the
 * HTTP route (POST /rtc/ice-servers) and IceServerService on the realtime
 * service (join acknowledgement, transport.create), so a client cannot double
 * its budget by alternating paths.
 *
 * Numbers here are ceilings against abuse, not product limits. Slow mode and
 * the chat rate in .env.example are product decisions and live with the chat
 * domain; these are the last line before someone hurts the cluster.
 *
 * Used by the api and realtime roles only; the SFU and worker never import it.
 */

import { env, serviceRole } from './env.js';

if (serviceRole !== 'api' && serviceRole !== 'realtime') {
  throw new Error(`rateLimit.config.js is not available to the ${serviceRole} role`);
}

/** Default bucket, applied to any route without a more specific rule. */
export const defaultLimit = Object.freeze({
  windowSec: env.RATE_LIMIT_WINDOW_SEC,
  maxPerIp: env.RATE_LIMIT_MAX_PER_IP,
  maxPerUser: env.RATE_LIMIT_MAX_PER_USER,
});

// ---------------------------------------------------------------------------
// ICE credential issuance (F8)
// ---------------------------------------------------------------------------

export const ICE_ISSUANCE_BUCKET = 'ice-issuance';

/**
 * Architecture section 4.5: credentials are issued only to an admitted user
 * and rate-limited to 30 per user per minute. A normal session needs one at
 * join, one per refresh (every ~6.4 h) and at most a few during ICE recovery;
 * thirty is room for a whole family of devices behind one account, not for a
 * credential farm.
 *
 * Counted: POST /rtc/ice-servers, the join acknowledgement and
 * transport.create. Not counted: server-initiated `classroom:ice.update`
 * pushes (TURN node drained, secret rotation) — a client must never be locked
 * out of a replacement it did not ask for.
 */
export const iceIssuanceLimit = Object.freeze({
  bucket: ICE_ISSUANCE_BUCKET,
  windowSec: 60,
  maxPerUser: 30,
  message: 'Too many connection requests. Wait a moment and try again.',
});

// ---------------------------------------------------------------------------
// HTTP routes
// ---------------------------------------------------------------------------

/**
 * Per-route overrides, most specific first. `method` omitted means any.
 *
 * The pattern is a path prefix, not a regex: routes are known at build time
 * and a regex here is a performance trap on a hot path.
 *
 * `bucket` names the Redis bucket explicitly when a limit is shared with a
 * non-HTTP path; without it the prefix is the bucket (see bucketFor).
 */
export const routeLimits = Object.freeze([
  // --- authentication: the classic brute-force surface -------------------
  {
    prefix: '/auth/login',
    method: 'POST',
    windowSec: 300,
    maxPerIp: 10,
    maxPerUser: 10,
    // Counting only failures lets a person with a password manager sign in
    // repeatedly without being locked out.
    countOnly: 'failures',
    message: 'Too many sign-in attempts. Try again in a few minutes.',
  },
  { prefix: '/auth/register', method: 'POST', windowSec: 3_600, maxPerIp: 5 },
  { prefix: '/auth/password/reset', method: 'POST', windowSec: 3_600, maxPerIp: 5 },
  { prefix: '/auth/refresh', method: 'POST', windowSec: 60, maxPerUser: 30 },

  // --- connectivity (F8) --------------------------------------------------
  // Shares its bucket with IceServerService; see iceIssuanceLimit.
  {
    prefix: '/rtc/ice-servers',
    method: 'POST',
    ...iceIssuanceLimit,
    // Authenticated route; the IP ceiling only stops token-less hammering.
    maxPerIp: 120,
  },
  // Region list for ConnectivityProbe; cached client-side.
  { prefix: '/rtc/regions', method: 'GET', windowSec: 60, maxPerUser: 30, maxPerIp: 120 },

  // --- messaging (F6) -----------------------------------------------------
  {
    prefix: '/messaging/messages',
    method: 'POST',
    windowSec: 60,
    maxPerUser: env.CHAT_RATE_PER_MIN,
    message: 'You are sending messages too quickly.',
  },
  // Search is expensive on OpenSearch and trivially scriptable.
  { prefix: '/messaging/search', windowSec: 60, maxPerUser: 30 },
  { prefix: '/community/search', windowSec: 60, maxPerUser: 30 },
  { prefix: '/profiles/search', windowSec: 60, maxPerUser: 120 },

  // --- media (F4) ---------------------------------------------------------
  // Each presign reserves quota and opens a multipart upload, so this is
  // tighter than it looks: a hundred a minute is a lot of open uploads.
  { prefix: '/media/uploads', method: 'POST', windowSec: 60, maxPerUser: 60 },
  { prefix: '/media/assets', method: 'GET', windowSec: 60, maxPerUser: 300 },

  // --- classroom (F1) -----------------------------------------------------
  // Placement arrives in the join ack; clients no longer resolve nodes over
  // HTTP (route-resolve is ops-only). A burst here means something is wrong.
  { prefix: '/rooms', windowSec: 60, maxPerUser: 60 },

  // --- reports and moderation --------------------------------------------
  { prefix: '/profiles/reports', method: 'POST', windowSec: 3_600, maxPerUser: 20 },
  { prefix: '/messaging/reports', method: 'POST', windowSec: 3_600, maxPerUser: 20 },

  // --- webhooks -----------------------------------------------------------
  // Signature-verified and idempotent. Rate limiting them would drop a
  // legitimate provider retry, which is worse than the traffic.
  { prefix: '/billing/webhooks', skip: true },
  { prefix: '/media/webhooks', skip: true },

  // --- health -------------------------------------------------------------
  // The load balancer probes constantly and must never be throttled.
  { prefix: '/healthz', skip: true },
  { prefix: '/readyz', skip: true },
  { prefix: '/startupz', skip: true },
]);

/** Resolves the rule for a request. First match wins. */
export const limitFor = (path, method) => {
  const rule = routeLimits.find(
    (candidate) =>
      path.startsWith(candidate.prefix) && (!candidate.method || candidate.method === method),
  );
  return rule ?? defaultLimit;
};

/** The Redis bucket a rule counts against. */
export const bucketFor = (rule) => rule.bucket ?? rule.prefix ?? 'default';

// ---------------------------------------------------------------------------
// Socket budgets (realtime role)
// ---------------------------------------------------------------------------

/**
 * Built only on the realtime service, which is the only role with a socket
 * server and the only one that receives SOCKET_MAX_EVENTS_PER_MIN.
 */
export const socketLimits =
  serviceRole === 'realtime'
    ? Object.freeze({
        /** Ceiling across every counted event on one connection. */
        maxEventsPerMinute: env.SOCKET_MAX_EVENTS_PER_MIN,

        /**
         * Per-event ceilings, per connection, per minute. Typing is the
         * outlier: it is throttled client-side to one event per few seconds,
         * and a client that ignores that is misbehaving.
         */
        perEvent: Object.freeze({
          'chat:message.send': env.CHAT_RATE_PER_MIN,
          'chat:typing': 30,
          'chat:message.react': 60,
          'chat:read': 60,
          'chat:sync': 10,
          'classroom:react': 30,
          'classroom:hand.raise': 20,
          'classroom:screenShare.start': 10,
          // Each join mints ICE credentials and may trigger placement.
          'classroom:join': 10,
          // Transport rebuilds: a relay retry is two, a recovery loop is many.
          'classroom:transport.create': 20,
          'classroom:transport.restartIce': 20,
          'community:presence.heartbeat': 6,
        }),

        /**
         * Excluded from maxEventsPerMinute. Joining a large room issues one
         * consume and one resume per remote producer; a 150-producer lecture
         * would otherwise trip the connection-wide ceiling on join. These stay
         * bounded by room size, which the server already controls.
         */
        uncountedEvents: Object.freeze(['classroom:consume', 'classroom:consumer.resume']),

        /**
         * Offences tolerated before the connection is closed. Bursts happen on
         * a flaky network when a client replays its outbox; a single overage
         * should cost a rejected event, not a disconnect.
         */
        strikesBeforeDisconnect: 5,
        strikeWindowSec: 60,

        /** Payload ceiling per event, before JSON parsing. */
        maxPayloadBytes: 128 * 1024,

        /** Rooms and channels one connection may subscribe to at once. */
        maxSubscriptions: 200,
      })
    : null;

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

/**
 * A signed-in user is limited as a user wherever they connect from. Everyone
 * else is limited by IP, which behind the ALB means the leftmost entry of
 * X-Forwarded-For — hence TRUST_PROXY, without which every request would look
 * like it came from the load balancer.
 */
export const keyFor = (request) =>
  request.user?.id ? `u:${request.user.id}` : `ip:${request.ip}`;

/** Same key for a socket-originated issuance, so HTTP and socket share a bucket. */
export const keyForUser = (userId) => `u:${userId}`;

export const redisKey = (bucket, key) => `${env.REDIS_PREFIX}:rl:${bucket}:${key}`;

export const rateLimitConfig = Object.freeze({
  default: defaultLimit,
  routes: routeLimits,
  socket: socketLimits,
  iceIssuance: iceIssuanceLimit,
  limitFor,
  bucketFor,
  keyFor,
  keyForUser,
  redisKey,
});

export default rateLimitConfig;