// infra/functions/acme-renewer/handler.js
//
// Keeps the TLS certificate for TURN over TLS (port 443) valid. coturn needs the private key on the instance, so an
// ACM certificate cannot be used; this function obtains a publicly trusted certificate through ACME (Let's Encrypt)
// with DNS-01 validation on the delegated rtc zone in Route 53:
//
//   certificate   *.<rtc_domain>   (covers turn-<short>-NN.<rtc_domain> and turn-<region>.<rtc_domain>)
//   key           ECDSA P-256, generated per issuance, never leaves Secrets Manager / the TURN nodes' tmpfs
//   stored in     TURN_TLS secret (core region, replicated to every media region) as
//                 {"fullchain": "...", "privkey": "...", "notAfter": "...", "issuedAt": "..."}
//                 — the shape turn/bootstrap/fetch-tls.sh reads
//
// Runs daily (EventBridge Scheduler). Renews when the stored certificate expires within RENEW_BEFORE_DAYS (30), is
// missing, or does not cover the domain; then requests a node refresh (deploy-turn.yml, reason "tls-renewal") so every
// node loads the new certificate well before the old one expires. Always publishes Classroom/Turn
// CertificateDaysRemaining (EMF) for the certificate-expiry alarm.
//
// The ACME account key and account URL are kept in ACME_ACCOUNT_SECRET_ARN and created on the first run.
// Recommended: a CAA record on the rtc zone allowing only letsencrypt.org.
//
// Environment:
//   RTC_DOMAIN                  rtc.example.com
//   HOSTED_ZONE_ID              Route 53 zone of RTC_DOMAIN
//   TURN_TLS_SECRET_ARN         primary TURN TLS secret
//   ACME_ACCOUNT_SECRET_ARN     {"accountKey": "...PEM...", "accountUrl": "..."} (may start empty)
//   ACME_EMAIL                  expiry / incident contact registered with the CA
//   ACME_DIRECTORY              production | staging  (staging for dev and first tests: untrusted, no rate limits)
//   RENEW_BEFORE_DAYS           30
//   GITHUB_DISPATCH_SECRET_ARN  see turn-secret-rotation
//
// Owner: F8 Real-Time Connectivity (+ security review).

import { X509Certificate } from 'node:crypto';
import acme from 'acme-client';
import { Route53Client, ChangeResourceRecordSetsCommand, GetChangeCommand } from '@aws-sdk/client-route-53';
import { SecretsManagerClient, GetSecretValueCommand, PutSecretValueCommand } from '@aws-sdk/client-secrets-manager';

export function log(level, msg, fields = {}) {
  console.log(JSON.stringify({ level, service: 'acme-renewer', msg, ...fields }));
}

/** Days until notAfter of a PEM certificate chain's leaf, and whether it covers the host name. */
export function inspectCertificate(fullchainPem, hostname, now = Date.now()) {
  const leaf = new X509Certificate(fullchainPem);
  const notAfter = new Date(leaf.validTo).getTime();
  return {
    notAfter: new Date(notAfter).toISOString(),
    daysRemaining: Math.floor((notAfter - now) / 86_400_000),
    covers: leaf.checkHost(hostname) !== undefined,
  };
}

export function createHandler({
  domain = process.env.RTC_DOMAIN,
  hostedZoneId = process.env.HOSTED_ZONE_ID,
  tlsSecretId = process.env.TURN_TLS_SECRET_ARN,
  accountSecretId = process.env.ACME_ACCOUNT_SECRET_ARN,
  email = process.env.ACME_EMAIL,
  directory = process.env.ACME_DIRECTORY ?? 'production',
  renewBeforeDays = Number(process.env.RENEW_BEFORE_DAYS ?? 30),
  secrets = new SecretsManagerClient({}),
  route53 = new Route53Client({}),
  acmeLib = acme,
  refreshNodes = defaultRefreshNodes(),
  emit = (line) => console.log(line),
  sleep = (ms) => new Promise((r) => setTimeout(r, ms)),
  now = () => Date.now(),
} = {}) {
  const probeHost = `turn-probe.${domain}`; // any single-label name under the wildcard

  const metric = (daysRemaining) => emit(JSON.stringify({
    _aws: { Timestamp: now(), CloudWatchMetrics: [{ Namespace: 'Classroom/Turn', Dimensions: [['Domain']], Metrics: [{ Name: 'CertificateDaysRemaining', Unit: 'Count' }] }] },
    Domain: domain, CertificateDaysRemaining: daysRemaining,
  }));

  async function readSecret(id) {
    try {
      const out = await secrets.send(new GetSecretValueCommand({ SecretId: id }));
      return out.SecretString ? JSON.parse(out.SecretString) : null;
    } catch (err) {
      if (err.name === 'ResourceNotFoundException') return null; // secret has no version yet
      throw err;
    }
  }

  async function upsertTxt(action, name, value) {
    const out = await route53.send(new ChangeResourceRecordSetsCommand({
      HostedZoneId: hostedZoneId,
      ChangeBatch: {
        Comment: `acme-renewer ${action} ${name}`,
        Changes: [{ Action: action, ResourceRecordSet: { Name: name, Type: 'TXT', TTL: 60, ResourceRecords: [{ Value: `"${value}"` }] } }],
      },
    }));
    if (action === 'DELETE') return;
    for (let i = 0; i < 60; i += 1) {
      const change = await route53.send(new GetChangeCommand({ Id: out.ChangeInfo.Id }));
      if (change.ChangeInfo.Status === 'INSYNC') return;
      await sleep(5_000);
    }
    throw new Error(`Route 53 change for ${name} not in sync after 5 minutes`);
  }

  async function accountClient() {
    const stored = (await readSecret(accountSecretId)) ?? {};
    const accountKey = stored.accountKey ?? (await acmeLib.crypto.createPrivateEcdsaKey('P-256')).toString();
    const client = new acmeLib.Client({
      directoryUrl: directory === 'staging' ? acmeLib.directory.letsencrypt.staging : acmeLib.directory.letsencrypt.production,
      accountKey,
      accountUrl: stored.accountUrl,
    });
    return { client, accountKey, stored };
  }

  return async function handler(event = {}) {
    const current = await readSecret(tlsSecretId);
    if (current?.fullchain && event.force !== true) {
      try {
        const info = inspectCertificate(current.fullchain, probeHost, now());
        metric(info.daysRemaining);
        if (info.covers && info.daysRemaining > renewBeforeDays) {
          log('info', 'certificate still valid; nothing to do', info);
          return { renewed: false, ...info };
        }
        log('info', 'certificate due for renewal', info);
      } catch (err) {
        log('warn', 'stored certificate unreadable; issuing a new one', { error: err.message });
      }
    }

    const { client, accountKey, stored } = await accountClient();
    const privateKey = await acmeLib.crypto.createPrivateEcdsaKey('P-256');
    const [, csr] = await acmeLib.crypto.createCsr({ altNames: [`*.${domain}`] }, privateKey);
    const created = [];

    let fullchain;
    try {
      fullchain = await client.auto({
        csr,
        email,
        termsOfServiceAgreed: true,
        challengePriority: ['dns-01'],
        challengeCreateFn: async (authz, _challenge, keyAuthorization) => {
          const name = `_acme-challenge.${authz.identifier.value}`;
          await upsertTxt('UPSERT', name, keyAuthorization);
          created.push({ name, value: keyAuthorization });
        },
        challengeRemoveFn: async (authz, _challenge, keyAuthorization) => {
          const name = `_acme-challenge.${authz.identifier.value}`;
          await upsertTxt('DELETE', name, keyAuthorization).catch((err) => log('warn', 'could not remove challenge record', { name, error: err.message }));
        },
      });
    } finally {
      if (!stored.accountUrl) {
        // Persist the account even if the order failed, so the next run does not register a new one.
        await secrets.send(new PutSecretValueCommand({
          SecretId: accountSecretId,
          SecretString: JSON.stringify({ accountKey, accountUrl: client.getAccountUrl?.() ?? null }),
        })).catch((err) => log('warn', 'could not store ACME account', { error: err.message }));
      }
    }

    const info = inspectCertificate(fullchain, probeHost, now());
    if (!info.covers) throw new Error(`issued certificate does not cover ${probeHost}`);
    await secrets.send(new PutSecretValueCommand({
      SecretId: tlsSecretId,
      SecretString: JSON.stringify({
        fullchain,
        privkey: privateKey.toString(),
        notAfter: info.notAfter,
        issuedAt: new Date(now()).toISOString(),
        directory,
      }),
    }));
    metric(info.daysRemaining);
    log('info', 'certificate issued and stored; requesting TURN node refresh', { notAfter: info.notAfter, challenges: created.length });
    await refreshNodes('tls-renewal');
    return { renewed: true, ...info };
  };
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

let handlerInstance;
export const handler = (event) => {
  handlerInstance ??= createHandler();
  return handlerInstance(event);
};