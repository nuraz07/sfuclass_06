# TURN load test per node size

`ops/load/turn-load.md` · Owner: F8 Real-Time Connectivity · Environment: **staging** only

Calibrates the two per-node limits the platform relies on, for each instance type used in a TURN pool:

| Setting (`infra/envs/<env>/media-edge.<region>.tfvars`) | Used by |
|---|---|
| `turn.capacity_mbps` | agent `LoadRatio`, `TurnPoolSelector` load, autoscaling target, saturation alarm |
| `turn.total_quota` | coturn `total-quota`, agent `LoadRatio` |

Until a type is calibrated, the tfvars carry conservative planning values. Re-run after changing the instance type,
the coturn version (Renovate PR label `needs-staging-soak`) or the agent.

## 1 · What is measured

TURN is bandwidth-bound: each relayed packet is received on one socket and sent on another. The test drives a node
with media-like traffic (1200-byte packets every 10 ms per allocation ≈ 0.96 Mbit/s each way) and increases the number
of allocations until one limit is hit:

| Signal | Source | Pass limit |
|---|---|---|
| Packet loss | `turnutils_uclient` summary "Total lost packets" | ≤ 0.5 % |
| Round-trip time increase over the 50-allocation baseline | uclient "Average round trip delay" | ≤ 20 ms |
| Jitter | uclient "Average jitter" | ≤ 10 ms |
| Node CPU (max core) | CloudWatch / `mpstat -P ALL` via SSM | ≤ 70 % |
| Relayed egress | `Classroom/Turn RelayEgressMbps` (Node dimension) | recorded |
| Self-probe | `Classroom/Turn ProbeSuccess` | stays 1 |

The **highest step that passes every limit** is the node's sustainable point.

## 2 · Setup

### 2.1 The node under test
Staging region `eu-central-1`, one TURN node of the instance type to calibrate. Prevent real traffic on it:

```bash
# Keep it published (the probe must keep passing) but make it unattractive for real clients:
# run the test in a maintenance window, or temporarily raise turn.max_nodes so real load spreads elsewhere.
export NODE=turn-euc1-03 NODE_IP=<its Elastic IP> REGION=eu-central-1
```

### 2.2 Peers — must be allowed by the TURN security group
TURN relays only to addresses in the **SFU prefix list**, on SFU RTC ports (`rtc_port_base` … `+63`). A load peer
therefore has to use a **free SFU pool address** and listen on an RTC port:

1. Launch 1–2 `c7gn.xlarge` instances in a public media subnet of the staging media VPC (security group allowing
   UDP 40000 from the TURN prefix list).
2. Associate a **free** Elastic IP of the SFU pool (tag `MediaPool=sfu`, no association) — check that no SFU node is
   waiting for one (`FreeEips` ≥ 2).
3. Install coturn utilities and start the echo peer:

   ```bash
   sudo apt-get install -y coturn   # provides turnutils_peer / turnutils_uclient
   turnutils_peer -L 0.0.0.0 -p 40000
   ```

Release the addresses right after the test (disassociate; the pool slot becomes free again).

### 2.3 Load generators
3–6 instances **outside** the media VPC (another region or account works), `c7gn.2xlarge`, with coturn utilities.
One `turnutils_uclient` process handles a few hundred allocations; run several processes per generator.

### 2.4 Credentials
Audited, one hour, one per generator:

```bash
node ops/scripts/mint-ice-credentials.js --env staging --ticket LOAD-42 --reason "TURN load test c7gn.xlarge" \
  --secret-id "$TURN_SECRET_ARN" --region $REGION --ttl 3600 --format env > turn-creds.env
```

`user-quota` (12) limits allocations per credential: mint one credential per 10 allocations, or raise
`turn.user_quota` on the staging node for the test (and restore it afterwards).

## 3 · Procedure

Baseline, then steps. Each step runs 10 minutes (`-n 60000` packets at `-z 10`).

```bash
. ./turn-creds.env
# one process = 100 allocations (-m 100), no RTCP twin allocations (-c), IPv4 relay (-X)
turnutils_uclient -c -X -m 100 -n 60000 -l 1200 -z 10 \
  -e <peer Elastic IP> -r 40000 -u "$TURN_USERNAME" -w "$TURN_CREDENTIAL" -p 3478 "$NODE_IP" \
  > step-$(hostname)-$$.log 2>&1 &
```

| Step | Allocations (total) | Expected relayed egress |
|---|---|---|
| 0 baseline | 50 | ~ 50 Mbit/s |
| 1 | 500 | ~ 0.5 Gbit/s |
| 2 | 1000 | ~ 1 Gbit/s |
| 3 | 2000 | ~ 2 Gbit/s |
| 4 | 3000 | ~ 3 Gbit/s |
| 5 … | + 1000 per step | until a limit fails |

Also run one step at 70 % of the result with **20 % of the processes over TLS** (`-t -S -p 443`) — TLS costs CPU;
record whether it lowers the sustainable point.

After each step collect:

```bash
grep -h -E 'Total lost packets|Average round trip delay|Average jitter' step-*.log
aws cloudwatch get-metric-statistics --region $REGION --namespace Classroom/Turn --metric-name RelayEgressMbps \
  --dimensions Name=Region,Value=$REGION Name=Node,Value=$NODE --statistics Average Maximum \
  --start-time "$(date -u -d '-12 min' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" --period 60
```

Stop immediately if the self-probe of the node fails for more than one minute — that means real clients would be
affected too.

## 4 · Deriving the settings

- `capacity_mbps` = **70 %** of relayed egress at the sustainable point (headroom for bursts and for the TLS share).
- `total_quota` = allocations at the sustainable point, rounded down to the next 500.
- Keep `target_load_ratio = 0.6`: the pool scales out well before a node reaches the calibrated capacity.

Update the tfvars of **every** environment and region using the type, in one reviewed change that links this
results table.

## 5 · Results

| Date | Instance type | coturn / agent release | Sustainable allocations | Relayed egress at that point | CPU max core | Limit that failed next | capacity_mbps | total_quota | Ticket |
|---|---|---|---|---|---|---|---|---|---|
| _yyyy-mm-dd_ | c7gn.xlarge | 4.6.x / _sha_ | | | | | | | LOAD-_n_ |

Keep old rows; they show how releases change capacity.