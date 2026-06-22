#!/usr/bin/env bash
# Run from the HOST (not inside the toolbox container):
#   ./scripts/99-teardown.sh
#
# Full destroy: deletes the k3d cluster, brings down the compose stack,
# and removes all local Docker images created for this project.
# Safe to run even if the cluster or stack is already partially down.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLUSTER_NAME=elsa-devops

cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# 1. Delete k3d cluster
# ---------------------------------------------------------------------------
printf 'Deleting k3d cluster "%s"...\n' "$CLUSTER_NAME"
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

# ---------------------------------------------------------------------------
# 2. Bring down compose stack and remove compose-built images
# ---------------------------------------------------------------------------
printf 'Bringing down compose stack and removing built images...\n'
docker compose down -v --rmi local

# ---------------------------------------------------------------------------
# 3. Stop and remove any leftover project containers (outside compose stack)
# ---------------------------------------------------------------------------
printf 'Removing leftover project containers...\n'
docker ps -a --filter "name=quote-api" --format '{{.Names}}' \
  | xargs -r docker rm -f 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. Remove all project-related Docker images
# ---------------------------------------------------------------------------
printf 'Removing project images...\n'

# Collect image IDs across all patterns, deduplicate, then remove in one pass
{
  docker images --filter "reference=ghcr.io/k3d-io/*"           --format '{{.ID}}'
  docker images --filter "reference=rancher/k3s"                 --format '{{.ID}}'
  docker images --filter "reference=ghcr.io/tuna6/devops-takehome" --format '{{.ID}}'
  docker images --filter "reference=quote-api-test"              --format '{{.ID}}'
} | sort -u | xargs -r docker rmi -f 2>/dev/null || true

printf '\nTeardown complete. All local images removed.\n'
printf 'Bring everything back up with: docker compose up -d\n'
