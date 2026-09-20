// classroom-app/server/src/security/piiRedaction.js
/**
 * Log redaction  (F7, F8)  [EXT]
 *
 * One place that decides what never reaches CloudWatch. logger.js installs
 * `redactPaths` in pino and runs `scrub()` over anything structured; auditLog.js
 * runs the same scrub over its metadata, so a log line and an audit record hide
 * the same things.
 *
 * Version 7 adds the media plane:
 *
 *   ICE candidates    a candidate line is an address. `candidate:… 192.0.2.7
 *                     54321 typ srflx raddr …` tells you where a learner sits,
 *                     which network they are on and often which school. They
 *                     are replaced by their type, which is the only part worth
 *                     debugging with (host · srflx · prf · relay).
 *   Client IPs        kept as a network prefix, never as an address. /24 and
 *                     /48 are enough to tell "same campus" from "somewhere
 *                     else" in an incident, and identify nobody.
 *   TURN credentials  the username is already pseudonymous, the credential is
 *                     an HMAC that is valid for hours. Both go.
 *
 * The rule is the same one as everywhere else: log what you need to debug the
 * system, not what you need to identify the person using it.
 */

const REDACTED = '[redacted]';

/**
 * Structural paths for pino's own redaction. Fast, but only for known shapes —
 * scrub() below handles everything else.
 */
export const redactPaths = Object.freeze([
  // --- credentials and tokens ---------------------------------------------
  'req.headers.authorization',
  'req.headers.cookie',
  'res.headers["set-cookie"]',
  'password',
  '*.password',
  'token',
  '*.token',
  'accessToken',
  'refreshToken',
  '*.secret',
  'dtlsParameters',

  // --- identity -----------------------------------------------------------
  'email',
  '*.email',
  'user.email',
  'phone',
  '*.phone',

  // --- media plane (F8) ---------------------------------------------------
  'ice.iceServers[*].username',
  'ice.iceServers[*].credential',
  'iceServers[*].username',
  'iceServers[*].credential',
  'credential',
  '*.credential',
  'iceCandidates',
  '*.iceCandidates',
  'candidate',
  '*.candidate',
  'remoteCandidate',
  'localCandidate',

  // --- addresses ----------------------------------------------------------
  'req.remoteAddress',
  'req.headers["x-forwarded-for"]',
]);

// ---------------------------------------------------------------------------
// Addresses
// ---------------------------------------------------------------------------

const IPV4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;

/**
 * Keeps the network, drops the host: 203.0.113.42 → 203.0.113.0/24,
 * 2001:db8:1:2::7 → 2001:db8:1::/48. Unparseable input is dropped entirely
 * rather than guessed at.
 */
export const maskIp = (value) => {
  if (typeof value !== 'string' || value.length === 0) return null;
  const address = value.trim().replace(/^\[|\]$/g, '').split('%')[0];

  const v4 = address.match(IPV4);
  if (v4) {
    const octets = v4.slice(1).map(Number);
    if (octets.some((octet) => octet > 255)) return REDACTED;
    return `${octets[0]}.${octets[1]}.${octets[2]}.0/24`;
  }

  if (address.includes(':')) {
    const groups = address.split(':').filter(Boolean).slice(0, 3);
    if (groups.length === 0) return REDACTED;
    return `${groups.join(':')}::/48`;
  }

  return REDACTED;
};

/**
 * Behind the ALB the client address is the leftmost X-Forwarded-For entry; the
 * rest are load balancer hops and carry nothing worth keeping.
 */
export const maskForwardedFor = (header) => {
  if (typeof header !== 'string') return null;
  const [client] = header.split(',');
  return maskIp(client);
};

// ---------------------------------------------------------------------------
// ICE
// ---------------------------------------------------------------------------

const CANDIDATE_TYPE = /\btyp\s+(host|srflx|prflx|relay)\b/;

/**
 * A candidate becomes its type. `candidate:1 1 udp 2113937151 192.0.2.7 54321
 * typ srflx …` → `typ:srflx`. Everything that identifies a network is gone,
 * and rtcStats.ts still gets the one field an ICE incident is debugged with.
 */
export const scrubIceCandidate = (candidate) => {
  if (candidate == null) return null;

  if (typeof candidate === 'string') {
    const type = candidate.match(CANDIDATE_TYPE)?.[1];
    return type ? `typ:${type}` : REDACTED;
  }

  if (typeof candidate === 'object') {
    const type = candidate.type ?? candidate.candidateType ?? null;
    return {
      type: type ?? 'unknown',
      protocol: candidate.protocol ?? null,
      // Relay candidates come from a TURN node we operate, so the node name is
      // ours to log; it identifies no one.
      relayProtocol: candidate.relayProtocol ?? null,
    };
  }

  return REDACTED;
};

export const scrubIceCandidates = (candidates) =>
  Array.isArray(candidates) ? candidates.map(scrubIceCandidate) : REDACTED;

/** What an ICE configuration may look like in a log: shape, never credentials. */
export const summariseIceConfig = (ice) => {
  if (!ice || typeof ice !== 'object') return null;
  const servers = Array.isArray(ice.iceServers) ? ice.iceServers : [];
  return {
    policy: ice.iceTransportPolicy ?? null,
    urls: servers.flatMap((server) => (Array.isArray(server.urls) ? server.urls : [])).length,
    // Hostnames are our own TURN nodes and are useful during an incident.
    hosts: [
      ...new Set(
        servers
          .flatMap((server) => (Array.isArray(server.urls) ? server.urls : []))
          .map((url) => String(url).replace(/^\w+:/, '').split(/[:?]/)[0]),
      ),
    ],
    expiresAt: ice.expiresAt ?? null,
  };
};

// ---------------------------------------------------------------------------
// Generic scrub
// ---------------------------------------------------------------------------

const SENSITIVE_KEY =
  /^(password|secret|token|credential|authorization|cookie|apiKey|privateKey|dtlsParameters|sdp|email|phone)$/i;
const IP_KEY = /^(ip|clientIp|remoteAddress|address|announcedIp|publicIp|privateIp|relayIp)$/i;
const CANDIDATE_KEY = /candidate/i;

const MAX_DEPTH = 6;

/**
 * Deep copy with the sensitive parts removed. Used on anything that did not
 * come from a known shape: audit metadata, error context, socket payloads.
 */
export const scrub = (value, depth = 0) => {
  if (value === null || value === undefined) return value;
  if (depth > MAX_DEPTH) return REDACTED;

  if (Array.isArray(value)) return value.slice(0, 50).map((entry) => scrub(entry, depth + 1));

  if (value instanceof Error) {
    return { name: value.name, message: value.message, code: value.code ?? null };
  }

  if (typeof value === 'object') {
    const output = {};
    for (const [key, entry] of Object.entries(value)) {
      if (SENSITIVE_KEY.test(key)) {
        output[key] = REDACTED;
      } else if (CANDIDATE_KEY.test(key)) {
        output[key] = Array.isArray(entry) ? scrubIceCandidates(entry) : scrubIceCandidate(entry);
      } else if (IP_KEY.test(key)) {
        output[key] = maskIp(entry);
      } else if (key === 'iceServers') {
        output[key] = summariseIceConfig({ iceServers: entry });
      } else {
        output[key] = scrub(entry, depth + 1);
      }
    }
    return output;
  }

  return value;
};

export const piiRedaction = Object.freeze({
  redactPaths,
  scrub,
  maskIp,
  maskForwardedFor,
  scrubIceCandidate,
  scrubIceCandidates,
  summariseIceConfig,
  REDACTED,
});

export default piiRedaction;