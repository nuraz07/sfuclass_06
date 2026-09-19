#!/usr/bin/env bash
# turn/bootstrap/fetch-tls.sh
#
# Sourced by entrypoint.sh (not executed). Provides fetch_tls, which places the certificate and key for
# TURN over TLS (port 443) into ${TURN_TLS_DIR} (tmpfs, 0600):
#
#   fullchain.pem   leaf + intermediates for *.<realm>
#   privkey.pem     matching private key
#
# Sources:
#   TURN_TLS_SOURCE=secretsmanager (staging, production)
#     Secret TURN_TLS_SECRET_ARN, stage AWSCURRENT, JSON:
#       { "fullchain": "-----BEGIN CERTIFICATE-----…", "privkey": "-----BEGIN PRIVATE KEY-----…",
#         "notAfter": "2026-12-01T00:00:00Z" }
#     Written by infra/functions/acme-renewer (ACME DNS-01 on Route 53) and replicated to every media region by
#     infra/media-edge/secrets-replica.tf. ACM cannot be used: coturn needs the key on the instance.
#     Renewal 30 days before expiry triggers deploy-turn.yml (reason tls-renewal), which refreshes every node.
#   TURN_TLS_SOURCE=selfsigned (development only)
#     A throwaway certificate for the node hostname, valid 30 days — for docker-compose.dev.yml and tests.
#
# entrypoint.sh validates the result (key matches certificate, hostname covered, > 7 days validity).
#
# Owner: F8 Real-Time Connectivity (+ security review).

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "fetch-tls.sh must be sourced by entrypoint.sh" >&2
  exit 64
fi

fetch_tls() {
  local fullchain="${TURN_TLS_DIR}/fullchain.pem" privkey="${TURN_TLS_DIR}/privkey.pem"
  mkdir -p "$TURN_TLS_DIR"
  chmod 0700 "$TURN_TLS_DIR"

  case "${TURN_TLS_SOURCE:-secretsmanager}" in
    secretsmanager)
      require_env TURN_TLS_SECRET_ARN
      local payload rc=0
      payload="$(secretsmanager_get "$TURN_TLS_SECRET_ARN" AWSCURRENT)" || rc=$?
      (( rc == 0 )) || die "TURN TLS secret unavailable (stage AWSCURRENT)"
      jq -e 'has("fullchain") and has("privkey")' <<<"$payload" >/dev/null \
        || die "TURN TLS secret must be JSON with 'fullchain' and 'privkey'"
      write_private "$fullchain" "$(jq -r '.fullchain' <<<"$payload")"
      write_private "$privkey" "$(jq -r '.privkey' <<<"$payload")"
      unset payload
      ;;
    selfsigned)
      [[ "${TURN_ENV:-production}" == "development" ]] || die "TURN_TLS_SOURCE=selfsigned is only allowed with TURN_ENV=development"
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 \
        -subj "/CN=${TURN_HOSTNAME}" \
        -addext "subjectAltName=DNS:${TURN_HOSTNAME},DNS:*.${TURN_REALM},IP:${TURN_PRIVATE_IP}" \
        -keyout "${privkey}.tmp" -out "${fullchain}.tmp" 2>/dev/null || die "could not create self-signed certificate"
      chmod 0600 "${privkey}.tmp" "${fullchain}.tmp"
      mv -f "${privkey}.tmp" "$privkey"
      mv -f "${fullchain}.tmp" "$fullchain"
      log warn "using a self-signed TLS certificate (development only)"
      ;;
    *) die "TURN_TLS_SOURCE must be secretsmanager or selfsigned" ;;
  esac

  local not_after
  not_after="$(openssl x509 -in "$fullchain" -noout -enddate 2>/dev/null | cut -d= -f2)" || die "certificate is not valid PEM"
  log info "TLS certificate for ${TURN_HOSTNAME} valid until ${not_after}"
}

# write_private <path> <content>: atomic write, never world-readable, trailing newline normalised.
write_private() {
  local path="$1" content="$2"
  [[ "$content" == *"-----BEGIN "* ]] || die "$(basename "$path") is not PEM"
  printf '%s\n' "${content%$'\n'}" > "${path}.tmp"
  chmod 0600 "${path}.tmp"
  mv -f "${path}.tmp" "$path"
}