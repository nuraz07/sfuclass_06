#!/usr/bin/env bash
# docker-cleanup.sh — removes this project's dev containers, including ones
# left broken by a Codespace restart ("RWLayer of container … is unexpectedly
# nil"), and starts nothing.
#
# Run from the project folder:   bash docker-cleanup.sh
#
# Kept:     every volume (database, Redis, object storage), every image, the
#           compose file. Only containers and the project network are removed.
# Started:  nothing. Bring the services up when you decide to: ./dev-up.sh
set -euo pipefail

COMPOSE_FILE=docker-compose.dev.yml
[ -f "$COMPOSE_FILE" ] || { echo "Run this from the project folder (the one with $COMPOSE_FILE)." >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker is not running; there is nothing to clean up." >&2; exit 0; }

compose() { docker compose -f "$COMPOSE_FILE" "$@"; }
PROJECT=$(compose config --format json 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).name||"")}catch{console.log("")}})')
[ -n "$PROJECT" ] || { echo "Could not read the project name from $COMPOSE_FILE." >&2; exit 1; }
echo "project: $PROJECT"

# Every container of the project, in every profile and state.
ids() { docker ps -aq --filter "label=com.docker.compose.project=$PROJECT"; }

BEFORE=$(ids | wc -l | tr -d ' ')
echo "containers found: $BEFORE"

# Regular removal first; a container with a broken layer can make it fail.
compose --profile '*' down --remove-orphans --timeout 20 || true

# Whatever survived (typically the broken one) is removed by force.
LEFT=$(ids)
if [ -n "$LEFT" ]; then
  for id in $LEFT; do
    name=$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##' || echo "$id")
    if docker rm -f "$id" >/dev/null 2>&1; then
      echo "removed $name (forced)"
    else
      echo "could not remove $name ($id)" >&2
    fi
  done
fi

LEFT=$(ids)
if [ -n "$LEFT" ]; then
  echo
  echo "These containers could not be removed:" >&2
  docker ps -a --filter "label=com.docker.compose.project=$PROJECT" --format '  {{.Names}}  {{.Status}}' >&2
  echo "Docker's storage itself is damaged then. Send this output before anything else is tried;" >&2
  echo "the remaining fix would also delete the volumes (database)." >&2
  exit 1
fi

echo
echo "Clean: no containers of $PROJECT left, volumes kept:"
docker volume ls --filter "label=com.docker.compose.project=$PROJECT" --format '  {{.Name}}'
echo
echo "Nothing was started. When you want the services: ./dev-up.sh"