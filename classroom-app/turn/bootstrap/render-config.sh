#!/usr/bin/env bash
# turn/bootstrap/render-config.sh
#
# Sourced by entrypoint.sh (not executed). Provides:
#
#   resolve_node_identity   who and where this node is: private IP, Elastic IP, node name, hostname, region, AZ
#   render_config           turnserver.conf from the template, the accepted secrets and the denied peers
#   write_node_file         node.json for the agent sidecar (no secrets)
#
# Identity on EC2 (TURN_ADDRESS_SOURCE=imds) comes from IMDSv2 only:
#   local-ipv4                     listening-ip / relay-ip
#   public-ipv4                    external-ip (the Elastic IP)
#   placement/region, /availability-zone, instance-id
#   tags/instance/TurnNodeName     e.g. turn-euc1-07          ┐ written by infra/functions/node-lifecycle after it
#   tags/instance/TurnHostname     turn-euc1-07.<realm>        │ associated the Elastic IP and created the DNS record
#   tags/instance/TurnPublicIp     the Elastic IP it attached  ┘ (launch template: instance_metadata_tags = enabled)
# The script waits until TurnPublicIp equals public-ipv4, i.e. until the Elastic IP is really attached: a node must
# never announce a transient address that clients' ICE candidates and firewall allowlists do not know.
#
# Secrets (TURN_SECRET_SOURCE=secretsmanager): AWSCURRENT (required), AWSPENDING (only during rotation phase 1),
# AWSPREVIOUS (until rotation phase 3). Each becomes one static-auth-secret line; the API signs with AWSCURRENT
# (server/src/rtc/TurnSecretRing.js), so every credential it issues is accepted in every rotation phase.
#
# Owner: F8 Real-Time Connectivity.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "render-config.sh must be sourced by entrypoint.sh" >&2
  exit 64
fi

readonly NODE_NAME_PATTERN='^[a-z0-9-]{3,63}$'
readonly SECRET_PATTERN='^[A-Za-z0-9+/=_.~-]{32,256}$'
readonly IPV4_PATTERN='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

resolve_node_identity() {
  require_env TURN_REALM
  case "${TURN_ADDRESS_SOURCE:-imds}" in
    imds) resolve_from_imds ;;
    static)
      [[ "${TURN_ENV:-production}" == "production" ]] && die "TURN_ADDRESS_SOURCE=static is not allowed in production"
      require_env TURN_PUBLIC_IP TURN_PRIVATE_IP TURN_NODE_NAME TURN_HOSTNAME TURN_REGION TURN_AZ
      TURN_INSTANCE_ID="${TURN_INSTANCE_ID:-static}"
      ;;
    *) die "TURN_ADDRESS_SOURCE must be imds or static" ;;
  esac

  [[ "$TURN_PUBLIC_IP" =~ $IPV4_PATTERN ]] || die "invalid public IPv4 '${TURN_PUBLIC_IP}'"
  [[ "$TURN_PRIVATE_IP" =~ $IPV4_PATTERN ]] || die "invalid private IPv4 '${TURN_PRIVATE_IP}'"
  [[ "$TURN_NODE_NAME" =~ $NODE_NAME_PATTERN ]] || die "invalid node name '${TURN_NODE_NAME}'"
  [[ "$TURN_HOSTNAME" == "${TURN_NODE_NAME}.${TURN_REALM}" ]] \
    || die "hostname '${TURN_HOSTNAME}' must be '${TURN_NODE_NAME}.${TURN_REALM}' (certificate *.${TURN_REALM})"
  export TURN_PUBLIC_IP TURN_PRIVATE_IP TURN_PUBLIC_IPV6="${TURN_PUBLIC_IPV6:-}" TURN_NODE_NAME TURN_HOSTNAME \
         TURN_REGION TURN_AZ TURN_INSTANCE_ID
  log info "node identity: ${TURN_NODE_NAME} ${TURN_PUBLIC_IP} (private ${TURN_PRIVATE_IP}) ${TURN_REGION}/${TURN_AZ}"
}

resolve_from_imds() {
  local deadline=$(( $(date +%s) + ${TURN_BOOTSTRAP_WAIT_S:-300} )) public tagged_ip
  imds_init
  TURN_PRIVATE_IP="$(imds meta-data/local-ipv4)" || die "IMDS: local-ipv4 unavailable"
  TURN_REGION="$(imds meta-data/placement/region)" || die "IMDS: region unavailable"
  TURN_AZ="$(imds meta-data/placement/availability-zone)" || die "IMDS: availability zone unavailable"
  TURN_INSTANCE_ID="$(imds meta-data/instance-id)" || die "IMDS: instance id unavailable"

  while :; do
    public="$(imds meta-data/public-ipv4 2>/dev/null || true)"
    tagged_ip="$(imds meta-data/tags/instance/TurnPublicIp 2>/dev/null || true)"
    TURN_NODE_NAME="$(imds meta-data/tags/instance/TurnNodeName 2>/dev/null || true)"
    TURN_HOSTNAME="$(imds meta-data/tags/instance/TurnHostname 2>/dev/null || true)"
    if [[ -n "$public" && "$public" == "$tagged_ip" && -n "$TURN_NODE_NAME" && -n "$TURN_HOSTNAME" ]]; then
      TURN_PUBLIC_IP="$public"
      break
    fi
    (( $(date +%s) < deadline )) || die "Elastic IP / node tags not ready after ${TURN_BOOTSTRAP_WAIT_S:-300} s (public='${public}', tagged='${tagged_ip}', name='${TURN_NODE_NAME}')"
    log info "waiting for node-lifecycle to attach the Elastic IP and tag the instance"
    sleep 5
  done

  # Optional dual-stack: announce the instance's first IPv6 address if the subnet has one.
  TURN_PUBLIC_IPV6="$(imds meta-data/ipv6 2>/dev/null || true)"
}

load_secrets() {
  local -a secrets=()
  local value stage rc
  case "${TURN_SECRET_SOURCE:-secretsmanager}" in
    secretsmanager)
      require_env TURN_SECRET_ARN
      for stage in AWSCURRENT AWSPENDING AWSPREVIOUS; do
        rc=0
        value="$(secretsmanager_get "$TURN_SECRET_ARN" "$stage")" || rc=$?
        if (( rc == 3 )); then
          [[ "$stage" == "AWSCURRENT" ]] && die "TURN secret has no AWSCURRENT version"
          continue
        fi
        (( rc == 0 )) || die "could not read TURN secret stage ${stage}"
        parse_secret "$value"
        secrets+=("$PARSED_SECRET")
      done
      ;;
    env)
      [[ "${TURN_ENV:-production}" == "production" ]] && die "TURN_SECRET_SOURCE=env is not allowed in production"
      require_env TURN_SECRET_DEV
      parse_secret "$TURN_SECRET_DEV"
      secrets+=("$PARSED_SECRET")
      if [[ -n "${TURN_SECRET_DEV_PREVIOUS:-}" ]]; then
        parse_secret "$TURN_SECRET_DEV_PREVIOUS"
        secrets+=("$PARSED_SECRET")
      fi
      ;;
    *) die "TURN_SECRET_SOURCE must be secretsmanager or env" ;;
  esac

  # Unique, current first (order is irrelevant to coturn but keeps the rendered file stable).
  local -A seen=()
  TURN_STATIC_AUTH_SECRETS=""
  for value in "${secrets[@]}"; do
    [[ -n "${seen[$value]:-}" ]] && continue
    seen[$value]=1
    TURN_STATIC_AUTH_SECRETS+="static-auth-secret=${value}"$'\n'
  done
  TURN_STATIC_AUTH_SECRETS="${TURN_STATIC_AUTH_SECRETS%$'\n'}"
  export TURN_STATIC_AUTH_SECRETS

  # The agent mints its probe credentials with the signing secret, exactly like the API does.
  mkdir -p "${TURN_RUNTIME_DIR}/secrets"
  chmod 0700 "${TURN_RUNTIME_DIR}/secrets"
  printf '%s' "${secrets[0]}" > "${TURN_RUNTIME_DIR}/secrets/current.tmp"
  chmod 0600 "${TURN_RUNTIME_DIR}/secrets/current.tmp"
  mv -f "${TURN_RUNTIME_DIR}/secrets/current.tmp" "${TURN_RUNTIME_DIR}/secrets/current"
  log info "loaded ${#seen[@]} accepted TURN secret version(s)"
}

# Accepts the raw string or {"secret": "..."} — the same two shapes server/src/rtc/TurnSecretRing.js accepts.
# Sets PARSED_SECRET (runs in the current shell so that die() really stops the bootstrap).
parse_secret() {
  local raw="$1"
  PARSED_SECRET=""
  if [[ "$raw" == \{* ]]; then
    PARSED_SECRET="$(jq -er '.secret // .value' <<<"$raw")" || die "TURN secret JSON has no 'secret' field"
  else
    PARSED_SECRET="$raw"
  fi
  [[ "$PARSED_SECRET" =~ $SECRET_PATTERN ]] || die "TURN secret must be 32-256 characters of [A-Za-z0-9+/=_.~-]"
}

render_config() {
  local template="$1" denied_file="$2" output="$3"
  [[ -r "$template" && -r "$denied_file" ]] || die "template or denied-peers file missing in ${TURN_CONFIG_DIR}"

  load_secrets

  export TURN_LISTEN_PORT="${TURN_LISTEN_PORT:-3478}"
  export TURN_TLS_PORT="${TURN_TLS_PORT:-443}"
  export TURN_RELAY_MIN_PORT="${TURN_RELAY_MIN_PORT:-49152}"
  export TURN_RELAY_MAX_PORT="${TURN_RELAY_MAX_PORT:-65535}"
  export TURN_USER_QUOTA="${TURN_USER_QUOTA:-12}"
  export TURN_TOTAL_QUOTA="${TURN_TOTAL_QUOTA:-4000}"
  export TURN_MAX_BPS="${TURN_MAX_BPS:-0}"
  export TURN_BPS_CAPACITY="${TURN_BPS_CAPACITY:-0}"
  export TURN_PROMETHEUS_PORT="${TURN_PROMETHEUS_PORT:-9641}"
  local name
  for name in TURN_LISTEN_PORT TURN_TLS_PORT TURN_RELAY_MIN_PORT TURN_RELAY_MAX_PORT TURN_USER_QUOTA \
              TURN_TOTAL_QUOTA TURN_MAX_BPS TURN_BPS_CAPACITY TURN_PROMETHEUS_PORT; do
    [[ "${!name}" =~ ^[0-9]+$ ]] || die "${name} must be a non-negative integer"
  done
  (( TURN_RELAY_MIN_PORT < TURN_RELAY_MAX_PORT )) || die "relay port range is empty"

  # Only directive lines of the denied-peers file are rendered.
  TURN_DENIED_PEERS="$(grep -E '^denied-peer-ip=' "$denied_file")" || die "denied-peers file has no entries"
  export TURN_DENIED_PEERS

  # Explicit variable list: nothing else in the template is ever substituted (single quotes are intended).
  # shellcheck disable=SC2016
  envsubst '${TURN_REALM} ${TURN_NODE_NAME} ${TURN_PRIVATE_IP} ${TURN_PUBLIC_IP} ${TURN_LISTEN_PORT}
            ${TURN_TLS_PORT} ${TURN_RELAY_MIN_PORT} ${TURN_RELAY_MAX_PORT} ${TURN_STATIC_AUTH_SECRETS}
            ${TURN_TLS_DIR} ${TURN_DENIED_PEERS} ${TURN_USER_QUOTA} ${TURN_TOTAL_QUOTA} ${TURN_MAX_BPS}
            ${TURN_BPS_CAPACITY} ${TURN_PROMETHEUS_PORT} ${TURN_RUNTIME_DIR}' \
    < "$template" > "${output}.tmp"
  chmod 0600 "${output}.tmp"
  mv -f "${output}.tmp" "$output"
  unset TURN_STATIC_AUTH_SECRETS
  log info "rendered ${output}"
}

write_node_file() {
  local output="$1"
  jq -n \
    --arg node "$TURN_NODE_NAME" \
    --arg hostname "$TURN_HOSTNAME" \
    --arg region "$TURN_REGION" \
    --arg az "$TURN_AZ" \
    --arg publicIpv4 "$TURN_PUBLIC_IP" \
    --arg publicIpv6 "${TURN_PUBLIC_IPV6:-}" \
    --arg privateIp "$TURN_PRIVATE_IP" \
    --arg instanceId "$TURN_INSTANCE_ID" \
    --arg realm "$TURN_REALM" \
    --argjson listenPort "$TURN_LISTEN_PORT" \
    --argjson tlsPort "$TURN_TLS_PORT" \
    --argjson relayMin "$TURN_RELAY_MIN_PORT" \
    --argjson relayMax "$TURN_RELAY_MAX_PORT" \
    --argjson maxAllocations "$TURN_TOTAL_QUOTA" \
    --argjson capacityMbps "${TURN_CAPACITY_MBPS:-5000}" \
    --argjson prometheusPort "$TURN_PROMETHEUS_PORT" \
    '{node: $node, hostname: $hostname, region: $region, az: $az,
      publicIpv4: $publicIpv4, publicIpv6: (if $publicIpv6 == "" then null else $publicIpv6 end),
      privateIp: $privateIp, instanceId: $instanceId, realm: $realm,
      ports: {listen: $listenPort, tls: $tlsPort, relayMin: $relayMin, relayMax: $relayMax, prometheus: $prometheusPort},
      maxAllocations: $maxAllocations, capacityMbps: $capacityMbps}' > "${output}.tmp"
  chmod 0600 "${output}.tmp"
  mv -f "${output}.tmp" "$output"
}