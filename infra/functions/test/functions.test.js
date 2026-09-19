// infra/functions/test/functions.test.js
//
// Tests of the five media-plane functions with the AWS clients replaced by in-memory fakes (dependency injection
// through createHandler). Integration parts run only when the local services are configured:
//   REDIS_TEST_URL        redis://127.0.0.1:6379       node-lifecycle drain flag, read back by the TURN agent
//   TURN_TEST_HOST        IP of a dev coturn           rotation acceptance probe, canary
//   TURN_TEST_SECRET      its TURN_SECRET_DEV
//   TURN_TEST_HOSTNAME    certificate host name of the dev coturn, TURN_TEST_TLS_PORT, TURN_TEST_TLS_CA
//
// Owner: F8 Real-Time Connectivity.

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Redis } from 'ioredis';
import acme from 'acme-client';

import { createHandler as createLifecycle } from '../node-lifecycle/handler.js';
import { createHandler as createRotation } from '../turn-secret-rotation/handler.js';
import { createHandler as createAcme, inspectCertificate } from '../acme-renewer/handler.js';
import { createHandler as createPublish } from '../publish-ip-ranges/handler.js';
import { runCanary } from '../turn-canary/canary.js';
import { DrainController } from '../../../turn/agent/src/drain.js';

const env = process.env;
const name = (cmd) => cmd.constructor.name;

// ------------------------------------------------------------------ node-lifecycle

function fakeEc2(addresses) {
  const calls = [];
  const state = addresses.map((a) => ({ ...a }));
  return {
    calls, state,
    async send(cmd) {
      calls.push([name(cmd), cmd.input]);
      switch (name(cmd)) {
        case 'DescribeAddressesCommand': return { Addresses: state.map((a) => ({ ...a })) };
        case 'AssociateAddressCommand': {
          const a = state.find((x) => x.AllocationId === cmd.input.AllocationId);
          if (a.AssociationId || a.raceOnce) { a.raceOnce = false; a.AssociationId = 'other'; const e = new Error('address is already associated'); e.name = 'Resource.AlreadyAssociated'; throw e; }
          a.AssociationId = `assoc-${cmd.input.InstanceId}`; a.InstanceId = cmd.input.InstanceId; return {};
        }
        case 'CreateTagsCommand': return {};
        case 'DescribeInstancesCommand': return { Reservations: [{ Instances: [{ Tags: [{ Key: 'TurnNodeName', Value: 'turn-euc1-02' }] }] }] };
        default: throw new Error(`unexpected ${name(cmd)}`);
      }
    },
  };
}
const address = (slot, ip, extra = {}) => ({
  AllocationId: `eipalloc-${slot}`, PublicIp: ip,
  Tags: [{ Key: 'Slot', Value: slot }, { Key: 'TurnNodeName', Value: slot }, { Key: 'TurnHostname', Value: `${slot}.rtc.example.com` }],
  ...extra,
});
const pools = {
  turn: { asgName: 'turn-asg', launchHookName: 'launch', terminateHookName: 'terminate', allocationIds: ['a'], nodeTags: true, drainTimeoutMinutes: 240 },
  sfu: { asgName: 'sfu-asg', launchHookName: 'launch', terminateHookName: 'terminate', allocationIds: ['b'], nodeTags: false },
};
const lifecycleEvent = (type, asg, instance) => ({
  'detail-type': `EC2 Instance-${type} Lifecycle Action`,
  detail: { AutoScalingGroupName: asg, LifecycleHookName: type, LifecycleActionToken: 'tok', EC2InstanceId: instance },
});

describe('node-lifecycle', () => {
  test('launch takes the lowest free slot, survives a race, tags the node, completes CONTINUE', async () => {
    const ec2 = fakeEc2([address('turn-euc1-02', '3.0.0.2'), address('turn-euc1-01', '3.0.0.1', { raceOnce: true }), address('turn-euc1-03', '3.0.0.3')]);
    const asg = []; const metrics = [];
    const handler = createLifecycle({ pools, region: 'eu-central-1', ec2, autoscaling: { send: async (c) => asg.push(c.input) }, ecs: { send: async () => ({}) }, emit: (l) => metrics.push(JSON.parse(l)), waitRunning: async () => {}, sleep: async () => {} });
    const out = await handler(lifecycleEvent('launch', 'turn-asg', 'i-1'));
    assert.equal(out.slot, 'turn-euc1-02', 'slot 01 lost the race, next lowest wins');
    const tags = ec2.calls.find(([n]) => n === 'CreateTagsCommand')[1].Tags;
    assert.deepEqual(Object.fromEntries(tags.map((t) => [t.Key, t.Value])), { TurnNodeName: 'turn-euc1-02', TurnHostname: 'turn-euc1-02.rtc.example.com', TurnPublicIp: '3.0.0.2' });
    assert.equal(asg[0].LifecycleActionResult, 'CONTINUE');
    assert.equal(metrics.at(-1).FreeEips, 1);
    // redelivery: already associated → no second association
    const before = ec2.calls.filter(([n]) => n === 'AssociateAddressCommand').length;
    await handler(lifecycleEvent('launch', 'turn-asg', 'i-1'));
    assert.equal(ec2.calls.filter(([n]) => n === 'AssociateAddressCommand').length, before);
  });

  test('exhausted pool abandons the launch', async () => {
    const ec2 = fakeEc2([address('sfu-euc1-01', '3.0.1.1', { AssociationId: 'x', InstanceId: 'i-9' })]);
    const asg = [];
    const handler = createLifecycle({ pools, region: 'eu-central-1', ec2, autoscaling: { send: async (c) => asg.push(c.input) }, ecs: { send: async () => ({}) }, emit: () => {}, waitRunning: async () => {}, sleep: async () => {} });
    assert.equal((await handler(lifecycleEvent('launch', 'sfu-asg', 'i-2'))).action, 'abandoned');
    assert.equal(asg[0].LifecycleActionResult, 'ABANDON');
  });

  test('terminate without tasks completes at once', async () => {
    const asg = [];
    const handler = createLifecycle({ pools, region: 'eu-central-1', cluster: 'c', ec2: fakeEc2([]), autoscaling: { send: async (c) => asg.push(c.input) }, ecs: { send: async () => ({ containerInstanceArns: [] }) }, emit: () => {} });
    assert.equal((await handler(lifecycleEvent('terminate', 'turn-asg', 'i-3'))).action, 'completed');
    assert.equal(asg[0].LifecycleActionResult, 'CONTINUE');
  });

  test('terminate with running tasks sets a drain flag the TURN agent understands', { skip: !env.REDIS_TEST_URL && 'REDIS_TEST_URL not set' }, async () => {
    const redis = new Redis(env.REDIS_TEST_URL);
    await redis.del('media:drain:turn-euc1-02');
    const ecs = { send: async (c) => (name(c) === 'ListContainerInstancesCommand' ? { containerInstanceArns: ['ci'] } : { containerInstances: [{ runningTasksCount: 2 }] }) };
    const asg = [];
    const handler = createLifecycle({ pools, region: 'eu-central-1', cluster: 'c', ec2: fakeEc2([]), autoscaling: { send: async (c) => asg.push(c.input) }, ecs, getRedis: async () => redis, emit: () => {} });
    assert.equal((await handler(lifecycleEvent('terminate', 'turn-asg', 'i-4'))).action, 'draining');
    assert.equal(asg.length, 0, 'the node completes the hook, not the Lambda');
    assert.ok((await redis.ttl('media:drain:turn-euc1-02')) > 4 * 3600);

    // The agent's DrainController picks up the flag and completes the hook after draining.
    const hookCalls = [];
    const drain = new DrainController({
      redis, node: { node: 'turn-euc1-02', region: 'eu-central-1', instanceId: 'i-4' },
      heartbeat: { leave: async () => {} }, getAllocations: () => 0, pollMs: 20,
      autoScalingClient: async () => ({ send: async (c) => hookCalls.push(c.input) }), logger: { info() {}, warn() {}, error() {} },
    });
    drain.watchFlag();
    await new Promise((r) => setTimeout(r, 200));
    drain.stop();
    assert.deepEqual(hookCalls.at(-1), { LifecycleHookName: 'terminate', AutoScalingGroupName: 'turn-asg', InstanceId: 'i-4', LifecycleActionResult: 'CONTINUE' });
    await redis.del('media:drain:turn-euc1-02');
    redis.disconnect();
  });
});

// ------------------------------------------------------------------ turn-secret-rotation

function fakeSecretsManager(initial) {
  const versions = { v1: { value: JSON.stringify({ secret: initial }), stages: ['AWSCURRENT'] } };
  const tags = {};
  return {
    versions, tags,
    async send(cmd) {
      const i = cmd.input;
      switch (name(cmd)) {
        case 'DescribeSecretCommand': return { ARN: 'arn:s', Tags: Object.entries(tags).map(([Key, Value]) => ({ Key, Value })), VersionIdsToStages: Object.fromEntries(Object.entries(versions).map(([k, v]) => [k, v.stages])) };
        case 'GetSecretValueCommand': return { SecretString: versions[i.VersionId].value };
        case 'PutSecretValueCommand': versions[i.ClientRequestToken] = { value: i.SecretString, stages: i.VersionStages }; return {};
        case 'TagResourceCommand': for (const t of i.Tags) tags[t.Key] = t.Value; return {};
        case 'UpdateSecretVersionStageCommand': {
          if (i.RemoveFromVersionId) versions[i.RemoveFromVersionId].stages = versions[i.RemoveFromVersionId].stages.filter((s) => s !== i.VersionStage);
          if (i.MoveToVersionId) versions[i.MoveToVersionId].stages.push(i.VersionStage);
          if (i.VersionStage === 'AWSCURRENT' && i.RemoveFromVersionId) {
            for (const v of Object.values(versions)) v.stages = v.stages.filter((s) => s !== 'AWSPREVIOUS');
            versions[i.RemoveFromVersionId].stages.push('AWSPREVIOUS');
          }
          return {};
        }
        default: throw new Error(`unexpected ${name(cmd)}`);
      }
    },
  };
}
const labels = (sm) => Object.fromEntries(Object.entries(sm.versions).map(([k, v]) => [k, v.stages.join(',')]));

describe('turn-secret-rotation', () => {
  test('three phases: accept only after every node accepts, retire only after the credential lifetime', async () => {
    let t = Date.parse('2026-09-01T00:00:00Z');
    const sm = fakeSecretsManager('old-secret-0123456789abcdefghijklmnopqrstuv');
    sm.tags['turn-rotation:promoted-at'] = new Date(t - 40 * 86_400_000).toISOString();
    const refreshes = [];
    let nodesAccept = false;
    const handler = createRotation({
      secretId: 's', regions: ['eu-central-1'], secrets: sm, now: () => t,
      listTurnNodes: async () => [{ node: 'turn-euc1-01', publicIpv4: '192.0.2.2' }],
      probeNode: async () => { if (!nodesAccept) { const e = new Error('401'); e.code = 401; throw e; } },
      refreshNodes: async (reason) => refreshes.push(reason),
    });
    assert.equal((await handler()).phase, 'accept');
    const pendingId = Object.keys(sm.versions).find((k) => sm.versions[k].stages.includes('AWSPENDING'));
    assert.match(JSON.parse(sm.versions[pendingId].value).secret, /^[A-Za-z0-9_-]{48}$/);
    assert.deepEqual(refreshes, ['secret-rotation']);
    t += 5 * 60_000; assert.equal((await handler()).waiting, 'minimum accept time');
    t += 15 * 60_000; const waiting = await handler();
    assert.equal(waiting.waiting, 'nodes'); assert.equal(waiting.failing.length, 1);
    assert.ok(labels(sm).v1.includes('AWSCURRENT'), 'API keeps signing with the old secret');
    nodesAccept = true;
    assert.equal((await handler()).promoted, true);
    assert.deepEqual(labels(sm), { v1: 'AWSPREVIOUS', [pendingId]: 'AWSCURRENT' });
    t += 3600_000; assert.equal((await handler()).waiting, 'credential lifetime');
    t += 24 * 3600_000; assert.equal((await handler()).retired, true);
    assert.deepEqual(labels(sm), { v1: '', [pendingId]: 'AWSCURRENT' });
    assert.deepEqual(refreshes, ['secret-rotation', 'secret-rotation']);
    assert.equal((await handler()).phase, 'idle');
  });

  test('real coturn decides acceptance', { skip: !env.TURN_TEST_HOST && 'TURN_TEST_HOST not set' }, async () => {
    const t = Date.now();
    const sm = fakeSecretsManager('old-secret-0123456789abcdefghijklmnopqrstuv');
    const handler = createRotation({
      secretId: 's', regions: ['eu-central-1'], secrets: sm, now: () => t, minAcceptMinutes: 0,
      listTurnNodes: async () => [{ node: 'turn-dev-01', publicIpv4: env.TURN_TEST_HOST }],
      refreshNodes: async () => {},
    });
    await handler({ action: 'rotate-now' });
    const pendingId = Object.keys(sm.versions).find((k) => sm.versions[k].stages.includes('AWSPENDING'));
    assert.equal((await handler()).waiting, 'nodes', 'coturn does not know the new random secret yet');
    sm.versions[pendingId].value = JSON.stringify({ secret: env.TURN_TEST_SECRET }); // as if the node had been refreshed
    assert.equal((await handler()).promoted, true, 'coturn accepted a credential signed with the pending secret');
  });
});

// ------------------------------------------------------------------ acme-renewer

describe('acme-renewer', () => {
  const dir = mkdtempSync(join(tmpdir(), 'acme-'));
  execFileSync('openssl', ['req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256', '-nodes', '-days', '2', '-subj', '/CN=Test CA', '-keyout', join(dir, 'ca.key'), '-out', join(dir, 'ca.pem')], { stdio: 'ignore' });

  function fakeAcme(days) {
    return {
      ...acme,
      Client: class {
        getAccountUrl() { return 'https://acme.test/acct/1'; }
        async auto({ csr, challengeCreateFn, challengeRemoveFn }) {
          const authz = { identifier: { value: 'rtc.example.com' }, wildcard: true };
          await challengeCreateFn(authz, { type: 'dns-01' }, 'key-authorization-digest');
          await challengeRemoveFn(authz, { type: 'dns-01' }, 'key-authorization-digest');
          writeFileSync(join(dir, 'req.csr'), csr);
          writeFileSync(join(dir, 'ext.cnf'), 'subjectAltName=DNS:*.rtc.example.com');
          execFileSync('openssl', ['x509', '-req', '-in', join(dir, 'req.csr'), '-CA', join(dir, 'ca.pem'), '-CAkey', join(dir, 'ca.key'), '-CAcreateserial', '-days', String(days), '-extfile', join(dir, 'ext.cnf'), '-out', join(dir, 'leaf.pem')], { stdio: 'ignore' });
          return readFileSync(join(dir, 'leaf.pem'), 'utf8') + readFileSync(join(dir, 'ca.pem'), 'utf8');
        }
      },
    };
  }

  test('issues via DNS-01, stores the fetch-tls.sh shape, refreshes nodes; skips while valid', async () => {
    const store = {}; const changes = []; const refreshes = []; const metrics = [];
    const secrets = { send: async (c) => {
      if (name(c) === 'GetSecretValueCommand') { if (!store[c.input.SecretId]) { const e = new Error('none'); e.name = 'ResourceNotFoundException'; throw e; } return { SecretString: store[c.input.SecretId] }; }
      store[c.input.SecretId] = c.input.SecretString; return {};
    } };
    const route53 = { send: async (c) => { changes.push(c.input); return name(c) === 'GetChangeCommand' ? { ChangeInfo: { Status: 'INSYNC' } } : { ChangeInfo: { Id: 'c1' } }; } };
    const make = (days) => createAcme({ domain: 'rtc.example.com', hostedZoneId: 'Z1', tlsSecretId: 'tls', accountSecretId: 'acct', email: 'ops@example.com', secrets, route53, acmeLib: fakeAcme(days), refreshNodes: async (r) => refreshes.push(r), emit: (l) => metrics.push(JSON.parse(l)), sleep: async () => {} });

    const first = await make(90)();
    assert.equal(first.renewed, true);
    const txt = changes.find((c) => c.ChangeBatch?.Changes[0].Action === 'UPSERT').ChangeBatch.Changes[0].ResourceRecordSet;
    assert.deepEqual([txt.Name, txt.Type, txt.ResourceRecords[0].Value], ['_acme-challenge.rtc.example.com', 'TXT', '"key-authorization-digest"']);
    assert.ok(changes.some((c) => c.ChangeBatch?.Changes[0].Action === 'DELETE'), 'challenge record removed');
    const stored = JSON.parse(store.tls);
    writeFileSync(join(dir, 'fullchain.pem'), stored.fullchain); writeFileSync(join(dir, 'privkey.pem'), stored.privkey);
    const certPub = execFileSync('bash', ['-c', `openssl x509 -in ${dir}/fullchain.pem -noout -pubkey | openssl sha256`]).toString();
    const keyPub = execFileSync('bash', ['-c', `openssl pkey -in ${dir}/privkey.pem -pubout | openssl sha256`]).toString();
    assert.equal(certPub, keyPub, 'stored key matches the certificate (same check as turn/bootstrap/entrypoint.sh)');
    assert.deepEqual(refreshes, ['tls-renewal']);
    assert.equal(JSON.parse(store.acct).accountUrl, 'https://acme.test/acct/1');
    assert.equal(inspectCertificate(stored.fullchain, 'turn-euc1-07.rtc.example.com').covers, true);

    assert.equal((await make(90)()).renewed, false, 'valid for > 30 days: no renewal');
    assert.ok(metrics.at(-1).CertificateDaysRemaining > 80);
  });
});

// ------------------------------------------------------------------ publish-ip-ranges

describe('publish-ip-ranges', () => {
  test('publishes sorted prefixes with ports and rewrites only on change', async () => {
    const puts = []; let meta = null;
    const ssmPages = [
      { Parameters: [{ Value: JSON.stringify({ region: 'us-east-1', sfu: ['3.1.0.2'], turn: ['3.1.0.9'] }) }], NextToken: 'n' },
      { Parameters: [{ Value: JSON.stringify({ region: 'eu-central-1', sfu: ['3.0.0.10', '3.0.0.2'], turn: ['3.0.0.5'] }) }] },
    ];
    let page = 0;
    const make = () => createPublish({
      path: '/p', bucket: 'b', environment: 'prod', rtcDomain: 'rtc.example.com',
      ssm: { send: async () => ssmPages[page++ % 2] },
      s3: { send: async (c) => {
        if (name(c) === 'HeadObjectCommand') { if (!meta) { const e = new Error('nf'); e.name = 'NotFound'; throw e; } return { Metadata: meta }; }
        puts.push(c.input); meta = c.input.Metadata; return {};
      } },
    });
    const first = await make()();
    assert.equal(first.changed, true);
    const doc = JSON.parse(puts[0].Body);
    assert.deepEqual(doc.prefixes.map((p) => `${p.region} ${p.service} ${p.ip_prefix}`), [
      'eu-central-1 SFU 3.0.0.2/32', 'eu-central-1 SFU 3.0.0.10/32', 'eu-central-1 TURN 3.0.0.5/32',
      'us-east-1 SFU 3.1.0.2/32', 'us-east-1 TURN 3.1.0.9/32',
    ]);
    assert.deepEqual(doc.ports.TURN.map((p) => `${p.protocol}/${p.from}`), ['udp/3478', 'tcp/3478', 'tcp/443']);
    assert.equal(puts[0].CacheControl, 'public, max-age=300');
    assert.equal((await make()()).changed, false);
    assert.equal(puts.length, 1);
  });

  test('refuses to publish an empty list', async () => {
    const handler = createPublish({ path: '/p', bucket: 'b', ssm: { send: async () => ({ Parameters: [] }) }, s3: { send: async () => ({}) } });
    await assert.rejects(handler(), /refusing to publish an empty list/);
  });
});

// ------------------------------------------------------------------ turn-canary

describe('turn-canary', { skip: !env.TURN_TEST_HOST && 'TURN_TEST_HOST not set' }, () => {
  test('allocations over UDP and TLS against every node the regional name returns', async () => {
    const steps = [];
    const out = await runCanary({
      host: env.TURN_TEST_HOSTNAME, realm: 'rtc.test', peerIp: '1.1.1.1', secret: env.TURN_TEST_SECRET,
      resolve: async () => [env.TURN_TEST_HOST],
      ca: readFileSync(env.TURN_TEST_TLS_CA), tlsPort: Number(env.TURN_TEST_TLS_PORT ?? 443),
      step: async (n, fn) => { steps.push(n); return fn(); }, log: { info() {} },
    });
    assert.equal(out.nodes, 1);
    assert.deepEqual(steps, ['resolve-regional-name', `udp-${env.TURN_TEST_HOST}`, `tls-${env.TURN_TEST_HOST}`]);
  });

  test('a wrong secret fails the run', async () => {
    await assert.rejects(runCanary({
      host: env.TURN_TEST_HOSTNAME, realm: 'rtc.test', peerIp: '1.1.1.1', secret: 'wrong-secret-0123456789abcdefghijklmnopqr',
      resolve: async () => [env.TURN_TEST_HOST], ca: readFileSync(env.TURN_TEST_TLS_CA), tlsPort: Number(env.TURN_TEST_TLS_PORT ?? 443), log: { info() {} },
    }), (err) => err.code === 401);
  });
});