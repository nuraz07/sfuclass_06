#!/usr/bin/env bash
# classroom-app/ops/scripts/smoke.sh
#
# Smoke test  (F1, F4, F6, F8)  [EXT]
#
# Proves that a deployment can actually carry a lesson, in the order the product
# needs it: sign in, open a room, say something, move a file, and reach the media
# plane on a relayed path.
#
# The last check is the version 7 addition and the one that catches the failures
# nobody notices otherwise. A broken TURN path is invisible from the office,
# where UDP to the SFU works; it only shows up for the learner behind a school
# firewall. Forcing relay here makes that path a release gate
# (.github/workflows/e2e-smoke.yml, step 3 of the deployment process).
#
# Usage:
#   ops/scripts/smoke.sh --env staging
#   ops/scripts/smoke.sh --api https://api.example.com --ws wss://ws.example.com
#   SMOKE_EMAIL=… SMOKE_PASSWORD=… ops/scripts/smoke.sh --env prod --skip-upload
#
# Exit codes: 0 all checks passed · 1 a check failed · 2 bad usage or missing tool

set -euo pipefail

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

ENVIRONMENT="${SMOKE_ENV:-staging}"
API_URL="${SMOKE_API_URL:-}"
WS_URL="${SMOKE_WS_URL:-}"
EMAIL="${SMOKE_EMAIL:-}"
PASSWORD="${SMOKE_PASSWORD:-}"
SKIP_UPLOAD=0
SKIP_RELAY=0
TIMEOUT=20

usage() {
  sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENVIRONMENT="$2"; shift 2 ;;
    --api) API_URL="$2"; shift 2 ;;
    --ws) WS_URL="$2"; shift 2 ;;
    --skip-upload) SKIP_UPLOAD=1; shift ;;
    --skip-relay) SKIP_RELAY=1; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done

: "${API_URL:=https://api.${ENVIRONMENT}.example.com}"
: "${WS_URL:=wss://ws.${ENVIRONMENT}.example.com}"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; DIM=""; RESET=""
fi

FAILED=0
STEP=0

pass() { printf '%s  ok %s%s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '%s  ~~ %s%s\n' "$YELLOW" "$RESET" "$1"; }
fail() { printf '%s  XX %s%s\n' "$RED" "$RESET" "$1"; FAILED=1; }
step() { STEP=$((STEP + 1)); printf '\n%s[%d] %s%s\n' "$DIM" "$STEP" "$1" "$RESET"; }
die()  { printf '%s  XX %s%s\n' "$RED" "$RESET" "$1"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 2; }; }
need curl
need jq

WORKDIR="$(mktemp -d)"
ROOM_ID=""
ACCESS_TOKEN=""

cleanup() {
  # Leave nothing behind in a real environment, even after a failure.
  if [[ -n "$ROOM_ID" && -n "$ACCESS_TOKEN" ]]; then
    api DELETE "/rooms/$ROOM_ID" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# HTTP helper: METHOD PATH [BODY] -> body on stdout, HTTP status in $HTTP_STATUS
# ---------------------------------------------------------------------------

HTTP_STATUS=0

api() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -m "$TIMEOUT" -X "$method" -H 'content-type: application/json'
              -w '\n%{http_code}' "${API_URL}${path}")

  [[ -n "$ACCESS_TOKEN" ]] && args+=(-H "authorization: Bearer ${ACCESS_TOKEN}")
  [[ -n "$body" ]] && args+=(-d "$body")

  local response
  response="$(curl "${args[@]}")" || { HTTP_STATUS=0; return 1; }

  HTTP_STATUS="${response##*$'\n'}"
  printf '%s' "${response%$'\n'*}"
}

expect_status() {
  local expected="$1" what="$2"
  if [[ "$HTTP_STATUS" == "$expected" ]]; then
    pass "$what"
    return 0
  fi
  fail "$what (HTTP $HTTP_STATUS)"
  return 1
}

printf '%sSmoke test · %s · %s%s\n' "$DIM" "$ENVIRONMENT" "$API_URL" "$RESET"

# ---------------------------------------------------------------------------
# 1. Health
# ---------------------------------------------------------------------------

step "health"

api GET /healthz >/dev/null || true
expect_status 200 "/healthz answers" || die "the API is not up; nothing else is worth testing"

READY="$(api GET /readyz || true)"
if [[ "$HTTP_STATUS" == "200" ]]; then
  pass "/readyz: dependencies reachable"
else
  fail "/readyz (HTTP $HTTP_STATUS): $(printf '%s' "$READY" | jq -rc '.checks // .' 2>/dev/null || true)"
  die "dependencies are not ready"
fi

RELEASE="$(api GET /healthz | jq -r '.release // "unknown"')"
printf '%s      release %s%s\n' "$DIM" "$RELEASE" "$RESET"

# ---------------------------------------------------------------------------
# 2. Login (F5)
# ---------------------------------------------------------------------------

step "login"

[[ -n "$EMAIL" && -n "$PASSWORD" ]] || die "SMOKE_EMAIL and SMOKE_PASSWORD are required"

LOGIN="$(api POST /auth/login "$(jq -nc --arg e "$EMAIL" --arg p "$PASSWORD" \
  '{email:$e,password:$p}')" || true)"

if [[ "$HTTP_STATUS" != "200" ]]; then
  fail "login (HTTP $HTTP_STATUS)"
  die "without a token the rest of the run is meaningless"
fi

ACCESS_TOKEN="$(printf '%s' "$LOGIN" | jq -r '.accessToken // empty')"
[[ -n "$ACCESS_TOKEN" ]] || die "login returned no access token"
USER_ID="$(printf '%s' "$LOGIN" | jq -r '.user.id // "unknown"')"
pass "signed in as $USER_ID"

# ---------------------------------------------------------------------------
# 3. Room (F1)
# ---------------------------------------------------------------------------

step "classroom"

ROOM="$(api POST /rooms "$(jq -nc --arg n "smoke $(date -u +%FT%TZ)" \
  '{name:$n,mode:"seminar"}')" || true)"

if expect_status 201 "room created"; then
  ROOM_ID="$(printf '%s' "$ROOM" | jq -r '.roomId')"
  printf '%s      room %s%s\n' "$DIM" "$ROOM_ID" "$RESET"
else
  die "cannot open a room"
fi

# Placement is returned on join, not over HTTP: clients never resolve nodes
# (v7, Appendix A #6). The ops route only proves the registry agrees.
PLACEMENT="$(api GET "/rooms/$ROOM_ID/node" || true)"
case "$HTTP_STATUS" in
  200) pass "registry knows the room: $(printf '%s' "$PLACEMENT" | jq -r '.region // "?"')" ;;
  403|404) warn "route-resolve is ops-only here (HTTP $HTTP_STATUS) — expected outside the VPC" ;;
  *) fail "route-resolve (HTTP $HTTP_STATUS)" ;;
esac

# ---------------------------------------------------------------------------
# 4. Chat (F6)
# ---------------------------------------------------------------------------

step "chat"

CONVERSATION="$(api POST /messaging/conversations "$(jq -nc --arg u "$USER_ID" \
  '{participantIds:[$u]}')" || true)"

if expect_status 200 "conversation opened"; then
  CONVERSATION_ID="$(printf '%s' "$CONVERSATION" | jq -r '.conversationId')"

  api POST /messaging/messages "$(jq -nc --arg c "$CONVERSATION_ID" --arg k "smoke-$RANDOM$RANDOM" \
    '{conversationId:$c,body:"smoke test",dedupeKey:$k}')" >/dev/null || true
  expect_status 201 "message sent" || true

  HISTORY="$(api GET "/messaging/messages?conversationId=${CONVERSATION_ID}&limit=1" || true)"
  COUNT="$(printf '%s' "$HISTORY" | jq -r '.items | length // 0')"
  [[ "$COUNT" -ge 1 ]] && pass "message readable from history" || fail "message did not come back"
fi

# ---------------------------------------------------------------------------
# 5. Upload (F4)
# ---------------------------------------------------------------------------

if [[ "$SKIP_UPLOAD" == "1" ]]; then
  step "upload (skipped)"
else
  step "upload"

  FILE="$WORKDIR/smoke.txt"
  head -c 1024 /dev/urandom | base64 > "$FILE"
  SIZE="$(wc -c < "$FILE" | tr -d ' ')"

  PRESIGN="$(api POST /media/uploads "$(jq -nc --arg s "$SIZE" \
    '{filename:"smoke.txt",contentType:"text/plain",sizeBytes:($s|tonumber),purpose:"chat-attachment"}')" || true)"

  if expect_status 201 "presigned upload issued"; then
    UPLOAD_URL="$(printf '%s' "$PRESIGN" | jq -r '.url // .parts[0].url')"
    ASSET_ID="$(printf '%s' "$PRESIGN" | jq -r '.assetId')"

    if curl -sS -m "$TIMEOUT" -X PUT -H 'content-type: text/plain' \
         --upload-file "$FILE" "$UPLOAD_URL" >/dev/null; then
      pass "object uploaded to the raw bucket"
    else
      fail "upload to S3 failed"
    fi

    api POST "/media/uploads/${ASSET_ID}/complete" '{}' >/dev/null || true
    expect_status 200 "upload completed" || true

    # Quarantine → scan → ready. A few seconds in staging; do not wait forever.
    for _ in $(seq 1 10); do
      STATE="$(api GET "/media/assets/${ASSET_ID}" | jq -r '.status // "unknown"')"
      [[ "$STATE" == "ready" ]] && break
      sleep 2
    done
    [[ "$STATE" == "ready" ]] && pass "asset scanned and ready" || warn "asset still $STATE (antivirus may be async here)"
  fi
fi

# ---------------------------------------------------------------------------
# 6. Forced relay (F8)
# ---------------------------------------------------------------------------

if [[ "$SKIP_RELAY" == "1" ]]; then
  step "forced relay (skipped)"
else
  step "forced relay over TURN"

  ICE="$(api POST /rtc/ice-servers "$(jq -nc --arg r "$ROOM_ID" \
    '{roomId:$r,iceTransportPolicy:"relay"}')" || true)"

  if expect_status 200 "ICE configuration issued"; then
    URL_COUNT="$(printf '%s' "$ICE" | jq '[.iceServers[].urls[]] | length')"
    POLICY="$(printf '%s' "$ICE" | jq -r '.iceTransportPolicy')"
    EXPIRES="$(printf '%s' "$ICE" | jq -r '.expiresAt')"

    # Five is the cap: one STUN, three transports on the primary node, TLS 443
    # on a backup. More only slows candidate gathering.
    [[ "$URL_COUNT" -ge 1 && "$URL_COUNT" -le 5 ]] \
      && pass "$URL_COUNT ICE URLs, policy $POLICY, valid until $EXPIRES" \
      || fail "unexpected ICE URL count: $URL_COUNT"

    # TLS 443 is the path that gets a learner out of a school or a hotel.
    printf '%s' "$ICE" | jq -e '[.iceServers[].urls[]] | map(select(startswith("turns:"))) | length > 0' >/dev/null \
      && pass "TURN over TLS 443 offered" \
      || fail "no turns: URL — restrictive networks cannot connect"

    printf '%s' "$ICE" | jq -e '.iceServers[] | select(.credential != null) | .username | test("^[0-9]+:")' >/dev/null \
      && pass "credential is a TURN REST username (expiry:opaqueId)" \
      || fail "credential does not follow the TURN REST scheme"

    # The real thing: allocate on the node we were handed. turnutils_uclient
    # ships with coturn; without it this is a config check only.
    if command -v turnutils_uclient >/dev/null 2>&1; then
      TURN_HOST="$(printf '%s' "$ICE" | jq -r '[.iceServers[].urls[]] | map(select(startswith("turn:"))) | .[0]' \
        | sed -E 's#^turn:##; s#[:?].*$##')"
      TURN_USER="$(printf '%s' "$ICE" | jq -r '[.iceServers[] | select(.credential != null)][0].username')"
      TURN_PASS="$(printf '%s' "$ICE" | jq -r '[.iceServers[] | select(.credential != null)][0].credential')"

      if turnutils_uclient -T -u "$TURN_USER" -w "$TURN_PASS" -p 3478 -n 2 -c "$TURN_HOST" >/dev/null 2>&1; then
        pass "relayed packets reached $TURN_HOST"
      else
        fail "TURN allocation failed against $TURN_HOST"
      fi
    else
      warn "turnutils_uclient not installed — allocation not verified (e2e-smoke.yml runs it)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

printf '\n'
if [[ "$FAILED" == "0" ]]; then
  printf '%sall checks passed · %s · release %s%s\n' "$GREEN" "$ENVIRONMENT" "$RELEASE" "$RESET"
  exit 0
fi

printf '%ssmoke test failed · %s · release %s%s\n' "$RED" "$ENVIRONMENT" "$RELEASE" "$RESET"
printf '%sdo not promote this build; see ops/runbooks/rollback.md%s\n' "$DIM" "$RESET"
exit 1