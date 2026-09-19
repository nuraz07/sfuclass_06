// infra/functions/publish-ip-ranges/handler.js
//
// Publishes every public media address of the platform as one machine-readable file, so school and company IT
// departments can allowlist the platform once and automate updates (ops/runbooks/customer-firewall.md):
//
//   https://<media host>/media-ip-ranges.json
//
// Source: one SSM parameter per media region, written by infra/media-edge/prefix-lists.tf in the control-plane region:
//   /<name_prefix>/media/public-ips/<region>   {"region": "...", "sfu": [...], "turn": [...]}
// These are the pre-allocated Elastic IP pools, i.e. every address a node can ever have — not just the running ones —
// so the file only changes when a pool grows or a region is added.
//
// Format (modelled on AWS ip-ranges.json, so existing firewall tooling can read it):
//   { "syncToken": "<unix seconds of the last content change>", "createDate": "YYYY-MM-DD-hh-mm-ss",
//     "environment": "prod", "hostnames": { "turn": "*.rtc.example.com" },
//     "ports": { "SFU": [...], "TURN": [...] },
//     "prefixes": [ { "ip_prefix": "3.120.10.7/32", "region": "eu-central-1", "service": "TURN" }, ... ] }
// The object is only rewritten when the content hash changes (x-amz-meta-content-sha256), so syncToken is stable and
// clients can poll cheaply.
//
// Triggers: EventBridge "Parameter Store Change" for the path, and a daily schedule as a safety net.
//
// Environment:
//   PARAMETER_PATH   /classroom-prod/media/public-ips
//   BUCKET           bucket served by CloudFront (infra/core/cdn.tf)
//   OBJECT_KEY       media-ip-ranges.json
//   ENVIRONMENT      prod
//   RTC_DOMAIN       rtc.example.com
//   SFU_PORT_RANGE   40000-40063
//   CACHE_SECONDS    300
//
// Owner: F8 Real-Time Connectivity.

import { createHash } from 'node:crypto';
import { SSMClient, GetParametersByPathCommand } from '@aws-sdk/client-ssm';
import { S3Client, HeadObjectCommand, PutObjectCommand } from '@aws-sdk/client-s3';

const IPV4 = /^(\d{1,3}\.){3}\d{1,3}$/;

export function log(level, msg, fields = {}) {
  console.log(JSON.stringify({ level, service: 'publish-ip-ranges', msg, ...fields }));
}

/** Pure: builds the document body (without syncToken/createDate) from parameter values. */
export function buildRanges({ parameters, environment, rtcDomain, sfuPortRange }) {
  const [sfuFrom, sfuTo] = sfuPortRange.split('-').map(Number);
  const prefixes = [];
  for (const value of parameters) {
    const entry = JSON.parse(value);
    for (const [service, list] of [['SFU', entry.sfu ?? []], ['TURN', entry.turn ?? []]]) {
      for (const ip of list) {
        if (!IPV4.test(ip)) throw new Error(`invalid address ${ip} in ${entry.region}`);
        prefixes.push({ ip_prefix: `${ip}/32`, region: entry.region, service });
      }
    }
  }
  prefixes.sort((a, b) => a.region.localeCompare(b.region) || a.service.localeCompare(b.service) || a.ip_prefix.localeCompare(b.ip_prefix, 'en', { numeric: true }));
  return {
    environment,
    hostnames: { turn: `*.${rtcDomain}` },
    ports: {
      // What a client network must allow outbound. Relay ports are only used between TURN and SFU nodes.
      SFU: [
        { protocol: 'udp', from: sfuFrom, to: sfuTo, note: 'media, preferred' },
        { protocol: 'tcp', from: sfuFrom, to: sfuTo, note: 'media when UDP is blocked' },
      ],
      TURN: [
        { protocol: 'udp', from: 3478, to: 3478, note: 'STUN and TURN' },
        { protocol: 'tcp', from: 3478, to: 3478, note: 'TURN over TCP' },
        { protocol: 'tcp', from: 443, to: 443, note: 'TURN over TLS; exempt from TLS inspection' },
      ],
    },
    prefixes,
  };
}

export function createHandler({
  path = process.env.PARAMETER_PATH,
  bucket = process.env.BUCKET,
  key = process.env.OBJECT_KEY ?? 'media-ip-ranges.json',
  environment = process.env.ENVIRONMENT,
  rtcDomain = process.env.RTC_DOMAIN,
  sfuPortRange = process.env.SFU_PORT_RANGE ?? '40000-40063',
  cacheSeconds = Number(process.env.CACHE_SECONDS ?? 300),
  ssm = new SSMClient({}),
  s3 = new S3Client({}),
  now = () => Date.now(),
} = {}) {
  async function readParameters() {
    const values = [];
    let NextToken;
    do {
      const out = await ssm.send(new GetParametersByPathCommand({ Path: path, Recursive: false, NextToken }));
      for (const p of out.Parameters ?? []) values.push(p.Value);
      NextToken = out.NextToken;
    } while (NextToken);
    return values;
  }

  async function publishedHash() {
    try {
      const head = await s3.send(new HeadObjectCommand({ Bucket: bucket, Key: key }));
      return head.Metadata?.['content-sha256'] ?? null;
    } catch (err) {
      if (err.name === 'NotFound' || err.$metadata?.httpStatusCode === 404) return null;
      throw err;
    }
  }

  return async function handler() {
    const parameters = await readParameters();
    if (parameters.length === 0) throw new Error(`no media regions published under ${path}; refusing to publish an empty list`);
    const body = buildRanges({ parameters, environment, rtcDomain, sfuPortRange });
    const hash = createHash('sha256').update(JSON.stringify(body)).digest('hex');
    if (hash === (await publishedHash())) {
      log('info', 'address list unchanged', { prefixes: body.prefixes.length });
      return { changed: false, prefixes: body.prefixes.length };
    }
    const date = new Date(now());
    const document = {
      syncToken: String(Math.floor(date.getTime() / 1000)),
      createDate: date.toISOString().replace(/[T:]/g, '-').slice(0, 19),
      ...body,
    };
    await s3.send(new PutObjectCommand({
      Bucket: bucket,
      Key: key,
      Body: `${JSON.stringify(document, null, 2)}\n`,
      ContentType: 'application/json',
      CacheControl: `public, max-age=${cacheSeconds}`,
      ChecksumAlgorithm: 'SHA256',
      Metadata: { 'content-sha256': hash },
    }));
    log('info', 'published media address list', { prefixes: body.prefixes.length, regions: parameters.length, syncToken: document.syncToken });
    return { changed: true, prefixes: body.prefixes.length, syncToken: document.syncToken };
  };
}

let handlerInstance;
export const handler = (event) => {
  handlerInstance ??= createHandler();
  return handlerInstance(event);
};