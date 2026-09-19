#!/usr/bin/env bash
# turn/bootstrap/entrypoint.sh
#
# Entrypoint of the turn image (turn/Dockerfile). The same image runs both containers of a TURN task:
#
#   entrypoint.sh coturn     (default)  fetch TLS material, render + validate the config, exec turnserver
#   entrypoint.sh agent                 wait for the node description written by "coturn", exec the agent
#   entrypoint.sh check                 render + validate only, print the config with secrets masked, exit
#
# Both containers mount the task volume "turn-runtime" at TURN_RUNTIME_DIR (/run/turn, tmpfs, uid 10001).
# Nothing is written anywhere else: the root filesystem is read-only.
#
# Environment (production values come from the ECS task definition, infra/modules/turn-node-pool):
#   TURN_ENV                 production | staging | development
#   TURN_REALM               rtc.example.com (must equal the realm clients use; also the certificate domain)
#   TURN_ADDRESS_SOURCE      imds (EC2) | static (docker-compose.dev.yml, tests)
#   TURN_SECRET_SOURCE       secretsmanager | env
#   TURN_TLS_SOURCE          secretsmanager | selfsigned (development only)
#   TURN_SECRET_ARN          Secrets Manager ARN of the TURN shared secret (regional replica)
#   TURN_TLS_SECRET_ARN      Secrets Manager ARN of {"fullchain": "...", "privkey": "..."} (acme-renewer)
#   TURN_SECRETSMANAGER_ENDPOINT  optional override (tests); VPC interface endpoints use the default name
#   TURN_LISTEN_PORT=3478 TURN_TLS_PORT=443 TURN_RELAY_MIN_PORT=49152 TURN_RELAY_MAX_PORT=65535
#   TURN_USER_QUOTA=12 TURN_TOTAL_QUOTA=4000 TURN_MAX_BPS=0 TURN_BPS_CAPACITY=0 TURN_PROMETHEUS_PORT=9641
#   TURN_CAPACITY_MBPS       sustained NIC baseline of the instance type, published for the selector
#   static mode only:        TURN_PUBLIC_IP TURN_PRIVATE_IP TURN_NODE_NAME TURN_HOSTNAME TURN_REGION TURN_AZ
#   env secret mode only:    TURN_SECRET_DEV [TURN_SECRET_DEV_PREVIOUS]
#
# Owner: F8 Real-Time Connectivity.

set -Eeuo pipefail
umask 077

BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BOOTSTRAP_DIR
readonly TURN_CONFIG_DIR="${TURN_CONFIG_DIR:-/etc/turn}"
export TURN_RUNTIME_DIR="${TURN_RUNTIME_DIR:-/run/turn}"
export TURN_TLS_DIR="${TURN_RUNTIME_DIR}/tls"
readonly NODE_FILE="${TURN_RUNTIME_DIR}/node.json"
readonly CONFIG_FILE="${TURN_RUNTIME_DIR}/turnserver.conf"

# ------------------------------------------------------------------ shared helpers (used by the sourced scripts)

log() {
  # JSON lines, same shape as the rest of the platform; never pass secrets to this function.
  local level="$1"; shift
  printf '{"level":"%s","service":"turn-bootstrap","msg":%s,"time":"%s"}\n' \
    "$level" "$(jq -Rn --arg m "$*" '$m')" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
}

die() {
  log fatal "$*"
  exit 1
}

require_env() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || die "missing required environment variable ${name}"
  done
}

# IMDSv2: session token first (instances are launched with http_tokens=required). imds_init runs in the
# current shell so the token is reused by every later imds call, including those in command substitutions.
IMDS_TOKEN=""
imds_init() {
  IMDS_TOKEN="$(curl -fsS --max-time 2 --retry 3 -X PUT 'http://169.254.169.254/latest/api/token' \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')" || die "IMDSv2 token request failed"
}
imds() {
  [[ -n "$IMDS_TOKEN" ]] || return 1
  curl -fsS --max-time 2 --retry 2 -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
    "http://169.254.169.254/latest/${1}"
}

# Task role credentials from the ECS container credentials endpoint (works with host networking).
# Honours the two standard variables the AWS SDKs use: *_RELATIVE_URI (ECS) and *_FULL_URI.
aws_credentials() {
  if [[ -n "${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI:-}" ]]; then
    curl -fsS --max-time 3 --retry 3 "http://169.254.170.2${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI}"
  elif [[ -n "${AWS_CONTAINER_CREDENTIALS_FULL_URI:-}" ]]; then
    curl -fsS --max-time 3 --retry 3 "${AWS_CONTAINER_CREDENTIALS_FULL_URI}"
  else
    die "no task role credentials available"
  fi
}

# secretsmanager_get <secret-id> <version-stage>
# Prints SecretString; returns 3 when the stage does not exist (ResourceNotFoundException).
# Uses curl's built-in SigV4 signing, so the image needs no AWS CLI.
secretsmanager_get() {
  local secret_id="$1" stage="$2" region creds response http_code body
  region="${TURN_REGION:?TURN_REGION must be known before reading secrets}"
  creds="$(aws_credentials)"
  response="$(curl -sS --max-time 5 --retry 2 -w '\n%{http_code}' \
    --aws-sigv4 "aws:amz:${region}:secretsmanager" \
    --user "$(jq -r '.AccessKeyId' <<<"$creds"):$(jq -r '.SecretAccessKey' <<<"$creds")" \
    -H "x-amz-security-token: $(jq -r '.Token' <<<"$creds")" \
    -H 'Content-Type: application/x-amz-json-1.1' \
    -H 'X-Amz-Target: secretsmanager.GetSecretValue' \
    --data "$(jq -cn --arg id "$secret_id" --arg stage "$stage" '{SecretId: $id, VersionStage: $stage}')" \
    "${TURN_SECRETSMANAGER_ENDPOINT:-https://secretsmanager.${region}.amazonaws.com}/")" || die "Secrets Manager request failed (${stage})"
  http_code="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [[ "$http_code" == "200" ]]; then
    jq -er '.SecretString' <<<"$body"
    return 0
  fi
  if [[ "$(jq -r '.__type // empty' <<<"$body" 2>/dev/null)" == *ResourceNotFoundException* ]]; then
    return 3
  fi
  die "Secrets Manager returned HTTP ${http_code} for stage ${stage}: $(jq -r '.__type // "unknown"' <<<"$body" 2>/dev/null)"
}

# ------------------------------------------------------------------ validation

validate_config() {
  local file="$1" directive
  [[ -s "$file" ]] || die "rendered config ${file} is empty"
  # No placeholder may survive rendering (comments excluded). Single quotes are intended: literal "${".
  # shellcheck disable=SC2016
  if grep -v '^[[:space:]]*#' "$file" | grep -q '\${'; then
    die "unrendered placeholder in ${file}: $(grep -v '^[[:space:]]*#' "$file" | grep -o '\${[A-Z_]*}' | sort -u | tr '\n' ' ')"
  fi
  for directive in realm listening-ip relay-ip external-ip listening-port tls-listening-port use-auth-secret \
                   static-auth-secret cert pkey no-tlsv1 no-tlsv1_1 no-tcp-relay no-multicast-peers \
                   denied-peer-ip user-quota total-quota no-cli; do
    grep -Eq "^${directive}(=|$)" "$file" || die "required directive '${directive}' missing from ${file}"
  done
  local secrets
  secrets="$(grep -c '^static-auth-secret=' "$file")"
  (( secrets >= 1 && secrets <= 3 )) || die "expected 1-3 static-auth-secret lines, found ${secrets}"
  if grep -Eq '^(allow-loopback-peers|no-auth|lt-cred-mech)' "$file"; then
    die "forbidden directive present in ${file}"
  fi

  # TLS material: readable, key matches certificate, not expiring within 7 days.
  [[ -r "${TURN_TLS_DIR}/fullchain.pem" && -r "${TURN_TLS_DIR}/privkey.pem" ]] || die "TLS certificate or key missing"
  openssl x509 -in "${TURN_TLS_DIR}/fullchain.pem" -noout -checkend $((7 * 24 * 3600)) >/dev/null \
    || die "TLS certificate expires within 7 days — check infra/functions/acme-renewer"
  local cert_pub key_pub
  cert_pub="$(openssl x509 -in "${TURN_TLS_DIR}/fullchain.pem" -noout -pubkey | openssl sha256)"
  key_pub="$(openssl pkey -in "${TURN_TLS_DIR}/privkey.pem" -pubout | openssl sha256)"
  [[ "$cert_pub" == "$key_pub" ]] || die "TLS private key does not match the certificate"
  if [[ "${TURN_ENV:-production}" != "development" ]]; then
    openssl x509 -in "${TURN_TLS_DIR}/fullchain.pem" -noout -checkhost "${TURN_HOSTNAME}" | grep -q 'does match' \
      || die "TLS certificate does not cover ${TURN_HOSTNAME}"
  fi
}

# ------------------------------------------------------------------ modes

prepare() {
  mkdir -p "$TURN_RUNTIME_DIR" "$TURN_TLS_DIR"
  chmod 0700 "$TURN_RUNTIME_DIR" "$TURN_TLS_DIR"
  # shellcheck source=render-config.sh
  source "${BOOTSTRAP_DIR}/render-config.sh"
  # shellcheck source=fetch-tls.sh
  source "${BOOTSTRAP_DIR}/fetch-tls.sh"
  resolve_node_identity
  fetch_tls
  render_config "${TURN_CONFIG_DIR}/turnserver.conf.tmpl" "${TURN_CONFIG_DIR}/denied-peers.conf" "$CONFIG_FILE"
  validate_config "$CONFIG_FILE"
  write_node_file "$NODE_FILE"
}

run_coturn() {
  prepare
  log info "starting coturn ${TURN_NODE_NAME} (${TURN_PUBLIC_IP}) in ${TURN_REGION}/${TURN_AZ}"
  exec turnserver -c "$CONFIG_FILE"
}

run_agent() {
  local waited=0
  # The coturn container writes node.json after its bootstrap; ECS dependsOn(START) orders the containers,
  # this wait covers the bootstrap itself (EIP association can take up to a few minutes on a fresh instance).
  until [[ -s "$NODE_FILE" && -s "${TURN_RUNTIME_DIR}/secrets/current" ]]; do
    (( waited < 600 )) || die "node description not written by the coturn container after 600 s"
    sleep 2
    waited=$((waited + 2))
  done
  export TURN_NODE_FILE="$NODE_FILE"
  export TURN_PROBE_SECRET_FILE="${TURN_RUNTIME_DIR}/secrets/current"
  exec node /opt/turn-agent/agent.mjs
}

run_check() {
  prepare
  sed -E 's/^(static-auth-secret=).*/\1********/' "$CONFIG_FILE"
  log info "configuration valid"
}

case "${1:-coturn}" in
  coturn) run_coturn ;;
  agent) run_agent ;;
  check) run_check ;;
  *) die "unknown mode '${1}' (expected: coturn | agent | check)" ;;
esac