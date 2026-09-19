// infra/functions/turn-secret-rotation/handler.js
//
// Rotates the TURN REST shared secret (Secrets Manager: TURN_SHARED_SECRET, primary in the core region, replicated
// to every media region) in three phases, so that no credential a client holds is ever rejected:
//
//   phase 1 · ACCEPT   create a new version labelled AWSPENDING; refresh every TURN node (deploy-turn.yml via
//                      repository_dispatch "turn-node-refresh"). Nodes now accept {AWSCURRENT, AWSPENDING}; the API
//                      still signs with AWSCURRENT (server/src/rtc/TurnSecretRing.js signs AWSCURRENT only).
//   phase 2 · SIGN     once EVERY registered TURN node in every region accepts a credential signed with the pending
//                      secret (real TURN allocation, not an assumption), move AWSCURRENT to the new version. The old
//                      one becomes AWSPREVIOUS and stays accepted; API tasks pick up the new signing secret within 60 s.
//   phase 3 · RETIRE   after the maximum credential lifetime (24 h) no client can hold an old credential any more:
//                      remove AWSPREVIOUS and refresh the nodes again, which then accept only the new secret.
//
// The phases take hours (node refreshes drain allocations), so this is not a Secrets Manager rotation Lambda with its
// four synchronous steps. It is a small state machine invoked every 15 minutes by EventBridge Scheduler; the state
// lives on the secret itself (version labels + tags), so invocations are idempotent and a failed run simply retries on
// the next tick. Invoke with {"action": "rotate-now"} to start a rotation outside the interval, or
// {"action": "emergency"} to promote and retire immediately (kills every outstanding credential: incident use only,
// ops/runbooks/rotate-secrets.md).
//
// Environment:
//   TURN_SECRET_ARN               primary secret ARN
//   ROTATION_INTERVAL_DAYS        30
//   MIN_ACCEPT_MINUTES            15    minimum time between phase 1 and phase 2 (nodes finish refreshing)
//   RETIRE_AFTER_HOURS            24    = ICE_CREDENTIAL_MAX_TTL_S
//   REDIS_URL_SECRET_ARN          state Redis (TURN registry of all regions)
//   MEDIA_REGIONS                 eu-central-1,us-east-1,ap-southeast-1
//   GITHUB_DISPATCH_SECRET_ARN    {"token": "...", "repository": "owner/classroom-app"} — fine-grained token with
//                                 "Contents: read and write" on the repository (needed for repository_dispatch)
//
// Owner: F8 Real-Time Connectivity (+ security review).

import { randomBytes, createHmac } from 'node:crypto';
import {
  SecretsManagerClient, DescribeSecretCommand, GetSecretValueCommand, PutSecretValueCommand,
  UpdateSecretVersionStageCommand, TagResourceCommand,
} from '@aws-sdk/client-secrets-manager';
import { Redis, Cluster } from 'ioredis';
import { TurnClient } from '../../../turn/agent/src/selfProbe.js';

const TAG_PHASE = 'turn-rotation:phase';
const TAG_PENDING_SINCE = 'turn-rotation:pending-since';
const TAG_PROMOTED_AT = 'turn-rotation:promoted-at';

export function log(level, msg, fields = {}) {
  console.log(JSON.stringify({ level, service: 'turn-secret-rotation', msg, ...fields }));
}

/** 48 base64url characters (288 bits): inside the charset coturn configs and render-config.sh accept. */
export function generateSecret() {
  return randomBytes(36).toString('base64url');
}

export function sign(secret, username) {
  return createHmac('sha1', secret).update(username, 'utf8').digest('base64');
}

function secretValue(secretString) {
  if (secretString.trim().startsWith('{')) return JSON.parse(secretString).secret;
  return secretString;
}

export function createHandler({
  secretId = process.env.TURN_SECRET_ARN,
  intervalDays = Number(process.env.ROTATION_INTERVAL_DAYS ?? 30),
  minAcceptMinutes = Number(process.env.MIN_ACCEPT_MINUTES ?? 15),
  retireAfterHours = Number(process.env.RETIRE_AFTER_HOURS ?? 24),
  regions = (process.env.MEDIA_REGIONS ?? '').split(',').map((s) => s.trim()).filter(Boolean),
  secrets = new SecretsManagerClient({}),
  listTurnNodes = defaultListTurnNodes(),
  probeNode = defaultProbeNode,
  refreshNodes = defaultRefreshNodes(),
  now = () => Date.now(),
} = {}) {
  async function state() {
    const d = await secrets.send(new DescribeSecretCommand({ SecretId: secretId }));
    const stages = d.VersionIdsToStages ?? {};
    const find = (label) => Object.keys(stages).find((id) => stages[id].includes(label)) ?? null;
    const tags = Object.fromEntries((d.Tags ?? []).map((t) => [t.Key, t.Value]));
    return {
      arn: d.ARN,
      current: find('AWSCURRENT'),
      pending: find('AWSPENDING'),
      previous: find('AWSPREVIOUS'),
      tags,
      lastChanged: d.LastChangedDate ? new Date(d.LastChangedDate).getTime() : 0,
    };
  }

  const tag = (entries) => secrets.send(new TagResourceCommand({
    SecretId: secretId,
    Tags: Object.entries(entries).map(([Key, Value]) => ({ Key, Value: String(Value) })),
  }));

  async function valueOf(versionId) {
    const out = await secrets.send(new GetSecretValueCommand({ SecretId: secretId, VersionId: versionId }));
    return secretValue(out.SecretString);
  }

  async function startRotation(s, reason) {
    const token = `rot-${now()}`; // ClientRequestToken doubles as the version id
    await secrets.send(new PutSecretValueCommand({
      SecretId: secretId,
      ClientRequestToken: token,
      SecretString: JSON.stringify({ secret: generateSecret() }),
      VersionStages: ['AWSPENDING'],
    }));
    await tag({ [TAG_PHASE]: 'accept', [TAG_PENDING_SINCE]: new Date(now()).toISOString() });
    await refreshNodes('secret-rotation');
    log('info', 'phase 1: pending secret created, node refresh requested', { reason, version: token });
    return { phase: 'accept', started: true };
  }

  /** Every registered TURN node in every region must accept the pending secret. */
  async function allNodesAccept(pendingSecret) {
    const nodes = await listTurnNodes(regions);
    if (nodes.length === 0) return { ok: false, reason: 'no TURN nodes registered' };
    const username = `${Math.floor(now() / 1000) + 300}:rotation-check`;
    const credential = { username, password: sign(pendingSecret, username) };
    const results = await Promise.all(nodes.map(async (node) => {
      try {
        await probeNode(node, credential);
        return { node: node.node, ok: true };
      } catch (err) {
        return { node: node.node, ok: false, error: err.code ?? err.message };
      }
    }));
    const failing = results.filter((r) => !r.ok);
    return { ok: failing.length === 0, checked: results.length, failing };
  }

  async function promote(s) {
    await secrets.send(new UpdateSecretVersionStageCommand({
      SecretId: secretId, VersionStage: 'AWSCURRENT', MoveToVersionId: s.pending, RemoveFromVersionId: s.current,
    }));
    await secrets.send(new UpdateSecretVersionStageCommand({
      SecretId: secretId, VersionStage: 'AWSPENDING', RemoveFromVersionId: s.pending,
    }));
    await tag({ [TAG_PHASE]: 'retire-wait', [TAG_PROMOTED_AT]: new Date(now()).toISOString() });
    log('info', 'phase 2: new secret is AWSCURRENT; old one kept as AWSPREVIOUS', { current: s.pending, previous: s.current });
  }

  async function retire(s) {
    await secrets.send(new UpdateSecretVersionStageCommand({
      SecretId: secretId, VersionStage: 'AWSPREVIOUS', RemoveFromVersionId: s.previous,
    }));
    await tag({ [TAG_PHASE]: 'idle' });
    await refreshNodes('secret-rotation');
    log('info', 'phase 3: previous secret retired, node refresh requested', { retired: s.previous });
  }

  return async function handler(event = {}) {
    const action = event.action ?? 'tick';
    const s = await state();
    const phase = s.tags[TAG_PHASE] ?? 'idle';

    if (action === 'emergency') {
      if (!s.pending) {
        await startRotation(s, 'emergency');
        return handler({ action: 'emergency-continue' });
      }
      await promote(s);
      const after = await state();
      if (after.previous) await retire(after);
      log('warn', 'emergency rotation completed: every outstanding TURN credential is now invalid');
      return { phase: 'idle', emergency: true };
    }
    if (action === 'emergency-continue' && s.pending) {
      await promote(s);
      const after = await state();
      if (after.previous) await retire(after);
      return { phase: 'idle', emergency: true };
    }

    // Phase 1 → 2
    if (s.pending) {
      const since = Date.parse(s.tags[TAG_PENDING_SINCE] ?? '') || s.lastChanged;
      if (now() - since < minAcceptMinutes * 60_000) return { phase: 'accept', waiting: 'minimum accept time' };
      const check = await allNodesAccept(await valueOf(s.pending));
      if (!check.ok) {
        log('info', 'phase 1: waiting until every TURN node accepts the pending secret', check);
        return { phase: 'accept', waiting: 'nodes', ...check };
      }
      await promote(s);
      return { phase: 'retire-wait', promoted: true, checked: check.checked };
    }

    // Phase 2 → 3
    if (s.previous && phase === 'retire-wait') {
      const promotedAt = Date.parse(s.tags[TAG_PROMOTED_AT] ?? '') || s.lastChanged;
      if (now() - promotedAt < retireAfterHours * 3_600_000) return { phase: 'retire-wait', waiting: 'credential lifetime' };
      await retire(s);
      return { phase: 'idle', retired: true };
    }

    // Idle → phase 1
    const age = now() - (Date.parse(s.tags[TAG_PROMOTED_AT] ?? '') || s.lastChanged);
    if (action === 'rotate-now' || age >= intervalDays * 86_400_000) return startRotation(s, action);
    return { phase: 'idle', nextRotationInDays: Math.ceil((intervalDays * 86_400_000 - age) / 86_400_000) };
  };
}

// ------------------------------------------------------------------ defaults

function defaultListTurnNodes() {
  let redis;
  return async (regions) => {
    redis ??= await connectRedis();
    const nodes = [];
    for (const region of regions) {
      const index = `media:turn:{${region}}:index`;
      const names = await redis.zrangebyscore(index, Date.now() - 15_000, '+inf');
      if (names.length === 0) continue;
      const records = await redis.mget(...names.map((n) => `media:turn:{${region}}:node:${n}`));
      for (const raw of records) if (raw) nodes.push(JSON.parse(raw));
    }
    return nodes;
  };
}

async function defaultProbeNode(node, credential) {
  const client = await TurnClient.connect({ transport: 'udp', host: node.publicIpv4, port: 3478, timeoutMs: 4000 });
  try {
    await client.allocate({ ...credential, lifetime: 60 });
    await client.refresh(0);
  } finally {
    client.close();
  }
}

function defaultRefreshNodes() {
  const secrets = new SecretsManagerClient({});
  return async (reason) => {
    const out = await secrets.send(new GetSecretValueCommand({ SecretId: process.env.GITHUB_DISPATCH_SECRET_ARN }));
    const { token, repository } = JSON.parse(out.SecretString);
    const res = await fetch(`https://api.github.com/repos/${repository}/dispatches`, {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, accept: 'application/vnd.github+json', 'x-github-api-version': '2022-11-28' },
      body: JSON.stringify({ event_type: 'turn-node-refresh', client_payload: { reason } }),
      signal: AbortSignal.timeout(10_000),
    });
    if (res.status !== 204) throw new Error(`repository_dispatch failed with HTTP ${res.status}`);
  };
}

async function connectRedis() {
  const secrets = new SecretsManagerClient({});
  const out = await secrets.send(new GetSecretValueCommand({ SecretId: process.env.REDIS_URL_SECRET_ARN }));
  let url = out.SecretString;
  if (url.trim().startsWith('{')) url = JSON.parse(url).url;
  const parsed = new URL(url);
  const tls = parsed.protocol === 'rediss:' ? {} : undefined;
  return process.env.REDIS_CLUSTER === 'true'
    ? new Cluster([{ host: parsed.hostname, port: Number(parsed.port || 6379) }], {
        dnsLookup: (address, cb) => cb(null, address),
        redisOptions: { tls, username: decodeURIComponent(parsed.username) || undefined, password: decodeURIComponent(parsed.password) || undefined },
      })
    : new Redis(url, { tls, maxRetriesPerRequest: 2, connectTimeout: 5000 });
}

let handlerInstance;
export const handler = (event) => {
  handlerInstance ??= createHandler();
  return handlerInstance(event);
};