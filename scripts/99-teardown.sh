#!/usr/bin/env bash
# Run from the HOST (not inside the toolbox container):
#   ./scripts/99-teardown.sh
#
# Deletes the k3d cluster and brings down the compose stack.
# Safe to run even if the cluster or stack is already partially down.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLUSTER_NAME=elsa-devops

cd "$REPO_ROOT"

printf 'Deleting k3d cluster "%s"...\n' "$CLUSTER_NAME"
# k3d lives inside the toolbox image. Use exec if toolbox is running;
# otherwise remove the cluster containers/network/volume directly.
if docker ps --format '{{.Names}}' | grep -q '^elsa-devops-toolbox$'; then
  docker exec elsa-devops-toolbox k3d cluster delete "$CLUSTER_NAME" 2>/dev/null || true
else
  docker ps -a --filter "name=k3d-${CLUSTER_NAME}" --format '{{.Names}}' \
    | xargs -r docker rm -f 2>/dev/null || true
  docker network ls --filter "name=k3d-${CLUSTER_NAME}" --format '{{.Name}}' \
    | xargs -r docker network rm 2>/dev/null || true
  docker volume ls --filter "name=k3d-${CLUSTER_NAME}" --format '{{.Name}}' \
    | xargs -r docker volume rm 2>/dev/null || true
fi

printf 'Bringing down compose stack...\n'
docker compose down -v

printf 'Teardown complete. Bring everything back up with: docker compose up -d\n'
