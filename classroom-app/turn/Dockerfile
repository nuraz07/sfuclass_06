# syntax=docker/dockerfile:1.7
#
# turn/Dockerfile
#
# Image of a TURN node. One image, two containers in the same ECS task (infra/modules/turn-node-pool):
#
#   "coturn"      entrypoint.sh coturn  → fetch TLS, render + validate config, exec turnserver (STUN/TURN 3478, TLS 443)
#   "turn-agent"  entrypoint.sh agent   → self-probe, TURN registry heartbeat, metrics bridge, drain, /healthz
#
# Contents: coturn 4.6.x (official Debian image), Node.js 22 (agent only, copied from the official Node image),
# the bundled agent (/opt/turn-agent/agent.mjs, no node_modules), bash/curl/jq/envsubst/openssl for the bootstrap
# (curl signs Secrets Manager requests itself: no AWS CLI in the image), tini as PID 1.
#
# Build (build-images.yml; context = repository root because the agent is an npm workspace):
#   docker buildx build -f turn/Dockerfile -t <ecr>/classroom/turn:<sha> .
#
# Pinning: both base images are referenced by tag here and pinned to a digest by Renovate
# (renovate.json: docker:pinDigests; coturn updates need Dependency Dashboard approval and a staging soak).
# build-images.yml records the resolved digests in the SBOM.
#
# Runtime contract (task definition):
#   network mode host · user 10001:10001 (image default) · readonlyRootFilesystem true
#   volume "turn-runtime" at /run/turn in BOTH containers: dockerVolumeConfiguration scope=task, driver=local,
#     driverOpts { type=tmpfs, device=tmpfs, o="size=16m,uid=10001,gid=10001,mode=0700" }
#   coturn binds 443 as non-root through a file capability (cap_net_bind_service on turnserver); therefore the
#     coturn container must not set dockerSecurityOptions "no-new-privileges" and must keep NET_BIND_SERVICE in
#     its capability set (Docker default). All other capabilities can be dropped.
#   "turn-agent": dependsOn coturn (START), healthCheck CMD curl -fsS http://127.0.0.1:8080/healthz
#   stopTimeout 120 · task role: secretsmanager:GetSecretValue on TURN_SECRET_ARN and TURN_TLS_SECRET_ARN,
#     autoscaling:CompleteLifecycleAction / RecordLifecycleActionHeartbeat on the TURN Auto Scaling group

ARG NODE_IMAGE=node:22-bookworm-slim
ARG COTURN_IMAGE=coturn/coturn:4.6.3-debian

# ---------------------------------------------------------------- agent bundle
FROM ${NODE_IMAGE} AS agent-build
WORKDIR /repo
COPY . .
RUN npm ci --workspace @classroom/turn-agent --include-workspace-root=false --ignore-scripts --no-audit --no-fund \
 && npm run build --workspace @classroom/turn-agent \
 && node --check turn/agent/dist/agent.mjs

# ---------------------------------------------------------------- Node.js runtime binary
FROM ${NODE_IMAGE} AS node-runtime

# ---------------------------------------------------------------- runtime
FROM ${COTURN_IMAGE} AS runtime

# The coturn base image runs as "nobody"; packages and file capabilities need root at build time only.
USER 0:0
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG DEBIAN_FRONTEND=noninteractive

# Package versions are not pinned on purpose: the base image is pinned by digest and rebuilt regularly, and
# Debian stable packages then carry security fixes. The versions land in the SBOM.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends bash ca-certificates curl gettext-base jq libcap2-bin libstdc++6 openssl tini \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/* /usr/share/doc /usr/share/man

COPY --from=node-runtime /usr/local/bin/node /usr/local/bin/node

RUN groupadd --system --gid 10001 turn \
 && useradd --system --uid 10001 --gid turn --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin turn \
 && setcap cap_net_bind_service=+ep "$(readlink -f "$(command -v turnserver)")" \
 && turnserver --version \
 && node --version \
 && curl --version | head -n1 | grep -Eq 'curl (7\.(7[5-9]|[89][0-9])|[89]\.)' \
 && mkdir -p /run/turn \
 && chown 10001:10001 /run/turn \
 && chmod 0700 /run/turn

COPY --chmod=0444 turn/config/turnserver.conf.tmpl turn/config/denied-peers.conf /etc/turn/
COPY --chmod=0555 turn/bootstrap/entrypoint.sh turn/bootstrap/render-config.sh turn/bootstrap/fetch-tls.sh /opt/turn/bootstrap/
COPY --from=agent-build --chmod=0444 /repo/turn/agent/dist/agent.mjs /opt/turn-agent/agent.mjs

# TURN_SECRET_SOURCE / TURN_TLS_SOURCE only name where secrets come from; no secret value is ever set here.
# hadolint ignore=DL3064
ENV TURN_CONFIG_DIR=/etc/turn \
    TURN_RUNTIME_DIR=/run/turn \
    TURN_ENV=production \
    TURN_ADDRESS_SOURCE=imds \
    TURN_SECRET_SOURCE=secretsmanager \
    TURN_TLS_SOURCE=secretsmanager \
    TURN_LISTEN_PORT=3478 \
    TURN_TLS_PORT=443 \
    TURN_RELAY_MIN_PORT=49152 \
    TURN_RELAY_MAX_PORT=65535 \
    TURN_PROMETHEUS_PORT=9641 \
    TURN_AGENT_PORT=8080 \
    NODE_ENV=production

USER 10001:10001

EXPOSE 3478/udp 3478/tcp 443/tcp

# ECS uses the task definition's health check; this one serves local runs (docker-compose.dev.yml).
HEALTHCHECK --interval=15s --timeout=3s --start-period=60s --retries=3 \
  CMD ["curl", "-fsS", "http://127.0.0.1:8080/healthz"]

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/turn/bootstrap/entrypoint.sh"]
CMD ["coturn"]