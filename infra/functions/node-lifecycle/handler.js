// infra/functions/node-lifecycle/handler.js
//
// Lifecycle of SFU and TURN nodes in one media region (deployed by infra/modules/node-lifecycle, one function per
// region, triggered by EventBridge rules for the Auto Scaling lifecycle hooks of both pools and a 5-minute schedule).
//
//   launch (EC2 Instance-launch Lifecycle Action)
//     1. take a free Elastic IP of the pool (infra/media-edge/eip-pool.tf) — the lowest free slot, so node names stay
//        compact — and associate it with the instance; this replaces the transient auto-assigned public IP
//     2. tag the instance so its bootstrap can trust the address (read through IMDS instance tags):
//          TURN  TurnNodeName · TurnHostname · TurnPublicIp     (turn/bootstrap/render-config.sh waits for these)
//          SFU   SfuSlot · SfuPublicIp                           (server/src/config/publicAddress.js waits for these)
//     3. complete the hook (CONTINUE); on failure (no free address) ABANDON, so the ASG replaces the instance
//
//   terminate (EC2 Instance-terminate Lifecycle Action)
//     – instance runs no ECS task any more (blue/green retired colour, failed boot): complete at once (CONTINUE)
//     – otherwise set the drain flag media:drain:<node> in the state Redis; the node drains itself and completes the
//       hook when its sessions ended (turn/agent/src/drain.js, server/src/lifecycle/drainSfu.js), sending hook
//       heartbeats meanwhile. The hook's own timeout (default CONTINUE) is the safety net.
//
//   schedule (every 5 min) and after every event: publish Classroom/MediaEdge FreeEips {Region, Pool} (EMF) for the
//   eip_pool_exhausted alarms.
//
// Prefix lists and DNS are NOT touched at runtime: with pre-allocated pools they are static (media-edge/prefix-lists.tf,
// dns.tf), so a node replacement never changes what customers allowlist or what DNS answers.
//
// Environment (set by infra/modules/node-lifecycle):
//   POOLS                       JSON { sfu: {...}, turn: {...} } with
//                               asgName, launchHookName, terminateHookName, allocationIds[], nodeTags, drainTimeoutMinutes
//   ECS_CLUSTER                 cluster of this region
//   REDIS_URL_SECRET_ARN        state Redis URL (regional replica)
//   REDIS_CLUSTER               "true" for cluster-mode Redis
//   METRICS_NAMESPACE           Classroom/MediaEdge
//   AWS_REGION                  set by Lambda
//
// Owner: F8 Real-Time Connectivity.

import { EC2Client, DescribeAddressesCommand, AssociateAddressCommand, CreateTagsCommand, DescribeInstancesCommand, waitUntilInstanceRunning } from '@aws-sdk/client-ec2';
import { AutoScalingClient, CompleteLifecycleActionCommand } from '@aws-sdk/client-auto-scaling';
import { ECSClient, ListContainerInstancesCommand, DescribeContainerInstancesCommand } from '@aws-sdk/client-ecs';
import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import { Redis, Cluster } from 'ioredis';

const LAUNCH = 'EC2 Instance-launch Lifecycle Action';
const TERMINATE = 'EC2 Instance-terminate Lifecycle Action';

export function log(level, msg, fields = {}) {
  console.log(JSON.stringify({ level, service: 'node-lifecycle', msg, ...fields }));
}

export function loadPools(raw = process.env.POOLS) {
  const pools = JSON.parse(raw ?? '{}');
  for (const [kind, pool] of Object.entries(pools)) {
    for (const field of ['asgName', 'launchHookName', 'terminateHookName', 'allocationIds']) {
      if (!pool[field]) throw new Error(`POOLS.${kind}.${field} is required`);
    }
  }
  return pools;
}

/**
 * @param {object} deps  injected for tests; defaults are the real AWS clients
 */
export function createHandler({
  pools = loadPools(),
  region = process.env.AWS_REGION,
  cluster = process.env.ECS_CLUSTER,
  namespace = process.env.METRICS_NAMESPACE ?? 'Classroom/MediaEdge',
  ec2 = new EC2Client({}),
  autoscaling = new AutoScalingClient({}),
  ecs = new ECSClient({}),
  getRedis = defaultRedis(),
  emit = (line) => console.log(line),
  sleep = (ms) => new Promise((r) => setTimeout(r, ms)),
  waitRunning = (instanceId) => waitUntilInstanceRunning({ client: ec2, maxWaitTime: 180 }, { InstanceIds: [instanceId] }),
} = {}) {
  const poolFor = (asgName) => Object.entries(pools).find(([, p]) => p.asgName === asgName);

  async function addresses(pool) {
    const out = await ec2.send(new DescribeAddressesCommand({ AllocationIds: pool.allocationIds }));
    return (out.Addresses ?? []).map((a) => ({ ...a, tagMap: Object.fromEntries((a.Tags ?? []).map((t) => [t.Key, t.Value])) }))
      .sort((a, b) => (a.tagMap.Slot ?? a.AllocationId).localeCompare(b.tagMap.Slot ?? b.AllocationId));
  }

  async function publishFreeEips(kind, pool) {
    const list = await addresses(pool);
    const free = list.filter((a) => !a.AssociationId).length;
    emit(JSON.stringify({
      _aws: { Timestamp: Date.now(), CloudWatchMetrics: [{ Namespace: namespace, Dimensions: [['Region', 'Pool']], Metrics: [{ Name: 'FreeEips', Unit: 'Count' }, { Name: 'PoolSize', Unit: 'Count' }] }] },
      Region: region, Pool: kind, FreeEips: free, PoolSize: list.length,
    }));
    return free;
  }

  async function complete(detail, result) {
    try {
      await autoscaling.send(new CompleteLifecycleActionCommand({
        AutoScalingGroupName: detail.AutoScalingGroupName,
        LifecycleHookName: detail.LifecycleHookName,
        LifecycleActionToken: detail.LifecycleActionToken,
        InstanceId: detail.EC2InstanceId,
        LifecycleActionResult: result,
      }));
    } catch (err) {
      // Duplicate delivery or hook already completed/timed out: nothing left to do.
      if (/No active Lifecycle Action/i.test(err.message ?? '')) return;
      throw err;
    }
  }

  async function onLaunch(kind, pool, detail) {
    const instanceId = detail.EC2InstanceId;
    let list = await addresses(pool);
    let chosen = list.find((a) => a.InstanceId === instanceId); // idempotent on redelivery

    if (!chosen) {
      await waitRunning(instanceId);
      for (let attempt = 0; attempt < 5 && !chosen; attempt += 1) {
        const free = list.filter((a) => !a.AssociationId);
        if (free.length === 0) break;
        for (const candidate of free) {
          try {
            await ec2.send(new AssociateAddressCommand({ AllocationId: candidate.AllocationId, InstanceId: instanceId, AllowReassociation: false }));
            chosen = candidate;
            break;
          } catch (err) {
            // Another launch took this address a moment earlier: try the next one.
            if (/AlreadyAssociated|InvalidAddress\.InUse/i.test(`${err.name} ${err.message}`)) continue;
            if (/IncorrectInstanceState/i.test(`${err.name} ${err.message}`)) { await sleep(3000); continue; }
            throw err;
          }
        }
        if (!chosen) {
          await sleep(1000 + Math.random() * 2000);
          list = await addresses(pool);
        }
      }
    }

    if (!chosen) {
      log('error', 'no free elastic ip in pool; abandoning launch', { kind, instanceId });
      await complete(detail, 'ABANDON');
      await publishFreeEips(kind, pool);
      return { action: 'abandoned' };
    }

    const publicIp = chosen.PublicIp;
    const tags = pool.nodeTags
      ? [
          { Key: 'TurnNodeName', Value: chosen.tagMap.TurnNodeName },
          { Key: 'TurnHostname', Value: chosen.tagMap.TurnHostname },
          { Key: 'TurnPublicIp', Value: publicIp },
        ]
      : [
          { Key: 'SfuSlot', Value: chosen.tagMap.Slot ?? chosen.AllocationId },
          { Key: 'SfuPublicIp', Value: publicIp },
        ];
    if (tags.some((t) => !t.Value)) throw new Error(`address ${chosen.AllocationId} lacks slot tags`);
    await ec2.send(new CreateTagsCommand({ Resources: [instanceId], Tags: tags }));
    await complete(detail, 'CONTINUE');
    log('info', 'node launched with pool address', { kind, instanceId, publicIp, slot: chosen.tagMap.Slot });
    await publishFreeEips(kind, pool);
    return { action: 'associated', publicIp, slot: chosen.tagMap.Slot };
  }

  async function runningTasks(instanceId) {
    if (!cluster) return 0;
    const list = await ecs.send(new ListContainerInstancesCommand({ cluster, filter: `ec2InstanceId == ${instanceId}` }));
    if (!list.containerInstanceArns?.length) return 0;
    const described = await ecs.send(new DescribeContainerInstancesCommand({ cluster, containerInstances: list.containerInstanceArns }));
    return (described.containerInstances ?? []).reduce((sum, ci) => sum + (ci.runningTasksCount ?? 0), 0);
  }

  async function nodeName(kind, instanceId) {
    if (kind === 'sfu') return `sfu-${region}-${instanceId}`; // server/src/sfu.js nodeId
    const out = await ec2.send(new DescribeInstancesCommand({ InstanceIds: [instanceId] }));
    const tags = out.Reservations?.[0]?.Instances?.[0]?.Tags ?? [];
    return tags.find((t) => t.Key === 'TurnNodeName')?.Value ?? null;
  }

  async function onTerminate(kind, pool, detail) {
    const instanceId = detail.EC2InstanceId;
    const tasks = await runningTasks(instanceId);
    const node = await nodeName(kind, instanceId);
    if (tasks === 0 || !node) {
      log('info', 'nothing to drain; completing terminate hook', { kind, instanceId, tasks, node });
      await complete(detail, 'CONTINUE');
      await publishFreeEips(kind, pool);
      return { action: 'completed' };
    }
    const ttlSeconds = (pool.drainTimeoutMinutes ?? 240) * 60 + 3600;
    const redis = await getRedis();
    await redis.set(`media:drain:${node}`, JSON.stringify({
      reason: /refresh/i.test(detail.NotificationMetadata ?? '') ? 'instance-refresh' : 'scale-in',
      requestedAt: new Date().toISOString(),
      lifecycle: { hookName: detail.LifecycleHookName, autoScalingGroupName: detail.AutoScalingGroupName },
    }), 'EX', ttlSeconds);
    log('info', 'drain flag set; node completes the hook after draining', { kind, instanceId, node, tasks });
    return { action: 'draining', node };
  }

  return async function handler(event) {
    if (event?.['detail-type'] === LAUNCH || event?.['detail-type'] === TERMINATE) {
      const detail = event.detail ?? {};
      const match = poolFor(detail.AutoScalingGroupName);
      if (!match) {
        log('warn', 'event for an unknown auto scaling group', { asg: detail.AutoScalingGroupName });
        return { action: 'ignored' };
      }
      const [kind, pool] = match;
      return event['detail-type'] === LAUNCH ? onLaunch(kind, pool, detail) : onTerminate(kind, pool, detail);
    }
    // Scheduled invocation: refresh the pool metrics.
    const result = {};
    for (const [kind, pool] of Object.entries(pools)) result[kind] = await publishFreeEips(kind, pool);
    return { action: 'metrics', free: result };
  };
}

function defaultRedis() {
  let client;
  const secrets = new SecretsManagerClient({});
  return async () => {
    if (client) return client;
    const out = await secrets.send(new GetSecretValueCommand({ SecretId: process.env.REDIS_URL_SECRET_ARN }));
    let url = out.SecretString;
    if (url.trim().startsWith('{')) url = JSON.parse(url).url;
    const parsed = new URL(url);
    const tls = parsed.protocol === 'rediss:' ? {} : undefined;
    client = process.env.REDIS_CLUSTER === 'true'
      ? new Cluster([{ host: parsed.hostname, port: Number(parsed.port || 6379) }], {
          dnsLookup: (address, cb) => cb(null, address),
          redisOptions: { tls, username: decodeURIComponent(parsed.username) || undefined, password: decodeURIComponent(parsed.password) || undefined },
        })
      : new Redis(url, { tls, maxRetriesPerRequest: 2, connectTimeout: 5000 });
    return client;
  };
}

let handlerInstance;
export const handler = (event) => {
  handlerInstance ??= createHandler();
  return handlerInstance(event);
};