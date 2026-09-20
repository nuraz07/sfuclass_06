# classroom-app/ops/runbooks/on-call.md

# On-call

**One page. Alert → owner → first action.** Everything longer lives in the
runbook the row points at.

Pager: `classroom-<env>-alarms` (SNS). Escalation after 15 minutes without an
acknowledgement. The on-call person is allowed to roll back without asking; a
task-definition revert to the previous digest is always a safe first move.

---

## 0. First 60 seconds

1. **Is it a release?** Compare `RELEASE_SHA` in the logs against the last
   deployment. If they match, suspect the release first — `rollback.md`.
2. **Is it one region or all of them?** ICE and TURN alarms are per region. One
   region means placement can route around it; all of them means the control
   plane.
3. **Is media affected, or only the app?** Media runs client ↔ SFU directly, so
   the ALB, the API and even the realtime service can be down while a lesson in
   progress keeps working. That changes how urgent the fix is, not whether you
   fix it.
4. **Say something.** One line in the incident channel: what fired, what you are
   looking at, whether lessons are affected.

---

## 1. Platform

| Alarm | Condition | Owner | First action |
|---|---|---|---|
| API 5xx rate | > 2 % over 5 min | platform | Check the release; roll back the task definition (`rollback.md`) |
| Readiness failures | any task failing `/readyz` for 3 min | platform | `/readyz` probes Postgres, Redis and S3 — check RDS and Redis health before touching the service |
| Database | CPU, connections or replica lag above threshold | platform | Find the query (Performance Insights); check `PG_POOL_MAX` against the instance limit |
| Redis state memory | > 70 % | platform | Scale the state cluster. It is `noeviction` and **must never evict**: it holds queues, seat reservations and the media registries |
| Chat delivery latency | p95 > 1 s for 5 min | messaging | Check the sharded Pub/Sub adapter and socket fan-out; look at realtime task count |
| Transcode lag | queue depth or oldest job age | media | Scale the worker service; inspect dead letters |
| Certificate expiry | ACM or TURN certificate under 21 days | platform | Renewal is automatic — investigate the renewer (`rotate-secrets.md`, section 3) |

---

## 2. Media plane (F1, F8)

The rule of thumb: **a direct-path problem and a relay problem look the same to
a learner and completely different in the metrics.** `ice_candidate_type` is the
first dashboard to open.

| Alarm | Condition | Owner | First action |
|---|---|---|---|
| ICE failure rate | transports failing ICE > 2 % over 10 min, per region | media | Check the SFU security group and EIP associations, then the TURN canary. A recent network or Terraform change in `media-edge` is the usual cause |
| Relay share spike | relayed share doubles against the 7-day baseline | media | The direct UDP path to the SFU is probably broken: check the WebRtcServer ports, NACLs and EIP association. Users are still connected — this is urgent, not an outage |
| TURN canary failed | 2 consecutive failures in a region | media | Check TURN nodes, the TLS certificate and which rotation phase the secret ring is in |
| TURN auth failures | 401 rate > 5 % of allocations | media | Secret ring mismatch. Compare the API's signing version (`secretVersionId` in `rtc.ice.issued` audit rows) with the set the nodes accept. If a rotation is running, **go back a phase, not forward** |
| TURN node saturation | relayed Mbit/s > 80 % of baseline on a node | media | Scale out; verify `TurnPoolSelector` is spreading load rather than pinning one node |
| SFU node saturation | load score above threshold | media | Scale out; confirm cascading is engaging for large rooms |
| EIP pool low | < 20 % free in a region | platform | Allocate more EIPs and re-run `publish-ip-ranges`, or scale-out will fail silently at the next launch |

### Quick checks

```bash
ENV=prod REGION=eu-central-1

# Which nodes does the registry think are healthy?
redis-cli -h "$REDIS_STATE" --tls KEYS "media:sfu:$REGION:*"
redis-cli -h "$REDIS_STATE" --tls KEYS "media:turn:$REGION:*"

# Is a node draining? (placement skips these)
redis-cli -h "$REDIS_STATE" --tls KEYS "media:drain:*"

# Does one node actually answer?
curl -sk --cert client.pem --key client.key https://<node-private-ip>:7443/healthz/sfu | jq

# Does TURN actually relay?
ops/scripts/check-turn.sh --env $ENV --node turn-euc1-07
```

### Symptom → cause

| What people report | Most likely | Confirm with |
|---|---|---|
| "Everyone froze, chat still works" | Media path down, signalling fine | `ice_failure` per region; the banner says *media restarting* |
| "It reconnects every few seconds" | A node was replaced without draining, or a recovery loop | `ice_restart` rate, `sfu_drain_*` events |
| "Only the people at the school can't join" | UDP blocked, TURN/TLS 443 not reachable for that tenant | `ice_candidate_type` for that tenant; `customer-firewall.md` |
| "Video is bad for everyone in one room" | Node saturated or cascading not engaging | `sfu_load_score`, room size |
| "Nobody can start a lesson, existing ones are fine" | Control plane: placement, registry or control RPC | Joins failing with `sfu_unavailable`; Redis state health |

---

## 3. What is *not* an incident

- **A draining node.** Drain is the normal way a node leaves. `/healthz/sfu`
  reports healthy and `accepting: false`; lessons finish, then it terminates.
  See `sfu-incident.md` only if rooms are still on it at the drain timeout.
- **A single relayed user.** A relay is a working path, not a failure. The
  banner tells them quality may be lower.
- **A media region losing the control plane.** Running rooms keep running —
  media flows client ↔ SFU directly. New placements go to healthy regions. Fix
  it during the day unless placements are failing.

---

## 4. Failure playbook (from section 12.2)

| What broke | What happens on its own | What you do |
|---|---|---|
| A task dies | ECS replaces it; sockets reconnect; the client outbox replays | Nothing, unless it repeats |
| An SFU node dies | Heartbeat expires within 15 s; clients see ICE fail; `IceRecovery` rejoins; placement moves the room | Confirm the room moved; check why the node died |
| A TURN node dies | Relayed users lose their path; fresh `iceServers` point at a healthy node; direct users unaffected | Confirm the node left the registry |
| An AZ is lost | Services reschedule, RDS fails over, TURN backups point elsewhere | Watch capacity in the remaining AZs |
| A media region is lost | Placement excludes it; rooms rejoin in the next allowed region per residency policy | Tell tenants with residency constraints |
| A bad deployment | Circuit breaker rolls back on failed health checks | Manual path: revert the task definition |
| Redis state lost | Registries rebuild from heartbeats within 15 s; entitlements re-read from Postgres; jobs re-driven | Degraded, not down. Do not flush anything |

---

## 5. Handover

At the end of a shift, write down: what fired, what you did, what you did not
finish, and anything you had to look up that is not in a runbook. The last one
is the most valuable — it is how this page stays useful.