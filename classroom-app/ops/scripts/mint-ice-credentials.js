#!/usr/bin/env node
// ops/scripts/mint-ice-credentials.js
//
// Short-lived TURN credentials for debugging, and pseudonym lookups for support — both audited before anything is
// printed.
//
//   mint     credentials exactly as the API issues them (server/src/rtc/TurnCredentialIssuer.js, same secret ring),
//            but with a random ops pseudonym and a TTL of at most 1 hour. Use them with check-turn.sh, turnutils_uclient,
//            or paste the iceServers into a test page / chrome://webrtc-internals session.
//   derive   the opaque id a given user/device session has in TURN logs (server/src/rtc/OpaqueUserId.js), so a
//            coturn log line can be matched to a support ticket. Needs the ICE opaque-id pepper.
//
// Every invocation first writes an audit event — who (STS caller identity), why (reason + ticket), what (TTL, expiry,
// pseudonym; never the credential) — to the CloudWatch Logs group /classroom/<env>/audit/ice-debug-credentials. If that
// write fails, nothing is printed (fail closed). Secrets Manager additionally records the GetSecretValue in CloudTrail.
//
// Usage:
//   node ops/scripts/mint-ice-credentials.js --env prod --reason "relay failures for school X" --ticket INC-1234 \
//        --secret-id <TURN shared secret ARN> [--region eu-central-1] [--ttl 900] \
//        [--host turn-euc1-07.rtc.example.com] [--format json|env|webrtc]
//   node ops/scripts/mint-ice-credentials.js --derive-opaque-id --env prod --reason "…" --ticket SUP-88 \
//        --pepper-secret-id <ICE opaque-id pepper ARN> --tenant <tenantId> --user <userId> --device-session <id>
//   Local development (no AWS, audit to stderr): --env dev --dev-secret-env TURN_SECRET_DEV
//
// Environment fallbacks: TURN_SECRET_ID, ICE_OPAQUE_ID_PEPPER_SECRET_ID, AWS_REGION.
// Requires AWS credentials of an operator role (SSO) allowed to read the secret and write the audit group.
// Run from the repository root after `npm ci` (uses the server workspace's modules).
//
// Owner: F8 Real-Time Connectivity (+ security review).

import { parseArgs } from 'node:util';
import { randomBytes } from 'node:crypto';
import { hostname, userInfo } from 'node:os';
import { TurnSecretRing } from '../../server/src/rtc/TurnSecretRing.js';
import { TurnCredentialIssuer } from '../../server/src/rtc/TurnCredentialIssuer.js';
import { OpaqueUserId } from '../../server/src/rtc/OpaqueUserId.js';

const MAX_TTL_SECONDS = 3600;

const { values: args } = parseArgs({
  options: {
    env: { type: 'string' },
    reason: { type: 'string' },
    ticket: { type: 'string' },
    'secret-id': { type: 'string', default: process.env.TURN_SECRET_ID },
    'pepper-secret-id': { type: 'string', default: process.env.ICE_OPAQUE_ID_PEPPER_SECRET_ID },
    region: { type: 'string', default: process.env.AWS_REGION ?? 'eu-central-1' },
    ttl: { type: 'string', default: '900' },
    host: { type: 'string' },
    'tls-port': { type: 'string', default: '443' },
    format: { type: 'string', default: 'json' },
    'dev-secret-env': { type: 'string' },
    'derive-opaque-id': { type: 'boolean', default: false },
    tenant: { type: 'string' },
    user: { type: 'string' },
    'device-session': { type: 'string' },
    help: { type: 'boolean', short: 'h', default: false },
  },
  strict: true,
});

function fail(message, code = 2) {
  process.stderr.write(`mint-ice-credentials: ${message}\n`);
  process.exit(code);
}

if (args.help) {
  process.stdout.write('See the header of ops/scripts/mint-ice-credentials.js for usage.\n');
  process.exit(0);
}

// ------------------------------------------------------------------ validation

const env = args.env;
if (!['dev', 'staging', 'prod'].includes(env)) fail('--env must be dev, staging or prod');
const devMode = Boolean(args['dev-secret-env']);
if (devMode && env !== 'dev') fail('--dev-secret-env is only allowed with --env dev');
if (!args.reason || args.reason.trim().length < 10) fail('--reason is required (at least 10 characters)');
if (env !== 'dev' && !/^[A-Z][A-Z0-9]+-\d+$/.test(args.ticket ?? '')) fail('--ticket is required outside dev (e.g. INC-1234)');
const ttl = Number(args.ttl);
if (!Number.isInteger(ttl) || ttl < 60 || ttl > MAX_TTL_SECONDS) fail(`--ttl must be an integer between 60 and ${MAX_TTL_SECONDS} seconds`);
if (!['json', 'env', 'webrtc'].includes(args.format)) fail('--format must be json, env or webrtc');
process.env.AWS_REGION = args.region;

// ------------------------------------------------------------------ audit (fail closed)

async function callerIdentity() {
  if (devMode) return { arn: `local:${userInfo().username}@${hostname()}` };
  const { STSClient, GetCallerIdentityCommand } = await importSdk('@aws-sdk/client-sts');
  const out = await new STSClient({}).send(new GetCallerIdentityCommand({}));
  return { arn: out.Arn, account: out.Account };
}

async function audit(event) {
  const line = JSON.stringify({ type: 'ice-debug-credentials', at: new Date().toISOString(), env, ...event });
  if (devMode) {
    process.stderr.write(`audit ${line}\n`);
    return;
  }
  const { CloudWatchLogsClient, CreateLogStreamCommand, PutLogEventsCommand } = await importSdk('@aws-sdk/client-cloudwatch-logs');
  const logs = new CloudWatchLogsClient({});
  const logGroupName = `/classroom/${env}/audit/ice-debug-credentials`;
  const logStreamName = `${new Date().toISOString().slice(0, 10)}/${event.caller.replace(/[^A-Za-z0-9._/-]/g, '_').slice(-400)}`;
  try {
    await logs.send(new CreateLogStreamCommand({ logGroupName, logStreamName }));
  } catch (err) {
    if (err.name !== 'ResourceAlreadyExistsException') throw err;
  }
  await logs.send(new PutLogEventsCommand({ logGroupName, logStreamName, logEvents: [{ timestamp: Date.now(), message: line }] }));
}

async function importSdk(name) {
  try {
    return await import(name);
  } catch {
    fail(`${name} is not installed; run \`npm ci\` at the repository root`);
  }
}

async function secretString(secretId) {
  const { SecretsManagerClient, GetSecretValueCommand } = await importSdk('@aws-sdk/client-secrets-manager');
  const out = await new SecretsManagerClient({}).send(new GetSecretValueCommand({ SecretId: secretId }));
  return out.SecretString;
}

// ------------------------------------------------------------------ modes

async function derive(caller) {
  for (const flag of ['tenant', 'user', 'device-session']) if (!args[flag]) fail(`--${flag} is required with --derive-opaque-id`);
  if (!devMode && !args['pepper-secret-id']) fail('--pepper-secret-id (or ICE_OPAQUE_ID_PEPPER_SECRET_ID) is required');
  const pepper = devMode ? process.env.ICE_OPAQUE_ID_PEPPER : await secretString(args['pepper-secret-id']);
  if (!pepper) fail('pepper not available');
  const opaqueId = new OpaqueUserId({ getPepper: () => pepper }).derive({
    tenantId: args.tenant, userId: args.user, deviceSessionId: args['device-session'],
  });
  await audit({ action: 'derive-opaque-id', caller: caller.arn, reason: args.reason, ticket: args.ticket ?? null, tenant: args.tenant, opaqueId });
  process.stdout.write(`${JSON.stringify({ opaqueId, note: 'TURN usernames of this device session look like <expiry>:' + opaqueId }, null, 2)}\n`);
}

async function mint(caller) {
  let ring;
  if (devMode) {
    const value = process.env[args['dev-secret-env']];
    if (!value) fail(`environment variable ${args['dev-secret-env']} is empty`);
    ring = await new TurnSecretRing({ staticSecrets: { current: value } }).start();
  } else {
    if (!args['secret-id']) fail('--secret-id (or TURN_SECRET_ID) is required');
    ring = await new TurnSecretRing({ secretId: args['secret-id'] }).start();
    ring.stop();
  }
  const issuer = new TurnCredentialIssuer({ secretRing: ring, minTtlSeconds: 60, maxTtlSeconds: MAX_TTL_SECONDS });
  const opaqueId = `ops${randomBytes(12).toString('base64url')}`; // random: never a real user's identity
  const credential = issuer.issue({ opaqueId, ttlSeconds: ttl });

  await audit({
    action: 'mint', caller: caller.arn, reason: args.reason, ticket: args.ticket ?? null,
    ttlSeconds: ttl, expiresAt: credential.expiresAt, username: credential.username,
    secretVersion: credential.secretVersion, host: args.host ?? null,
  });

  const out = { username: credential.username, credential: credential.credential, expiresAt: credential.expiresAt };
  if (args.format === 'env') {
    process.stdout.write(`TURN_USERNAME='${out.username}'\nTURN_CREDENTIAL='${out.credential}'\nTURN_EXPIRES_AT='${out.expiresAt}'\n`);
  } else if (args.format === 'webrtc') {
    if (!args.host) fail('--host is required with --format webrtc');
    const urls = [
      `turn:${args.host}:3478?transport=udp`,
      `turn:${args.host}:3478?transport=tcp`,
      `turns:${args.host}:${args['tls-port']}?transport=tcp`,
    ];
    process.stdout.write(`${JSON.stringify({ iceServers: [{ urls: [`stun:${args.host}:3478`] }, { urls, username: out.username, credential: out.credential }], iceTransportPolicy: 'relay', expiresAt: out.expiresAt }, null, 2)}\n`);
  } else {
    process.stdout.write(`${JSON.stringify(out, null, 2)}\n`);
  }
}

try {
  const caller = await callerIdentity();
  await (args['derive-opaque-id'] ? derive(caller) : mint(caller));
} catch (err) {
  fail(`${err.name ?? 'Error'}: ${err.message}`, 1);
}