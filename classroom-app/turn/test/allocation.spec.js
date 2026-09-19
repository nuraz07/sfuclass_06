// turn/test/allocation.spec.js
//
// Proves that the API, the TURN agent and coturn agree end to end. Runs with the Node.js test runner:
//
//   npm test --workspace @classroom/turn-agent                      contract tests only (no network)
//   npm run test:integration --workspace @classroom/turn-agent      + integration tests against a running coturn
//
// Integration target: the dev coturn of docker-compose.dev.yml (same image and bootstrap as production, with
// TURN_ADDRESS_SOURCE=static, TURN_SECRET_SOURCE=env, TURN_TLS_SOURCE=selfsigned). CI runs it in ci.yml.
//
//   TURN_TEST_HOST            127.0.0.1         address coturn listens on
//   TURN_TEST_PORT            3478
//   TURN_TEST_TLS_PORT        5349              TURN over TLS (443 in production)
//   TURN_TEST_TLS_SERVERNAME  turn-dev-01.rtc.test
//   TURN_TEST_TLS_CA          path to the dev certificate (runtime volume tls/fullchain.pem)
//   TURN_TEST_SECRET          TURN_SECRET_DEV of the dev coturn
//   TURN_TEST_PREVIOUS_SECRET TURN_SECRET_DEV_PREVIOUS (optional: rotation acceptance)
//   TURN_TEST_EXTERNAL_IP     the address coturn announces (TURN_PUBLIC_IP)
//   TURN_TEST_RELAY_MIN/MAX   49152 / 65535
//
// Owner: F8 Real-Time Connectivity.

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { sign, TurnCredentialIssuer } from '../../server/src/rtc/TurnCredentialIssuer.js';
import { TurnSecretRing } from '../../server/src/rtc/TurnSecretRing.js';
import { turnRegistryKeys as serverKeys, turnNodeRecordSchema } from '../../server/src/rtc/TurnPoolRegistry.js';
import { TurnClient, StunError, signTurnCredential, mintProbeCredential, DENIED_PROBE_PEERS } from '../agent/src/selfProbe.js';
import { TurnHeartbeat, turnRegistryKeys as agentKeys } from '../agent/src/heartbeat.js';

const here = dirname(fileURLToPath(import.meta.url));
const vectors = JSON.parse(readFileSync(join(here, 'rest-credential.vectors.json'), 'utf8'));
const env = process.env;

// ------------------------------------------------------------------ contract (always runs)

describe('TURN REST credentials: shared vectors', () => {
  for (const v of vectors.vectors) {
    test(`API issuer matches vector: ${v.name}`, () => {
      assert.equal(sign(Buffer.from(v.secret, 'utf8'), v.username), v.credential);
    });
    test(`TURN agent matches vector: ${v.name}`, () => {
      assert.equal(signTurnCredential(v.secret, v.username), v.credential);
    });
  }

  test('issuer output verifies with the previous secret during rotation', async () => {
    const [a, b] = vectors.vectors.filter((v) => v.username === vectors.vectors[0].username).map((v) => v.secret);
    const ring = await new TurnSecretRing({ staticSecrets: { current: b, previous: a } }).start();
    const issuer = new TurnCredentialIssuer({ secretRing: ring });
    const username = `${Math.floor(Date.now() / 1000) + 600}:Zk3Jd9pQ1xWmA7rT0bYc2e`;
    const legacy = sign(Buffer.from(a, 'utf8'), username);
    assert.equal(issuer.verify(username, legacy).valid, true);
  });
});

describe('TURN registry contract (agent writes, API reads)', () => {
  test('keys are identical on both sides', () => {
    for (const fn of ['node', 'index', 'drain']) {
      assert.equal(agentKeys[fn]('eu-central-1', 'turn-euc1-07'), serverKeys[fn]('eu-central-1', 'turn-euc1-07'));
    }
  });

  test('heartbeat record passes the API schema', () => {
    const heartbeat = new TurnHeartbeat({
      redis: null,
      node: {
        node: 'turn-euc1-07', region: 'eu-central-1', az: 'eu-central-1b', hostname: 'turn-euc1-07.rtc.example.com',
        publicIpv4: '3.120.10.7', publicIpv6: null, maxAllocations: 4000, capacityMbps: 12500,
      },
      getLoad: () => ({ allocations: 312, relayMbps: 842.4567 }),
      isHealthy: () => true,
      isDraining: () => false,
      version: 'a'.repeat(40),
    });
    const parsed = turnNodeRecordSchema.safeParse(heartbeat.record());
    assert.equal(parsed.success, true, JSON.stringify(parsed.error?.issues));
  });
});

// ------------------------------------------------------------------ integration (TURN_TEST_INTEGRATION=1)

const integration = env.TURN_TEST_INTEGRATION === '1';
const host = env.TURN_TEST_HOST ?? '127.0.0.1';
const port = Number(env.TURN_TEST_PORT ?? 3478);
const tlsPort = Number(env.TURN_TEST_TLS_PORT ?? 5349);
const secret = env.TURN_TEST_SECRET;
const relayMin = Number(env.TURN_TEST_RELAY_MIN ?? 49152);
const relayMax = Number(env.TURN_TEST_RELAY_MAX ?? 65535);

async function issuerFor(current, previous) {
  const ring = await new TurnSecretRing({ staticSecrets: { current, previous } }).start();
  return new TurnCredentialIssuer({ secretRing: ring });
}

/** A client credential exactly as the API issues it. */
async function apiCredential(sec = secret, ttlSeconds = 600) {
  const issuer = await issuerFor(sec);
  const { username, credential } = issuer.issue({ opaqueId: 'Zk3Jd9pQ1xWmA7rT0bYc2e', ttlSeconds });
  return { username, password: credential };
}

async function withClient(transport, fn) {
  const options = transport === 'tls'
    ? { transport, host, port: tlsPort, servername: env.TURN_TEST_TLS_SERVERNAME, ca: env.TURN_TEST_TLS_CA ? readFileSync(env.TURN_TEST_TLS_CA) : undefined }
    : { transport, host, port };
  const client = await TurnClient.connect(options);
  try {
    return await fn(client);
  } finally {
    client.close();
  }
}

describe('coturn integration', { skip: !integration && 'set TURN_TEST_INTEGRATION=1 (needs the dev coturn)' }, () => {
  test('configuration present', () => {
    assert.ok(secret, 'TURN_TEST_SECRET is required');
  });

  test('STUN binding works without credentials', () =>
    withClient('udp', async (client) => {
      const { mapped } = await client.binding();
      assert.ok(mapped.address);
    }));

  test('allocation with an API-issued credential over UDP', () =>
    withClient('udp', async (client) => {
      const allocation = await client.allocate(await apiCredential());
      assert.ok(allocation.relayed.port >= relayMin && allocation.relayed.port <= relayMax, 'relay port inside range');
      if (env.TURN_TEST_EXTERNAL_IP) assert.equal(allocation.relayed.address, env.TURN_TEST_EXTERNAL_IP, 'announces the external IP');
      await client.refresh(0);
    }));

  test('allocation over TCP and over TLS', async () => {
    for (const transport of ['tcp', 'tls']) {
      if (transport === 'tls' && !env.TURN_TEST_TLS_SERVERNAME) continue;
      await withClient(transport, async (client) => {
        const allocation = await client.allocate(await apiCredential());
        assert.ok(allocation.relayed.address, `${transport} relayed address`);
        await client.refresh(0);
      });
    }
  });

  test('previous secret still accepted (rotation phases 1–2)', { skip: !env.TURN_TEST_PREVIOUS_SECRET && 'no previous secret configured' }, () =>
    withClient('udp', async (client) => {
      const allocation = await client.allocate(await apiCredential(env.TURN_TEST_PREVIOUS_SECRET));
      assert.ok(allocation.relayed.address);
      await client.refresh(0);
    }));

  test('agent probe credential accepted', () =>
    withClient('udp', async (client) => {
      const allocation = await client.allocate(mintProbeCredential({ secret, node: 'turn-dev-01' }));
      assert.ok(allocation.relayed.address);
      await client.refresh(0);
    }));

  test('wrong credential rejected with 401', () =>
    withClient('udp', async (client) => {
      const { username } = await apiCredential();
      await assert.rejects(client.allocate({ username, password: 'not-the-credential' }), (err) => err instanceof StunError && err.code === 401);
    }));

  test('expired credential rejected with 401', () =>
    withClient('udp', async (client) => {
      const expired = `${Math.floor(Date.now() / 1000) - 60}:Zk3Jd9pQ1xWmA7rT0bYc2e`;
      await assert.rejects(
        client.allocate({ username: expired, password: signTurnCredential(secret, expired) }),
        (err) => err instanceof StunError && err.code === 401,
      );
    }));

  test('permission for a public peer granted, denied peers refused with 403', () =>
    withClient('udp', async (client) => {
      await client.allocate(await apiCredential());
      await client.createPermission('1.1.1.1');
      for (const peer of [...DENIED_PROBE_PEERS, '172.16.0.1', '192.168.1.1', '169.254.170.2', '0.0.0.1']) {
        await assert.rejects(client.createPermission(peer), (err) => err instanceof StunError && err.code === 403, `peer ${peer} must be denied`);
      }
      await client.refresh(0);
    }));
});