# classroom-app/ops/runbooks/rotate-secrets.md

# Rotating secrets

**Owner:** platform · **Audience:** on-call · **Last reviewed:** with every release that touches `config/secrets.js`

Every secret lives in AWS Secrets Manager under `classroom/<env>/…` and is read
at boot by `config/secrets.js`, scoped to the process role. Nothing is a literal
in a task definition, an image layer or git, so a rotation is a new secret
version plus, at most, a restart — never a redeploy.

Two rotations are different from the rest and have their own sections: the
**TURN shared secret**, which is signed with rather than read, and the
**TURN TLS certificate**, which cannot come from ACM because ACM certificates
cannot be installed on EC2.

| Secret | Name | Who reads it | Rotation |
|---|---|---|---|
| JWT signing key pair | `jwt/private-key`, `jwt/public-key` | api (private), api + realtime (public) | Manual, dual-publish |
| Cookie secret | `cookie-secret` | api | Manual, restart |
| Database URL | `database/url`, `database/read-url` | api · realtime · worker | Manual with RDS password change |
| Redis URLs | `redis/state-url`, `redis/cache-url` | all roles | Manual with auth-token change |
| CloudFront signing key | `cdn/private-key`, `cdn/key-pair-id` | api | Manual, dual key pair |
| Stripe keys | `stripe/*` | api | Manual, in the Stripe dashboard first |
| **TURN shared secret** | `turn/shared-secret` | api + realtime, and every TURN node | **Automatic, three-phase, every 30 days** |
| **TURN TLS** | `turn/tls` | TURN nodes | **Automatic, ACME DNS-01, 30 days before expiry** |
| ICE opaque-id pepper | `ice/opaque-id-pepper` | api + realtime | Rarely; see the warning below |
| Control-plane mTLS | `sfu-control/*` | sfu + realtime | Manual, CA first |

---

## 1. The ordinary case

Most secrets are read once at boot and cached for five minutes. The sequence is
always the same:

```bash
ENV=prod                       # or staging
NAME=classroom/$ENV/cookie-secret

# 1. Stage the new value.
aws secretsmanager put-secret-value \
  --secret-id "$NAME" \
  --secret-string "$(openssl rand -base64 48)"

# 2. Restart the roles that read it, one service at a time.
aws ecs update-service --cluster classroom-$ENV --service classroom-$ENV-api --force-new-deployment
```

Watch the deployment, then confirm that `/readyz` and `/startupz` are green.
`startupz` is the honest one here: it only answers once the configuration
validated and the secrets loaded.

**A secret that two roles read is rotated in one step and restarted in two.**
Restart the reader that can tolerate a stale value first (realtime), then the
writer (api).

---

## 2. TURN shared secret — three phases

The TURN REST scheme computes credentials rather than storing them:

```
username   = <expiresAtUnix>:<opaqueId>
credential = base64(HMAC-SHA1(secret, username))
```

A credential is valid for up to 24 hours and **cannot be revoked
individually**. That is why rotation exists as more than hygiene: it is the
emergency kill switch. It is also why it has three phases — replacing the
secret in one step would invalidate every credential already in a learner's
browser and drop every relayed participant at once.

`functions/turn-secret-rotation` runs this automatically every
`turn_secret_rotation_days` (30). The manual path is identical and is what you
run during an incident.

### Phase 1 — Accept

A new version is staged as `AWSPENDING`. TURN nodes roll and accept
`{current, new}`; `turnserver.conf` carries two `static-auth-secret` lines for
exactly this window. Nothing is signed with the new secret yet.

```bash
aws secretsmanager put-secret-value \
  --secret-id classroom/$ENV/turn/shared-secret \
  --secret-string "$(openssl rand -hex 32)" \
  --version-stages AWSPENDING

# Roll the TURN fleet so both secrets are loaded. One node at a time,
# allocation-aware: minimum healthy capacity stays at 100 %.
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name classroom-$ENV-turn-eu-central-1 \
  --preferences '{"MinHealthyPercentage":100,"InstanceWarmup":120}'
```

**Gate:** every node in the region reports healthy, and the Synthetics canary is
green. Do not continue with a node that has not rolled — it would start
rejecting credentials the moment phase 2 begins.

### Phase 2 — Sign

`AWSCURRENT` moves to the new version. `TurnSecretRing.js` re-reads it within
60 seconds on every api and realtime task, so new credentials are signed with
the new secret while old ones stay valid.

```bash
NEW=$(aws secretsmanager list-secret-version-ids \
        --secret-id classroom/$ENV/turn/shared-secret \
        --query "Versions[?contains(VersionStages,'AWSPENDING')].VersionId" --output text)

aws secretsmanager update-secret-version-stage \
  --secret-id classroom/$ENV/turn/shared-secret \
  --version-stage AWSCURRENT \
  --move-to-version-id "$NEW"
```

**Gate:** within two minutes, `turn_credentials_issued` keeps its rate and
`TURN auth failures` stays below 5 %. A spike here means a node did not pick up
phase 1 — go back, do not go forward.

### Phase 3 — Retire

Wait out the longest credential that can still be in flight: the tenant maximum
TTL, 24 hours. Then roll the fleet again so nodes accept only the new secret.

```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name classroom-$ENV-turn-eu-central-1 \
  --preferences '{"MinHealthyPercentage":100,"InstanceWarmup":120}'
```

### Emergency rotation (kill switch)

Credentials leaked, or a TURN node is being abused. Run phases 1 and 2 back to
back, then phase 3 **immediately** instead of after 24 hours.

```bash
ops/scripts/mint-ice-credentials.js --env $ENV --dry-run   # confirm what is being invalidated
```

Every relayed participant loses their path within seconds and `IceRecovery`
requests fresh servers, restarts ICE and reconnects. Direct users are
unaffected. Say so in the incident channel before you do it: a few thousand
people see "Restoring audio and video…" at the same moment.

---

## 3. TURN TLS certificate

`turns:…:443` is what gets a learner out of a hotel, a school or a corporate
network, so this certificate is on the critical path for exactly the people with
the worst connectivity.

- Issued by `functions/acme-renewer` for `*.<rtc_domain>` through ACME DNS-01
  on Route 53, stored in `classroom/<env>/turn/tls` and replicated to every
  media region.
- Renewal starts 30 days before expiry and triggers a rolling instance refresh,
  so nodes fetch the new certificate at boot through `bootstrap/fetch-tls.sh`.

Manual renewal, when the alarm `Certificate expiry` fired and the renewer did
not:

```bash
aws lambda invoke --function-name classroom-$ENV-fn-acme-renewer \
  --payload '{"force":true}' /dev/stdout

# Then roll each region's TURN pool.
for REGION in eu-central-1 us-east-1 ap-southeast-1; do
  aws autoscaling start-instance-refresh --region $REGION \
    --auto-scaling-group-name classroom-$ENV-turn-$REGION \
    --preferences '{"MinHealthyPercentage":100}'
done
```

**Check first whether the failure is DNS-01 or rate limiting.** Let's Encrypt
rate limits are per registered domain and per week; a renewer stuck in a retry
loop will not fix itself, and you need the runbook for a staging certificate,
not another invocation.

---

## 4. ICE opaque-id pepper

`ICE_OPAQUE_ID_PEPPER` turns a tenant, user and device session into the
pseudonymous id inside a TURN username, so no name, e-mail or user id ever
reaches a coturn log.

Rotating it is safe for live sessions — new credentials simply get new
pseudonyms — but it **breaks the link between old audit records and old TURN
logs**, which is the one thing that makes a past abuse report traceable. Rotate
it only if it leaked, and record the rotation time in the incident so anyone
reading an older audit row knows why the ids stop matching.

---

## 5. Control-plane mTLS

The realtime service reaches SFU nodes on TCP 7443 with client certificates.
Order matters: everyone must trust the new CA before anyone presents a
certificate signed by it.

1. Write the new CA into `sfu-control/ca` **as an additional trusted CA**, keeping the old one.
2. Roll realtime, then the SFU pools, so both ends trust both CAs.
3. Replace `sfu-control/sfu/*` and `sfu-control/realtime/*` with certificates signed by the new CA; roll again.
4. Remove the old CA; roll a last time.

Between steps 2 and 3 a failed control RPC shows up as joins failing with
`sfu_unavailable` while media for existing sessions keeps flowing — the control
path is not the media path. If that happens, stop and go back a step.

---

## 6. After every rotation

- `RELEASE_SHA` and the secret version id appear in the audit record for each
  issuance (`rtc.ice.issued`, field `secretVersionId`) — use it to confirm which
  version signed what.
- Update the incident or change log with: secret, phase times, who ran it.
- If you skipped a phase gate because of pressure, write that down too. The next
  person needs to know which check was not actually green.