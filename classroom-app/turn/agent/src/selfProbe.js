// turn/agent/src/selfProbe.js
//
// Proves every 10 s that this TURN node really works, the way a client uses it — not just that a port is open:
//
//   UDP 3478   STUN Binding (unauthenticated) → XOR-MAPPED-ADDRESS
//              TURN Allocate with probe credentials (401 challenge → authenticated retry) → XOR-RELAYED-ADDRESS
//              CreatePermission towards a public peer → success
//              CreatePermission towards denied peers (VPC, IMDS, loopback, CGNAT) → must fail with 403
//              Refresh(lifetime 0) → allocation released
//   TLS 443    the same Allocate over TURN-over-TLS, verifying the certificate chain and the node hostname
//
// The result gates everything else: heartbeat.js publishes the node only while the probe passes, and
// healthServer.js reports /healthz from it (ECS replaces the task after repeated failures).
//
// Probe credentials are minted exactly like the API mints client credentials
// (server/src/rtc/TurnCredentialIssuer.js): username "<expiry>:probe-<node>", base64(HMAC-SHA1(secret, username)).
// The signing secret is read from the runtime volume written by bootstrap/render-config.sh.
//
// The STUN/TURN client below (RFC 8489 / RFC 8656 subset) is dependency-free and is reused by
// turn/test/allocation.spec.js, so the integration test and the health probe exercise the same code.
//
// Owner: F8 Real-Time Connectivity.

import dgram from 'node:dgram';
import tls from 'node:tls';
import net from 'node:net';
import { createHash, createHmac, randomBytes } from 'node:crypto';
import { readFile } from 'node:fs/promises';

const MAGIC_COOKIE = 0x2112a442;
const METHOD = { binding: 0x0001, allocate: 0x0003, refresh: 0x0004, createPermission: 0x0008 };
const CLASS = { request: 0x0000, success: 0x0100, error: 0x0110 };
const ATTR = {
  MAPPED_ADDRESS: 0x0001, USERNAME: 0x0006, MESSAGE_INTEGRITY: 0x0008, ERROR_CODE: 0x0009,
  LIFETIME: 0x000d, XOR_PEER_ADDRESS: 0x0012, REALM: 0x0014, NONCE: 0x0015, XOR_RELAYED_ADDRESS: 0x0016,
  REQUESTED_TRANSPORT: 0x0019, XOR_MAPPED_ADDRESS: 0x0020, SOFTWARE: 0x8022, FINGERPRINT: 0x8028,
};
const PROTOCOL_UDP = 17;

export class StunError extends Error {
  constructor(code, reason) {
    super(`STUN error ${code}${reason ? `: ${reason}` : ''}`);
    this.name = 'StunError';
    this.code = code;
    this.reason = reason;
  }
}

// ------------------------------------------------------------------ credentials

/** base64(HMAC-SHA1(secret, username)) — identical to TurnCredentialIssuer.sign(). */
export function signTurnCredential(secret, username) {
  return createHmac('sha1', secret).update(username, 'utf8').digest('base64');
}

/** Short-lived probe credentials for this node. */
export function mintProbeCredential({ secret, node, ttlSeconds = 300, now = Date.now() }) {
  const username = `${Math.floor(now / 1000) + ttlSeconds}:probe-${node}`;
  return { username, password: signTurnCredential(secret, username) };
}

// ------------------------------------------------------------------ message codec

function encodeMessage(type, transactionId, attributes, integrityKey) {
  const parts = [];
  for (const { type: attrType, value } of attributes) parts.push(encodeAttribute(attrType, value));
  let body = Buffer.concat(parts);
  const header = Buffer.alloc(20);
  header.writeUInt16BE(type, 0);
  header.writeUInt32BE(MAGIC_COOKIE, 4);
  transactionId.copy(header, 8);

  if (integrityKey) {
    // RFC 8489 §14.5: HMAC over the message with the length field already covering MESSAGE-INTEGRITY.
    header.writeUInt16BE(body.length + 24, 2);
    const hmac = createHmac('sha1', integrityKey).update(Buffer.concat([header, body])).digest();
    body = Buffer.concat([body, encodeAttribute(ATTR.MESSAGE_INTEGRITY, hmac)]);
  }
  header.writeUInt16BE(body.length, 2);
  return Buffer.concat([header, body]);
}

function encodeAttribute(type, value) {
  const padded = Math.ceil(value.length / 4) * 4;
  const out = Buffer.alloc(4 + padded);
  out.writeUInt16BE(type, 0);
  out.writeUInt16BE(value.length, 2);
  value.copy(out, 4);
  return out;
}

function decodeMessage(buffer) {
  if (buffer.length < 20 || buffer.readUInt32BE(4) !== MAGIC_COOKIE) return null;
  const length = buffer.readUInt16BE(2);
  if (buffer.length < 20 + length) return null;
  const type = buffer.readUInt16BE(0);
  const transactionId = buffer.subarray(8, 20);
  const attributes = new Map();
  let offset = 20;
  while (offset + 4 <= 20 + length) {
    const attrType = buffer.readUInt16BE(offset);
    const attrLength = buffer.readUInt16BE(offset + 2);
    const value = buffer.subarray(offset + 4, offset + 4 + attrLength);
    if (!attributes.has(attrType)) attributes.set(attrType, value);
    offset += 4 + Math.ceil(attrLength / 4) * 4;
  }
  return { type, klass: type & 0x0110, transactionId, attributes };
}

function xorAddress(value, transactionId) {
  const family = value.readUInt8(1);
  const port = value.readUInt16BE(2) ^ (MAGIC_COOKIE >>> 16);
  if (family === 0x01) {
    const address = (value.readUInt32BE(4) ^ MAGIC_COOKIE) >>> 0;
    return { family: 'IPv4', address: [24, 16, 8, 0].map((s) => (address >>> s) & 0xff).join('.'), port };
  }
  const key = Buffer.concat([Buffer.from([0x21, 0x12, 0xa4, 0x42]), transactionId]);
  const bytes = Buffer.alloc(16);
  for (let i = 0; i < 16; i += 1) bytes[i] = value[4 + i] ^ key[i];
  const groups = [];
  for (let i = 0; i < 16; i += 2) groups.push(bytes.readUInt16BE(i).toString(16));
  return { family: 'IPv6', address: groups.join(':'), port };
}

function encodeXorPeer(ip, port) {
  if (!net.isIPv4(ip)) throw new TypeError('probe peers must be IPv4');
  const value = Buffer.alloc(8);
  value.writeUInt8(0x01, 1);
  value.writeUInt16BE(port ^ (MAGIC_COOKIE >>> 16), 2);
  const numeric = ip.split('.').reduce((acc, octet) => ((acc << 8) | Number(octet)) >>> 0, 0);
  value.writeUInt32BE((numeric ^ MAGIC_COOKIE) >>> 0, 4);
  return value;
}

function errorOf(message) {
  const value = message.attributes.get(ATTR.ERROR_CODE);
  if (!value) return new StunError(0, 'error response without ERROR-CODE');
  const code = value.readUInt8(2) * 100 + value.readUInt8(3);
  return new StunError(code, value.subarray(4).toString('utf8'));
}

// ------------------------------------------------------------------ client

export class TurnClient {
  /**
   * @param {{ transport: 'udp'|'tcp'|'tls', host: string, port: number, servername?: string,
   *           ca?: string | Buffer, timeoutMs?: number }} options
   */
  static async connect({ transport, host, port, servername, ca, timeoutMs = 3_000 }) {
    const client = new TurnClient(transport, timeoutMs);
    await client.#open({ host, port, servername, ca });
    return client;
  }

  constructor(transport, timeoutMs) {
    this.transport = transport;
    this.timeoutMs = timeoutMs;
  }

  #socket = null;
  #pending = new Map();
  #buffer = Buffer.alloc(0);
  #auth = null; // { username, realm, nonce, key }
  #host = '';
  #port = 0;

  async #open({ host, port, servername, ca }) {
    this.#host = host;
    this.#port = port;
    if (this.transport === 'udp') {
      this.#socket = dgram.createSocket(net.isIPv6(host) ? 'udp6' : 'udp4');
      this.#socket.on('message', (msg) => this.#dispatch(msg));
      await new Promise((resolve, reject) => {
        this.#socket.once('error', reject);
        this.#socket.bind(0, () => { this.#socket.off('error', reject); resolve(); });
      });
      return;
    }
    const onData = (chunk) => {
      this.#buffer = Buffer.concat([this.#buffer, chunk]);
      while (this.#buffer.length >= 20) {
        const total = 20 + this.#buffer.readUInt16BE(2);
        if (this.#buffer.length < total) break;
        this.#dispatch(this.#buffer.subarray(0, total));
        this.#buffer = this.#buffer.subarray(total);
      }
    };
    this.#socket = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`${this.transport} connect timeout`)), this.timeoutMs);
      const socket = this.transport === 'tls'
        ? tls.connect({ host, port, servername, ca, minVersion: 'TLSv1.2', rejectUnauthorized: true }, () => { clearTimeout(timer); resolve(socket); })
        : net.connect({ host, port }, () => { clearTimeout(timer); resolve(socket); });
      socket.once('error', (err) => { clearTimeout(timer); reject(err); });
    });
    this.#socket.on('data', onData);
    this.#socket.on('error', () => {});
  }

  #dispatch(buffer) {
    const message = decodeMessage(buffer);
    if (!message) return;
    const key = message.transactionId.toString('hex');
    const pending = this.#pending.get(key);
    if (!pending) return;
    this.#pending.delete(key);
    pending.resolve(message);
  }

  #send(buffer, transactionId) {
    return new Promise((resolve, reject) => {
      const key = transactionId.toString('hex');
      const timers = [];
      const finish = (fn, value) => {
        timers.forEach(clearTimeout);
        this.#pending.delete(key);
        fn(value);
      };
      this.#pending.set(key, { resolve: (m) => finish(resolve, m) });
      const write = () => {
        if (this.transport === 'udp') this.#socket.send(buffer, this.#port, this.#host);
        else this.#socket.write(buffer);
      };
      write();
      if (this.transport === 'udp') {
        // RFC 8489 retransmission, compressed to fit the probe timeout.
        for (const at of [250, 750, 1_750]) if (at < this.timeoutMs) timers.push(setTimeout(write, at));
      }
      timers.push(setTimeout(() => finish(reject, new Error(`STUN ${this.transport} timeout after ${this.timeoutMs} ms`)), this.timeoutMs));
    });
  }

  async #request(method, attributes, { authenticated = true } = {}) {
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const transactionId = randomBytes(12);
      const attrs = [...attributes];
      if (authenticated && this.#auth) {
        attrs.push(
          { type: ATTR.USERNAME, value: Buffer.from(this.#auth.username) },
          { type: ATTR.REALM, value: Buffer.from(this.#auth.realm) },
          { type: ATTR.NONCE, value: Buffer.from(this.#auth.nonce) },
        );
      }
      const packet = encodeMessage(method | CLASS.request, transactionId, attrs, authenticated ? this.#auth?.key : undefined);
      const response = await this.#send(packet, transactionId);
      if (response.klass === CLASS.success) return response;
      const error = errorOf(response);
      if (error.code === 438 && this.#auth && attempt === 0) {
        // Stale nonce: take the fresh one and retry once.
        this.#auth.nonce = response.attributes.get(ATTR.NONCE)?.toString('utf8') ?? this.#auth.nonce;
        continue;
      }
      error.response = response;
      throw error;
    }
    throw new StunError(438, 'stale nonce twice');
  }

  /** Unauthenticated Binding; returns the server-reflexive address. */
  async binding() {
    const response = await this.#request(METHOD.binding, [], { authenticated: false });
    const value = response.attributes.get(ATTR.XOR_MAPPED_ADDRESS);
    if (!value) throw new Error('Binding response without XOR-MAPPED-ADDRESS');
    return { mapped: xorAddress(value, response.transactionId) };
  }

  /** Allocate with long-term credentials derived from the TURN REST username/password. */
  async allocate({ username, password, lifetime = 600 }) {
    const attributes = [
      { type: ATTR.REQUESTED_TRANSPORT, value: Buffer.from([PROTOCOL_UDP, 0, 0, 0]) },
      { type: ATTR.LIFETIME, value: uint32(lifetime) },
    ];
    let response;
    try {
      response = await this.#request(METHOD.allocate, attributes, { authenticated: false });
    } catch (err) {
      if (!(err instanceof StunError) || err.code !== 401) throw err;
      const realm = err.response.attributes.get(ATTR.REALM)?.toString('utf8');
      const nonce = err.response.attributes.get(ATTR.NONCE)?.toString('utf8');
      if (!realm || !nonce) throw new Error('401 without REALM/NONCE');
      this.#auth = { username, realm, nonce, key: createHash('md5').update(`${username}:${realm}:${password}`).digest() };
      response = await this.#request(METHOD.allocate, attributes);
    }
    const relayed = response.attributes.get(ATTR.XOR_RELAYED_ADDRESS);
    const mapped = response.attributes.get(ATTR.XOR_MAPPED_ADDRESS);
    if (!relayed) throw new Error('Allocate success without XOR-RELAYED-ADDRESS');
    return {
      realm: this.#auth?.realm ?? null,
      relayed: xorAddress(relayed, response.transactionId),
      mapped: mapped ? xorAddress(mapped, response.transactionId) : null,
      lifetime: response.attributes.get(ATTR.LIFETIME)?.readUInt32BE(0) ?? null,
    };
  }

  async createPermission(peerIp) {
    await this.#request(METHOD.createPermission, [{ type: ATTR.XOR_PEER_ADDRESS, value: encodeXorPeer(peerIp, 0) }]);
  }

  async refresh(lifetime) {
    await this.#request(METHOD.refresh, [{ type: ATTR.LIFETIME, value: uint32(lifetime) }]);
  }

  close() {
    for (const pending of this.#pending.values()) pending.resolve?.({ klass: -1, attributes: new Map() });
    this.#pending.clear();
    if (!this.#socket) return;
    if (this.transport === 'udp') this.#socket.close();
    else this.#socket.destroy();
    this.#socket = null;
  }
}

function uint32(n) {
  const b = Buffer.alloc(4);
  b.writeUInt32BE(n >>> 0, 0);
  return b;
}

// ------------------------------------------------------------------ probe

/** Addresses the relay must refuse (subset of turn/config/denied-peers.conf, one per category). */
export const DENIED_PROBE_PEERS = Object.freeze(['10.0.0.1', '169.254.169.254', '127.0.0.1', '100.64.0.1']);

/**
 * One full probe of one transport. Resolves with timings; rejects with a descriptive error on the first failure.
 */
export async function probeTransport({ transport, host, port, servername, ca, username, password, peerIp, timeoutMs = 3_000 }) {
  const started = performance.now();
  const client = await TurnClient.connect({ transport, host, port, servername, ca, timeoutMs });
  try {
    const binding = transport === 'udp' ? await client.binding() : null;
    const allocation = await client.allocate({ username, password, lifetime: 60 });
    await client.createPermission(peerIp);
    for (const denied of DENIED_PROBE_PEERS) {
      try {
        await client.createPermission(denied);
      } catch (err) {
        if (err instanceof StunError && err.code === 403) continue;
        throw err;
      }
      throw new Error(`relay accepted a permission for denied peer ${denied}`);
    }
    await client.refresh(0);
    return { transport, rttMs: Math.round(performance.now() - started), mapped: binding?.mapped ?? allocation.mapped, relayed: allocation.relayed };
  } finally {
    client.close();
  }
}

export class SelfProbe {
  /**
   * @param {object} options
   * @param {{ node: string, hostname: string, privateIp: string, publicIpv4: string,
   *           ports: { listen: number, tls: number } }} options.node   node.json
   * @param {string} options.secretFile          runtime file with the current signing secret
   * @param {string} [options.peerIp='1.1.1.1']  public peer for the permission test (no traffic is sent)
   * @param {string} [options.caFile]            extra CA (development: the self-signed certificate)
   * @param {number} [options.intervalMs=10000]
   * @param {{ info: Function, warn: Function }} [options.logger]
   */
  constructor({ node, secretFile, peerIp = '1.1.1.1', caFile, intervalMs = 10_000, logger = console }) {
    this.node = node;
    this.secretFile = secretFile;
    this.peerIp = peerIp;
    this.caFile = caFile;
    this.intervalMs = intervalMs;
    this.logger = logger;
    this.state = { ok: false, at: 0, consecutiveFailures: 0, results: [], error: 'not probed yet' };
  }

  #timer = null;
  #running = false;

  start() {
    const loop = async () => {
      await this.runOnce();
      if (this.#running) this.#timer = setTimeout(loop, this.intervalMs);
    };
    this.#running = true;
    loop();
  }

  stop() {
    this.#running = false;
    clearTimeout(this.#timer);
  }

  /** @param {number} maxAgeMs */
  isHealthy(maxAgeMs = this.intervalMs * 3.5) {
    return this.state.ok && Date.now() - this.state.at <= maxAgeMs;
  }

  async runOnce() {
    try {
      const secret = (await readFile(this.secretFile, 'utf8')).trim();
      const ca = this.caFile ? [...tls.rootCertificates, await readFile(this.caFile, 'utf8')] : undefined;
      const { username, password } = mintProbeCredential({ secret, node: this.node.node });
      const common = { username, password, peerIp: this.peerIp, host: this.node.privateIp };
      const results = await Promise.all([
        probeTransport({ ...common, transport: 'udp', port: this.node.ports.listen }),
        probeTransport({ ...common, transport: 'tls', port: this.node.ports.tls, servername: this.node.hostname, ca }),
      ]);
      const relayIp = results[0].relayed.address;
      if (relayIp !== this.node.publicIpv4) throw new Error(`relayed address ${relayIp} is not the node's Elastic IP ${this.node.publicIpv4}`);
      if (!this.state.ok) this.logger.info({ results }, 'turn self-probe passing');
      this.state = { ok: true, at: Date.now(), consecutiveFailures: 0, results, error: null };
    } catch (err) {
      const consecutiveFailures = this.state.consecutiveFailures + 1;
      this.logger.warn({ err: { message: err.message, code: err.code }, consecutiveFailures }, 'turn self-probe failed');
      this.state = { ok: false, at: Date.now(), consecutiveFailures, results: [], error: err.message };
    }
    return this.state;
  }
}