// infra/functions/turn-canary/canary.js
//
// CloudWatch Synthetics canary of one media region (infra/modules/connectivity-canary). Runs every minute OUTSIDE the
// VPC, i.e. over the public internet like a real client, against every TURN node the regional name currently answers
// with (turn-<region>.<rtc_domain>, a health-checked multivalue record — media-edge/dns.tf):
//
//   per node, UDP 3478    STUN binding · TURN allocation with a freshly minted REST credential · the relayed address is
//                         the node's Elastic IP · CreatePermission for a public peer · CreatePermission for denied peers
//                         (VPC, instance metadata, loopback, CGNAT) must be refused with 403 · Refresh(0)
//   per node, TLS 443     the same allocation over TURN-over-TLS, verifying chain and host name; fails when the
//                         certificate expires within 7 days
//
// Why no relayed payload: TURN relays only towards SFU addresses (security group of infra/modules/turn-node-pool), so
// a packet relayed to the canary itself is dropped by design. The payload path TURN → SFU is covered by the
// forced-relay call of the post-deploy smoke test (e2e-smoke.yml, ops/scripts/smoke.sh).
//
// A failed step fails the run → Synthetics SuccessPercent drops → alarm <prefix>-turn-canary-<region>, which
// deploy-turn.yml checks before and after every regional deployment.
//
// Environment: TURN_REGIONAL_HOST · TURN_REALM · TURN_SECRET_ARN (regional replica) · PROBE_PEER_IP (default 1.1.1.1)
// Build: bundled with esbuild to CommonJS (Synthetics and SyntheticsLogger stay external); see infra/functions/package.json.
//
// Owner: F8 Real-Time Connectivity.

import { promises as dns } from 'node:dns';
import tls from 'node:tls';
import synthetics from 'Synthetics';
import syntheticsLogger from 'SyntheticsLogger';
import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import { TurnClient, StunError, DENIED_PROBE_PEERS, mintProbeCredential } from '../../../turn/agent/src/selfProbe.js';

const secrets = new SecretsManagerClient({});

async function loadSecret() {
  const out = await secrets.send(new GetSecretValueCommand({ SecretId: process.env.TURN_SECRET_ARN }));
  const raw = out.SecretString;
  return raw.trim().startsWith('{') ? JSON.parse(raw).secret : raw;
}

async function certificateDaysRemaining(host, ip, ca, port = 443) {
  return new Promise((resolve, reject) => {
    const socket = tls.connect({ host: ip, port, servername: host, ca, rejectUnauthorized: true }, () => {
      const cert = socket.getPeerCertificate();
      socket.end();
      resolve(Math.floor((new Date(cert.valid_to).getTime() - Date.now()) / 86_400_000));
    });
    socket.setTimeout(5_000, () => socket.destroy(new Error('TLS handshake timeout')));
    socket.once('error', reject);
  });
}

/** One transport against one node: allocate, permission, denied peers, release. */
export async function probe({ transport, ip, host, credential, peerIp, ca, tlsPort = 443, log = console }) {
  const started = Date.now();
  const client = await TurnClient.connect({
    transport,
    host: ip,
    port: transport === 'tls' ? tlsPort : 3478,
    servername: transport === 'tls' ? host : undefined,
    ca,
    timeoutMs: 4_000,
  });
  try {
    if (transport === 'udp') await client.binding();
    const allocation = await client.allocate({ ...credential, lifetime: 60 });
    if (allocation.relayed.address !== ip) throw new Error(`relayed address ${allocation.relayed.address} is not the node address ${ip}`);
    await client.createPermission(peerIp);
    for (const denied of DENIED_PROBE_PEERS) {
      try {
        await client.createPermission(denied);
      } catch (err) {
        if (err instanceof StunError && err.code === 403) continue;
        throw err;
      }
      throw new Error(`node ${ip} accepted a permission for denied peer ${denied}`);
    }
    await client.refresh(0);
    const ms = Date.now() - started;
    log.info(`${transport} ${ip} ok in ${ms} ms`);
    return ms;
  } finally {
    client.close();
  }
}

export async function runCanary({
  host, realm, peerIp, secret, log = console, step = (name, fn) => fn(),
  resolve = (name) => dns.resolve4(name), ca, tlsPort = 443,
}) {
  const ips = await step('resolve-regional-name', async () => {
    const found = await resolve(host);
    if (found.length === 0) throw new Error(`${host} returned no healthy TURN node`);
    log.info(`${host} → ${found.join(', ')}`);
    return found;
  });
  const credential = mintProbeCredential({ secret, node: 'canary', ttlSeconds: 300 });
  for (const ip of ips) {
    await step(`udp-${ip}`, () => probe({ transport: 'udp', ip, host, credential, peerIp, log }));
    await step(`tls-${ip}`, async () => {
      const days = await certificateDaysRemaining(host, ip, ca, tlsPort);
      if (days < 7) throw new Error(`certificate on ${ip} expires in ${days} days`);
      return probe({ transport: 'tls', ip, host, credential, peerIp, ca, tlsPort, log });
    });
  }
  return { nodes: ips.length, realm };
}

export const handler = async () => {
  const secret = await loadSecret();
  return runCanary({
    host: process.env.TURN_REGIONAL_HOST,
    realm: process.env.TURN_REALM,
    peerIp: process.env.PROBE_PEER_IP ?? '1.1.1.1',
    secret,
    log: syntheticsLogger,
    step: (name, fn) => synthetics.executeStep(name, fn),
  });
};