# Network requirements for schools and companies

`ops/runbooks/customer-firewall.md` · Owner: F8 Real-Time Connectivity

Part A is written for the customer's IT department and is published unchanged in the help centre.
Part B is the internal procedure behind it.

---

# Part A — for IT departments

Live classes use WebRTC: audio, video and screen sharing travel directly between each participant's device and our
media servers. The web application itself only needs normal HTTPS. This page lists what your network must allow, from
"best quality" down to "works through strict firewalls".

## A1 · Web application (always required)

| Destination | Port | Notes |
|---|---|---|
| `app.example.com`, `api.example.com`, `cdn.example.com`, `media.example.com` | TCP 443 (HTTPS) | Served by CDN / load balancers with changing addresses: allow by **host name**, not IP. |
| `ws.example.com` | TCP 443 (secure WebSocket) | Signalling and chat. Proxies must allow the WebSocket upgrade; exempt from TLS inspection if WebSockets fail. |

## A2 · Media (audio, video, screen sharing)

All media addresses are fixed and published in one machine-readable file:

```
https://media.example.com/media-ip-ranges.json
```

```json
{
  "syncToken": "1790000000",
  "createDate": "2026-09-19-12-00-00",
  "environment": "prod",
  "hostnames": { "turn": "*.rtc.example.com" },
  "ports": {
    "SFU":  [ { "protocol": "udp", "from": 40000, "to": 40063 }, { "protocol": "tcp", "from": 40000, "to": 40063 } ],
    "TURN": [ { "protocol": "udp", "from": 3478, "to": 3478 }, { "protocol": "tcp", "from": 3478, "to": 3478 },
              { "protocol": "tcp", "from": 443, "to": 443 } ]
  },
  "prefixes": [ { "ip_prefix": "3.120.10.7/32", "region": "eu-central-1", "service": "TURN" }, "…" ]
}
```

- `service: "SFU"` — media servers. `service: "TURN"` — relay servers for restricted networks.
- The list contains **every address we can ever use**, including reserve capacity. It only changes when we add
  capacity or a region; `syncToken` changes exactly then.
- All connections are **outbound** from your network. No inbound rule is needed.

Choose the highest level your policy allows:

| Level | Allow outbound | Result |
|---|---|---|
| **1 · Recommended** | UDP 40000–40063 to all `SFU` prefixes (TCP on the same ports is used when UDP is not allowed), plus level 3 | Direct media, lowest latency, best quality. |
| 2 · Good | UDP and TCP 3478 to all `TURN` prefixes, plus level 3 | Media through our relay; quality usually unaffected. |
| 3 · Minimum | TCP 443 to all `TURN` prefixes (`*.rtc.example.com`), without TLS inspection | Works through strict firewalls; video adapts on congested links. |

Level 3 alone is enough for classes to work. Each level adds on top of the previous one — please do not open level 1
without level 3: the relay is also the automatic fallback when a network path degrades.

## A3 · TLS inspection and proxies

- **Exempt `*.rtc.example.com` from TLS inspection / SSL decryption.** Port 443 on these hosts carries TURN over TLS,
  not HTTPS; an inspecting proxy cannot understand it and the connection fails. Exempting by host name (SNI) is
  sufficient.
- Do not rely on an explicit web proxy (proxy settings / PAC) for media. Some browsers can tunnel TURN over TLS through
  such a proxy (HTTP CONNECT to port 443), others cannot, and UDP never goes through it. Allow the destinations above
  **directly**, even if web traffic goes through a proxy.
- Do not rate-limit or shape UDP on ports 3478 and 40000–40063 below ~5 Mbit/s per device.

## A4 · Bandwidth per participant

| Situation | Download | Upload |
|---|---|---|
| Learner, teacher video + a few learner tiles | 1.5–3 Mbit/s | 0.3–1.5 Mbit/s |
| Teacher presenting (screen share + camera) | 1–2 Mbit/s | 2–4 Mbit/s |
| Audio only | 0.1 Mbit/s | 0.1 Mbit/s |

Video adapts automatically; these are planning values for a classroom of 30 devices on one uplink
(~60–90 Mbit/s download at peak).

## A5 · Automating allowlists

Poll the file once a day and apply changes when `syncToken` differs from the last one you applied:

```bash
curl -s https://media.example.com/media-ip-ranges.json \
  | jq -r '.prefixes[] | select(.service == "TURN") | .ip_prefix'      # TURN relays
curl -s https://media.example.com/media-ip-ranges.json \
  | jq -r '.prefixes[] | select(.service == "SFU")  | .ip_prefix'      # media servers
```

We announce new address ranges **at least 14 days before they are first used**, and we never remove an address
without announcing it. Subscribe to announcements at `status.example.com` (component "Network ranges").

## A6 · Checking your network

Every class lobby has **Test my connection**. It checks direct UDP, the relay over UDP and TCP, and TLS on port 443,
and names the nearest media region. If something is blocked, press **Copy report** and send it to our support —
it contains the test results and your browser version, but no personal data, IP addresses or credentials.

---

# Part B — internal procedures

## B1 · Handling a customer ticket

1. Ask for the **Copy report** from the lobby network test (Part A6). Verdict mapping:
   `direct` → no network issue; `relay` → level 1 not open (fine); `tls-only` → only level 3 works (fine, mention
   level 2 for quality); `blocked` → nothing works: walk them through A2/A3, usually TLS inspection.
2. If they can run a script inside their network, send them the check from `ops/scripts/check-turn.sh`
   (with credentials minted for the ticket: `mint-ice-credentials.js --ticket <id>`), or run it from a VPN
   endpoint they provide.
3. Record the network type in the ticket; recurring patterns go into `ops/load/ice-matrix.md`.

## B2 · Growing an address pool (announce first)

Addresses are pre-allocated per region (`infra/media-edge/eip-pool.tf`); nodes always take the **lowest free slot**,
so newly added (higher) slots stay unused until the existing ones are busy. That gives time to announce.

1. Decide the new size: SFU ≥ `max_nodes + 1`, TURN ≥ `2 × max_nodes + 1`.
2. Check the regional Elastic IP quota (Service Quotas, "EC2-VPC Elastic IPs") and the security-group rule quota
   (prefix lists count `max_entries` per rule).
3. Change `eip_pool` in `infra/envs/<env>/media-edge.<region>.tfvars`; review; apply.
4. The region's parameter `/<prefix>/media/public-ips/<region>` changes → `publish-ip-ranges` rewrites
   `media-ip-ranges.json` with a new `syncToken` within minutes. Verify:
   `curl -s https://media.example.com/media-ip-ranges.json | jq '.syncToken, (.prefixes | length)'`.
5. Announce on the status page ("Network ranges") with the added prefixes and the date after which they may be used
   (≥ 14 days). Until then, do not raise `max_nodes` into the new slots.
6. Re-apply the other media regions of the environment so their global SFU prefix list includes new SFU addresses.

## B3 · Removing addresses

Only with an announcement ≥ 30 days ahead. The Elastic IPs are protected by `prevent_destroy`; shrinking a pool needs
a reviewed change that removes the guard for that apply. Never release an address that appeared in a published file
without that announcement — schools may have hard-coded it.

## B4 · Adding a media region

Follow the onboarding order in `infra/media-edge/secrets-replica.tf`, then B2 steps 4–6 for the new region's pools.
The new region's addresses appear in the published file as soon as its stack is applied — announce before placing
rooms there (the region only receives rooms once it is listed in `ICE_MEDIA_REGIONS` of the core stack).