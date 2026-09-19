# ICE network matrix

`ops/load/ice-matrix.md` · Owner: F8 Real-Time Connectivity · Environment: **staging** · Cadence: before every
release that touches connectivity (`server/src/rtc/`, `turn/`, `core-client/src/rtc/`, SFU addressing, security groups),
and quarterly.

Proves that a learner can join a live lesson from every kind of network we know schools, companies and homes use —
and that the connection takes the path we expect. The architecture promises this in section 4.2 (connection paths);
this matrix is how we check the promise.

---

## 1 · Expected paths

ICE tries all candidate pairs in parallel and picks the best working one. The SFU is ICE-lite on public Elastic IPs
(one UDP and one TCP port per worker, `40000 + i`), TURN offers UDP 3478, TCP 3478 and TLS 443.

| # | Network | What is blocked or altered | Expected selected path | Lobby network test verdict |
|---|---|---|---|---|
| N1 | Open (home broadband, cone NAT) | nothing | **direct UDP** to SFU | `direct` |
| N2 | Symmetric NAT (many mobile carriers, some enterprise firewalls) | NAT mapping changes per destination | **direct UDP** — the SFU has a public address, so the client's own mapping towards it works; TURN is *not* needed | `direct` |
| N3 | UDP blocked, TCP open | all outbound UDP | **direct TCP** to SFU (ICE-TCP, port `40000 + i`) | `relay` (probe cannot test direct TCP, see note) |
| N4 | Only TCP 80/443 open | everything except web ports | **TURN over TLS 443** | `tls-only` |
| N5 | Only TCP 443 + TLS inspection (SSL decryption) without exemption | TLS to unknown hosts is intercepted | **fails** — the proxy expects HTTPS inside TLS; guidance shown | `blocked` |
| N6 | N5 with `*.<rtc_domain>` exempted from inspection | as N4 | **TURN over TLS 443** | `tls-only` |
| N7 | Explicit web proxy only (no direct egress) | direct TCP and UDP | browser-dependent: TURN/TLS via CONNECT where supported, otherwise fails | `blocked` or `tls-only` |
| N8 | UDP 3478 open, other UDP blocked | UDP to 40000–40063 | **TURN over UDP 3478** | `relay` |
| N9 | Tenant with relay-only policy (`tenant_rtc_policy.ice_transport_policy = 'relay'`), open network | — | **TURN over UDP 3478**, never direct | `relay` |
| N10 | Wi-Fi → cellular handover during a lesson (mobile app) | address change | media resumes ≤ 3 s via `restartIce` (networkMonitor) | — |
| N11 | IPv6-only with NAT64/DNS64 (some carriers) | no native IPv4 | TURN via NAT64 on IPv4 addresses (SFU IPv6 disabled today) | `relay` or `direct` |

Note on N3: the pre-join probe has no SFU connection yet, so it cannot test direct TCP; it reports the relay paths that
work. The real join then prefers direct TCP. Both results are correct.

Pass criteria for every row (except N5 and N7, which pass when the documented failure and guidance appear):
join ≤ 5 s after "Join", audio both ways, teacher video received, own camera sent, screen share received, selected
path as expected, no ICE restart in the first 10 minutes.

---

## 2 · Lab setup

One Linux lab host (staging account, **outside** the media VPC) with network namespaces — one namespace per network
type, each with its own nftables rules. The browser runs headless inside the namespace with fake media.

```bash
# once: namespace + veth pair + NAT towards the host's uplink
sudo ip netns add n4
sudo ip link add veth-n4 type veth peer name veth-n4-ns
sudo ip link set veth-n4-ns netns n4
sudo ip addr add 10.99.4.1/24 dev veth-n4 && sudo ip link set veth-n4 up
sudo ip netns exec n4 ip addr add 10.99.4.2/24 dev veth-n4-ns
sudo ip netns exec n4 ip link set veth-n4-ns up
sudo ip netns exec n4 ip link set lo up
sudo ip netns exec n4 ip route add default via 10.99.4.1
sudo sysctl -w net.ipv4.ip_forward=1
```

Per-network rules (applied in the host's forward chain for the namespace's source range):

| Network | nftables essentials |
|---|---|
| N1 | `masquerade` only (cone-like mapping) |
| N2 | `masquerade random,fully-random` — a new source port per destination behaves like symmetric NAT |
| N3 | `meta l4proto udp ip saddr 10.99.3.0/24 drop` (keep UDP 53 to the lab resolver) |
| N4 | allow `tcp dport { 80, 443 }` and DNS; drop everything else from the range |
| N5 | N4 + transparent TLS interception: `mitmproxy --mode transparent` with its CA installed in the namespace's browser profile; redirect `tcp dport 443` to it |
| N6 | N5 + `--ignore-hosts '.*\.rtc\.example\.com'` (mitmproxy passes these through untouched) |
| N7 | drop all direct egress; run `squid` on the host, browser flag `--proxy-server=http://10.99.7.1:3128` |
| N8 | drop UDP except `udp dport 3478` (and DNS) |
| N11 | IPv6-only namespace + `jool` NAT64 and a DNS64 resolver on the host |

Tear down with `ip netns del <name>` and `nft flush table inet ice-lab`.

---

## 3 · Running a case

Credentials and a lesson: staging test tenant (`ops/scripts/seed.js`), one teacher bot publishing a test pattern from an
open network, learners joining from the namespaces.

```bash
sudo ip netns exec n4 sudo -u lab \
  chromium --headless=new --use-fake-device-for-media-stream --use-fake-ui-for-media-stream \
  --remote-debugging-port=9224 "https://app.staging.example.com/lessons/ice-matrix?autojoin=1"
```

A Playwright script per case (kept with the e2e suite) joins, waits 60 s, then reads from the page:

- the lobby **Copy report** (verdict, checks, region);
- the selected candidate pair of each transport via `RTCPeerConnection.getStats()` — `candidateType` of the local and
  remote candidate and the protocol (`relayProtocol` for relay candidates: `udp`, `tcp` or `tls`);
- `ConnectionQualityBadge` state (`data-level`, `data-relayed`);
- inbound audio and video `packetsReceived` > 0, outbound `packetsSent` > 0.

Mapping from stats to the "Expected selected path" column:

| Local candidate | Remote candidate | Path |
|---|---|---|
| `host` / `srflx` / `prflx`, protocol `udp` | `host` (SFU Elastic IP, 40000+) | direct UDP |
| `host`, protocol `tcp` | `host`, `tcpType: passive` | direct TCP |
| `relay`, `relayProtocol: udp` | SFU host | TURN over UDP 3478 |
| `relay`, `relayProtocol: tcp` | SFU host | TURN over TCP 3478 |
| `relay`, `relayProtocol: tls` | SFU host | TURN over TLS 443 |

Mobile rows (N2 on a real carrier, N10) run on devices: the Expo staging build, a carrier SIM, and a Wi-Fi network
that is switched off mid-lesson. Record the time from Wi-Fi loss to video resuming (networkMonitor logs
`restarting ICE after network change`).

---

## 4 · Results

One row per case and run; keep history. Attach the Copy report and the stats JSON to the release ticket.

| Date | Release | Case | Browser / app | Verdict (lobby) | Selected path | Join time | Pass | Notes |
|---|---|---|---|---|---|---|---|---|
| _yyyy-mm-dd_ | _sha_ | N1 | Chrome _v_ | direct | direct UDP | | | |
| | | N2 | | | | | | |
| | | … | | | | | | |

**A failing row blocks the release** unless the failure is a known browser limitation listed here with a ticket.

Known limitations (keep current):

| Case | Limitation | Customer guidance |
|---|---|---|
| N5 | TLS-inspecting proxies break TURN over TLS by design | Exempt `*.<rtc_domain>` (customer-firewall.md A3) |
| N7 | Proxy-only networks depend on browser support for TURN via CONNECT | Allow direct egress to the published ranges |

---

## 5 · When a case regresses

1. Compare with the last passing run: release diff in `server/src/rtc/`, `turn/`, `core-client/src/rtc/`, SFU
   `WebRtcServerFactory` / `publicAddress`, security groups and prefix lists in `infra/`.
2. Reproduce with `ops/scripts/check-turn.sh` from inside the namespace (TURN side) and `chrome://webrtc-internals`
   (client side).
3. Findings that affect customers go into `ops/runbooks/customer-firewall.md`; incidents follow
   `ops/runbooks/turn-incident.md`.