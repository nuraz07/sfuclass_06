#!/usr/bin/env bash
# Start the dev dependencies after a Codespaces restart.
# Containers are always recreated: a stopped codespace leaves them with a
# broken layer ("RWLayer ... is unexpectedly nil"). Volumes, and with them the
# database, are kept.
set -euo pipefail
cd "$(dirname "$0")"

if ! docker ps >/dev/null 2>&1; then
  echo "starting docker ..."
  sudo rm -f /var/run/docker.pid
  sudo service docker start 2>/dev/null || sudo /usr/local/share/docker-init.sh
  sleep 5
fi

docker compose -f docker-compose.dev.yml down --remove-orphans || true
docker compose -f docker-compose.dev.yml up -d --force-recreate
docker compose -f docker-compose.dev.yml ps
