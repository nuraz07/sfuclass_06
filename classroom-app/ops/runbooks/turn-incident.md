# TURN incident runbook

`ops/runbooks/turn-incident.md` · Owner: F8 Real-Time Connectivity · On-call: media plane

Covers the STUN/TURN service (`turn/`, one coturn + agent pool per media region) and everything that makes clients
fall back to it. Media and signalling incidents that are not TURN-specific live in `sfu-incident.md` and `on-call.md`.

**How TURN fails, in one paragraph.** Clients get TURN addresses and short-lived HMAC credentials from the API
(`server/src/rtc/`). A node is only handed out while its agent passes the self-probe (real STUN + TURN allocation
over UDP and TLS) and heartbeats into the registry. A broken node therefore disappears from new ICE configurations
within about 15 s on its own; clients already relayed through it restart ICE onto another node. Most TURN alarms mean
either **capacity** (too few nodes), **secrets/certificates** (credentials or TLS rejected everywhere at once), or
**direct paths broken elsewhere** (relay share spikes because UDP to the SFU no longer works).

---

## 1 · Alarm → section

| Alarm | Where | Go to |
|---|---|---|
| `classroom-<env>-media-<region>-turn-probe-failing` | media-edge, per region | [4 Node loss or probe failures](#4--node-loss-or-probe-failures) |
| `classroom-<env>-turn-canary-<region>` | connectivity-canary module | [4](#4--node-loss-or-probe-failures), then [6](#6--tls-certificate) |
| `classroom-<env>-media-<region>-turn-node-saturated` | media-edge | [5 Capacity](#5--capacity-saturation) |
| `classroom-<env>-media-<region>-turn-eip-pool-exhausted` | media-edge | [5.3](#53-address-pool-exhausted) |
| Relay share spike (relayed share doubles vs 7-day baseline) | core observability | [3 Relay spike](#3--relay-share-spike) |
| TURN auth failures (401 > 5 % of allocations) | core observability | [7 Credential failures](#7--credential-failures-401) |
| ICE failure rate > 2 % | core observability | [3](#3--relay-share-spike), then [4](#4--node-loss-or-probe-failures) |
| Certificate expiry (`Classroom/Turn CertificateDaysRemaining` < 21) | core observability | [6 TLS certificate](#6--tls-certificate) |
| deploy-turn.yml: "Both colours are scaled up" | GitHub Actions | [8 Interrupted deployment](#8--interrupted-deployment) |

Severity: **SEV-1** when relayed users cannot connect in a region (canary failing, auth failures everywhere, certificate
expired). **SEV-2** for saturation, single-node loss with remaining capacity, relay spike without user impact.

---

## 2 · Five-minute triage

Set context once:

```bash
export ENV=prod REGION=eu-central-1 SHORT=euc1 PREFIX=classroom-prod
export CLUSTER=$PREFIX-media-$REGION
```

1. **Dashboard** `classroom-<env>-media-<region>` — TURN load ratio (max node), probe success, allocations, relayed
   egress, free Elastic IPs, alarm panel.
2. **Which nodes are published?** From a host with access to the state Redis (realtime task via ECS Exec, or the
   ops bastion):

   ```bash
   redis-cli --tls -u "$REDIS_STATE_URL" ZRANGE "media:turn:{$REGION}:index" 0 -1 WITHSCORES
   redis-cli --tls -u "$REDIS_STATE_URL" GET "media:turn:{$REGION}:node:turn-$SHORT-07"
   redis-cli --tls -u "$REDIS_STATE_URL" --scan --pattern "media:drain:turn-$SHORT-*"
   ```

   A node missing from the index is either unhealthy (probe failing), draining, or gone.
3. **Test one node like a client** (from your laptop or the affected customer's network):

   ```bash
   ops/scripts/check-turn.sh --host turn-$SHORT-07.rtc.example.com --env $ENV \
     --ticket INC-1234 --reason "turn-probe-failing alarm" --secret-id "$TURN_SECRET_ARN" --region $REGION
   ```

4. **Ask the node itself** (agent on 127.0.0.1:8080, through SSM):

   ```bash
   aws ssm send-command --region $REGION --instance-ids i-0abc... --document-name AWS-RunShellScript \
     --parameters 'commands=["curl -s http://127.0.0.1:8080/healthz","curl -s http://127.0.0.1:8080/drain/status"]'
   ```

   `/healthz` shows the last probe error, registry state, allocations and release.
5. **Recent changes?** deploy-turn.yml runs, secret rotation phase (section 7), certificate renewal (section 6),
   security-group or network changes in `infra/media-edge`.

---

## 3 · Relay share spike

**Meaning.** Many more sessions than usual use a relay candidate. TURN itself is usually fine — something broke the
**direct** path (UDP/TCP to the SFU's WebRtcServer ports), and ICE correctly fell back to TURN.

1. Scope it: one region or all? One tenant/network or everyone? (`rtcStats` telemetry: candidate type by region,
   tenant, ASN.)
2. One region, everyone:
   - SFU security group still opens UDP+TCP `rtc_port_base … +workers-1` from `0.0.0.0/0`
     (`infra/modules/sfu-node-pool/security-group.tf`); check recent Terraform applies.
   - Elastic IPs still associated: every running SFU instance has tag `SfuPublicIp` equal to its public IPv4.
   - SFU nodes announce the right address: node log line `resolved node addresses`; ICE candidates in
     `chrome://webrtc-internals` must show the Elastic IP and the worker port.
3. One tenant or network: a customer firewall change. Send them `customer-firewall.md`, ask for the lobby network check
   ("Copy report"). Not an incident for us unless the customer is blocked entirely.
4. Watch TURN capacity while the spike lasts (section 5): relay spikes are what saturates TURN.

---

## 4 · Node loss or probe failures

**Automatic handling** — verify it happened before intervening:

- Failed probe → the agent leaves the registry immediately; the API stops handing the node out (≤ 1 s).
- ECS replaces the task after the container health check (`/healthz`) fails 3 times.
- Clients on the node: ICE consent fails → `IceRecovery` restarts ICE with fresh iceServers on a healthy node.

**Steps**

1. Identify the node: metric `Classroom/Turn ProbeSuccess` with dimensions `Region, Node`, or the agent log
   (`turn self-probe failed`, field `err.message`).
2. Read the probe error:

   | Probe error | Likely cause | Action |
   |---|---|---|
   | `STUN udp timeout` | coturn down, UDP 3478 blocked by SG/NACL, instance network impaired | check container `coturn` logs; SG; replace node |
   | `401` on allocation | node has a different secret set than the API signs with | section 7 |
   | `relayed address … is not the node's Elastic IP` | EIP re-associated / lost | replace node (the lifecycle Lambda re-attaches a pool address) |
   | `relay accepted a permission for denied peer` | **security:** denied-peers list not rendered | stop the node now (step 4), page security, then check `turn/config/denied-peers.conf` and the deployed image (`entrypoint.sh check` prints the rendered config with secrets masked) |
   | TLS errors (`certificate has expired`, `hostname mismatch`) | certificate | section 6 |

   Known pitfall: coturn matches IPv4 peers against the IPv6 address `::` and any range starting at `::` as a wildcard.
   Such an entry in `denied-peers.conf` blocks **every** peer, SFUs included: all probes then fail with 403 on the
   public peer. The shipped list deliberately contains no such entry — keep it that way.

3. Canary failing but every node's probe passes: the path from the internet is broken, not the nodes — Route 53
   health checks (`turn-<region>` returns no addresses?), IGW/route table, NACLs, a regional AWS network event.
4. **Take a node out by hand** (keeps its live allocations until they end):

   ```bash
   aws autoscaling terminate-instance-in-auto-scaling-group --region $REGION \
     --instance-id i-0abc... --no-should-decrement-desired-capacity
   ```

   The terminate hook sets `media:drain:<node>`; the agent drains (≤ `drain_timeout_minutes`) and completes the hook;
   a replacement launches at once. For an immediate stop (security issue), stop the task instead:
   `aws ecs stop-task --cluster $CLUSTER --task <arn> --reason INC-1234` — its clients restart ICE elsewhere.
5. Several nodes failing at once in one region → treat as regional; check the last deploy-turn.yml run and roll back
   (`gh workflow run deploy-turn.yml -f sha=<previous sha> -f reason=rollback`).

---

## 5 · Capacity (saturation)

`LoadRatio = max(allocations / total_quota, relayed Mbit/s / capacity_mbps)` per node; the pool scales out at
`target_load_ratio` (0.6). The alarm fires at 0.8 on any node for 5 minutes.

### 5.1 One node hot, others cool
Selector spread problem or a long-lived burst (one big school relayed through one node). Usually self-healing as new
allocations go elsewhere. If it persists > 30 min: drain the hot node (section 4 step 4).

### 5.2 Whole pool hot
1. Is autoscaling at `max_nodes`? `aws autoscaling describe-auto-scaling-groups` for the TURN group.
2. Raise `turn.max_nodes` in `infra/envs/<env>/media-edge.<region>.tfvars` — the Elastic IP pool must stay
   ≥ `2 × max_nodes + 1` (plan fails otherwise) → section 5.3 if it has to grow.
3. Check why relay demand rose (section 3): fixing a broken direct path removes most relay load.

### 5.3 Address pool exhausted
No free Elastic IP means the next node cannot launch (launch is abandoned, the ASG retries).

1. Short term: free a slot — terminate a drained/idle node of the pool, or pause deploy-turn.yml blue/green runs
   (they need `2 × nodes`).
2. Grow `eip_pool.turn` / `eip_pool.sfu` in the tfvars, check the regional Elastic IP quota, apply. New addresses are
   published automatically (`publish-ip-ranges`); follow the announcement procedure in `customer-firewall.md`
   **before** they are needed (nodes take the lowest free slot, so new high slots stay unused until the older ones
   are busy).

---

## 6 · TLS certificate

TURN over TLS (443) uses `*.<rtc_domain>` from Let's Encrypt, renewed by `infra/functions/acme-renewer` 30 days before
expiry and loaded by nodes on refresh.

1. Days left: metric `Classroom/Turn CertificateDaysRemaining`, or `check-turn.sh` (section 2 step 3).
2. Renewer failing? Logs of `<prefix>-acme-renewer`: Route 53 permission errors, ACME rate limits, DNS propagation.
   Force a run: `aws lambda invoke --function-name <prefix>-acme-renewer --payload '{"force":true}' out.json`.
3. Secret renewed but nodes serve the old certificate → nodes were not refreshed:
   `gh workflow run deploy-turn.yml -f reason=tls-renewal` (sha empty = keep images).
4. Expired certificate in production (SEV-1): steps 2 → 3; relayed users on TLS-only networks are down until nodes
   refreshed; UDP/TCP 3478 relaying is unaffected.

---

## 7 · Credential failures (401)

Credentials are `base64(HMAC-SHA1(secret, "<expiry>:<opaqueId>"))`; the API signs with the secret's `AWSCURRENT`
version, nodes accept `AWSCURRENT`, `AWSPENDING` and `AWSPREVIOUS` as loaded at their last refresh.

1. **Rotation phase:**

   ```bash
   aws secretsmanager describe-secret --secret-id "$TURN_SECRET_ARN" \
     --query '{stages: VersionIdsToStages, tags: Tags, replication: ReplicationStatus}'
   ```

   Tag `turn-rotation:phase` is `accept`, `retire-wait` or `idle`. The rotation function only promotes after every
   registered node accepted the new secret — if 401s started right after a promotion, a node was **not registered**
   during the check (e.g. booting) and never refreshed.
2. **Replication:** `ReplicationStatus` must be `InSync` for the media region. Nodes read the regional replica.
3. **Fix:** refresh the nodes of the affected region(s): `gh workflow run deploy-turn.yml -f reason=secret-rotation`.
   Confirm with `check-turn.sh` against each node.
4. **Clock skew:** credentials carry an expiry timestamp; a node or API task with a wrong clock rejects/produces
   expired credentials. Check `chronyc tracking` on the node (SSM) — Amazon Time Sync is expected.
5. **Suspected secret leak** → emergency rotation (invalidates every outstanding credential; relayed users reconnect
   after the node refresh completes, direct users are unaffected):

   ```bash
   aws lambda invoke --function-name <prefix>-turn-secret-rotation --payload '{"action":"emergency"}' out.json
   ```

   Record it in the incident; follow `rotate-secrets.md` for the post-incident review.

---

## 8 · Interrupted deployment

deploy-turn.yml switches a region blue/green: scale up the idle colour, drain the old one, scale it to 0. If a run was
cancelled or timed out, both `turn-blue` and `turn-green` have tasks and the next run stops with
"Both colours are scaled up".

1. Which colour is new? Compare `RELEASE_SHA` in the task definitions:

   ```bash
   for c in blue green; do
     td=$(aws ecs describe-services --region $REGION --cluster $CLUSTER --services turn-$c --query 'services[0].taskDefinition' --output text)
     echo "turn-$c $td $(aws ecs describe-task-definition --region $REGION --task-definition $td \
       --query "taskDefinition.containerDefinitions[0].environment[?name=='RELEASE_SHA'].value" --output text)"
   done
   ```

2. Did the old colour already start draining? `curl -s http://127.0.0.1:8080/drain/status` on its instances (SSM).
3. **Finish forward** (new colour healthy, canary OK — the usual case): drain the old colour's nodes
   (`POST /drain` via SSM), wait until `/drain/status` shows `allocations: 0` (or the drain timeout), then
   `aws ecs update-service --cluster $CLUSTER --service turn-<old> --desired-count 0`.
4. **Roll back** (new colour unhealthy): scale the new colour to 0 — its nodes have few or no allocations yet; if the
   old colour had started draining, its nodes stay out of the registry until replaced, so also run
   `gh workflow run deploy-turn.yml -f reason=rollback -f sha=<old sha>` to rebuild a clean colour.
5. Re-run the pipeline for the region once exactly one colour has tasks.

---

## 9 · After the incident

- Timeline in the incident document, including which automatic mechanisms worked.
- If a node was handed out while broken, or clients stayed on a dead node > 30 s, file a bug against `turn/agent` or
  `core-client IceRecovery` — both are supposed to prevent exactly that.
- Capacity incidents: re-run `ops/load/turn-load.md` for the instance type and update `capacity_mbps`.
- Firewall-related findings: update `customer-firewall.md` and the ICE matrix (`ops/load/ice-matrix.md`).