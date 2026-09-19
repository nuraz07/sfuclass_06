#!/usr/bin/env bash
# ops/scripts/check-turn.sh
#
# End-to-end check of ONE TURN node, from wherever you run it (laptop, bastion, customer network), the way a client
# uses it. Use it when an alarm names a node, when a customer reports relay problems, or after manual changes.
#
#   1  STUN binding over UDP 3478                       turnutils_stunclient (coturn utilities)
#   2  audited, short-lived credentials                 ops/scripts/mint-ice-credentials.js
#   3  TURN allocation over UDP 3478, TCP 3478, TLS 443 turn/agent/src/selfProbe.js — the same client as the node's
#      + permission for a public peer                   own self-probe, so results are directly comparable
#      + denied peers (VPC, IMDS, loopback, CGNAT) must be refused
#   4  TLS certificate: chain, host name, days left     openssl
#   5  optional relay data path (--peer ip:port)        turnutils_uclient; the peer must be allowed by the TURN
#                                                       security group, i.e. an address of the SFU pool on an SFU
#                                                       RTC port (see ops/load/turn-load.md for running a peer)
#
# Usage:
#   ops/scripts/check-turn.sh --host turn-euc1-07.rtc.example.com --env prod --ticket INC-1234 \
#       --reason "probe failing alarm" --secret-id <TURN secret ARN> [--region eu-central-1]
#   ops/scripts/check-turn.sh --host 192.0.2.2 --hostname turn-dev-01.rtc.test --env dev \
#       --dev-secret-env TURN_SECRET_DEV --tls-port 5349 --ca /run/turn/tls/fullchain.pem
#
# Options:
#   --host H            node host name or IP to connect to
#   --hostname N        TLS host name to verify (default: --host when it is a name)
#   --port P            STUN/TURN port (3478)          --tls-port P    TURN over TLS port (443)
#   --ca FILE           extra CA for TLS verification (development certificates only)
#   --peer IP:PORT      run the relay data-path test against this peer
#   --env / --reason / --ticket / --secret-id / --region / --dev-secret-env   passed to mint-ice-credentials.js
#
# Exit code 0 when every executed check passed, 1 otherwise. Run from the repository root.
# Owner: F8 Real-Time Connectivity.

set -Eeuo pipefail

HOST="" HOSTNAME_TLS="" PORT=3478 TLS_PORT=443 CA="" PEER=""
MINT_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --hostname) HOSTNAME_TLS="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --tls-port) TLS_PORT="$2"; shift 2 ;;
    --ca) CA="$2"; shift 2 ;;
    --peer) PEER="$2"; shift 2 ;;
    --env|--reason|--ticket|--secret-id|--region|--dev-secret-env) MINT_ARGS+=("$1" "$2"); shift 2 ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$HOST" ]] || { echo "--host is required" >&2; exit 2; }
if [[ -z "$HOSTNAME_TLS" && ! "$HOST" =~ ^[0-9.]+$ ]]; then HOSTNAME_TLS="$HOST"; fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
declare -a RESULTS=()
FAILED=0

record() { # record <name> <ok|fail|skip> <detail>
  RESULTS+=("$(printf '%-28s %-5s %s' "$1" "$2" "$3")")
  [[ "$2" == "fail" ]] && FAILED=1
  return 0
}

for tool in node openssl; do
  command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 2; }
done

# ------------------------------------------------------------------ 1 STUN
if command -v turnutils_stunclient >/dev/null; then
  if out="$(timeout 10 turnutils_stunclient -p "$PORT" "$HOST" 2>&1)" && grep -q 'UDP reflexive addr' <<<"$out"; then
    record "stun udp/${PORT}" ok "$(grep -m1 -o 'UDP reflexive addr: [^ ]*' <<<"$out" | cut -d' ' -f4)"
  else
    record "stun udp/${PORT}" fail "no binding response (UDP ${PORT} blocked or node down)"
  fi
else
  record "stun udp/${PORT}" skip "turnutils_stunclient not installed (apt install coturn-utils / coturn)"
fi

# ------------------------------------------------------------------ 2 credentials
[[ " ${MINT_ARGS[*]} " == *" --reason "* ]] || MINT_ARGS+=(--reason "check-turn.sh against ${HOST}")
CREDS="$(node "${REPO_ROOT}/ops/scripts/mint-ice-credentials.js" "${MINT_ARGS[@]}" --ttl 300 --format json 2>/dev/null)" || {
  # Re-run to show the reason (audit or permission failures) instead of guessing.
  node "${REPO_ROOT}/ops/scripts/mint-ice-credentials.js" "${MINT_ARGS[@]}" --ttl 300 --format json >/dev/null || true
  echo "could not mint credentials" >&2
  exit 1
}
TURN_USERNAME="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).username)' "$CREDS")"
TURN_CREDENTIAL="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).credential)' "$CREDS")"
record "credentials" ok "expires $(node -e 'process.stdout.write(JSON.parse(process.argv[1]).expiresAt)' "$CREDS")"

# ------------------------------------------------------------------ 3 TURN allocations
for transport in udp tcp tls; do
  port="$PORT"; [[ "$transport" == "tls" ]] && port="$TLS_PORT"
  if [[ "$transport" == "tls" && -z "$HOSTNAME_TLS" ]]; then
    record "turn ${transport}/${port}" skip "no --hostname to verify the certificate against"
    continue
  fi
  # shellcheck disable=SC2016  # the JavaScript below is meant to be passed literally
  if detail="$(cd "$REPO_ROOT" && TRANSPORT="$transport" TURN_HOST="$HOST" TURN_PORT="$port" TLS_NAME="$HOSTNAME_TLS" TLS_CA="$CA" \
      TURN_USERNAME="$TURN_USERNAME" TURN_CREDENTIAL="$TURN_CREDENTIAL" node --input-type=module -e '
        import { readFileSync } from "node:fs";
        import { probeTransport } from "./turn/agent/src/selfProbe.js";
        const e = process.env;
        try {
          const r = await probeTransport({
            transport: e.TRANSPORT, host: e.TURN_HOST, port: Number(e.TURN_PORT),
            servername: e.TLS_NAME || undefined, ca: e.TLS_CA ? readFileSync(e.TLS_CA) : undefined,
            username: e.TURN_USERNAME, password: e.TURN_CREDENTIAL, peerIp: "1.1.1.1", timeoutMs: 5000,
          });
          console.log(`relayed ${r.relayed.address}:${r.relayed.port} in ${r.rttMs} ms, denied peers refused`);
        } catch (err) {
          console.log(`${err.code ?? ""} ${err.message}`.trim());
          process.exit(1);
        }' 2>&1)"; then
    record "turn ${transport}/${port}" ok "$detail"
  else
    record "turn ${transport}/${port}" fail "$detail"
  fi
done

# ------------------------------------------------------------------ 4 TLS certificate
if [[ -n "$HOSTNAME_TLS" ]]; then
  verify_args=(-verify_return_error -verify_hostname "$HOSTNAME_TLS")
  [[ -n "$CA" ]] && verify_args+=(-CAfile "$CA")
  if pem="$(timeout 10 openssl s_client -connect "${HOST}:${TLS_PORT}" -servername "$HOSTNAME_TLS" "${verify_args[@]}" </dev/null 2>/dev/null \
            | openssl x509 2>/dev/null)" && [[ -n "$pem" ]]; then
    end="$(openssl x509 -noout -enddate <<<"$pem" | cut -d= -f2)"
    days=$(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
    if (( days < 21 )); then
      record "tls certificate" fail "expires in ${days} days (${end}) — check infra/functions/acme-renewer"
    else
      record "tls certificate" ok "valid for ${days} days, chain and host name verified"
    fi
  else
    record "tls certificate" fail "handshake or verification failed (TLS inspection in this network? expired?)"
  fi
fi

# ------------------------------------------------------------------ 5 relay data path (optional)
if [[ -n "$PEER" ]]; then
  if command -v turnutils_uclient >/dev/null; then
    peer_ip="${PEER%:*}" peer_port="${PEER##*:}"
    out="$(timeout 60 turnutils_uclient -c -X -n 200 -l 1200 -z 20 -m 1 -e "$peer_ip" -r "$peer_port" \
            -u "$TURN_USERNAME" -w "$TURN_CREDENTIAL" -p "$PORT" "$HOST" 2>&1 || true)"
    sent="$(grep -o 'Total transmit time is [0-9]*' <<<"$out" | head -1 || true)"
    lost="$(grep -o 'Total lost packets [0-9]* ([0-9.]*%)' <<<"$out" | head -1 || true)"
    if [[ -n "$lost" && "$lost" =~ \(0(\.0+)?%\) ]]; then
      record "relay data path" ok "200 × 1200 B to ${PEER}: ${lost}"
    else
      record "relay data path" fail "${lost:-no result} ${sent} (is ${PEER} in the SFU prefix list and listening?)"
    fi
  else
    record "relay data path" skip "turnutils_uclient not installed"
  fi
fi

# ------------------------------------------------------------------ summary
printf '\nTURN check of %s\n' "$HOST"
printf '%s\n' "${RESULTS[@]}"
exit "$FAILED"