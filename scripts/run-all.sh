#!/usr/bin/env bash
# Run from the HOST after `docker compose up -d`.
# k3d/kubectl/helm are inside the toolbox container — this script drives them
# via `docker exec` rather than requiring those tools on the host.
set -euo pipefail

TOOLBOX="elsa-devops-toolbox"
BOOTSTRAP="devops-takehome-bootstrap-1"

# Wait for the compose bootstrap container to finish before running anything.
# `docker compose up -d` returns as soon as containers start, not when the
# bootstrap script inside them completes. Without this wait a reviewer who runs
# this script immediately after compose up will race against cluster creation.
BOOTSTRAP_STATUS=$(docker inspect "${BOOTSTRAP}" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
if [ "${BOOTSTRAP_STATUS}" = "running" ] || [ "${BOOTSTRAP_STATUS}" = "created" ]; then
  printf 'Bootstrap container still running — waiting for it to finish...\n'
  docker wait "${BOOTSTRAP}" > /dev/null
fi

if ! docker logs "${BOOTSTRAP}" 2>/dev/null | grep -q 'Bootstrap complete'; then
  printf 'ERROR: Bootstrap appears to have failed.\n'
  printf 'Inspect with: docker logs %s\n' "${BOOTSTRAP}"
  exit 1
fi

printf 'Bootstrap confirmed complete. Running scripts inside toolbox...\n'

# 00-bootstrap-cluster.sh already ran via the compose bootstrap service above.
# 10-build-push.sh is a developer tool (requires GHCR credentials) and is
# intentionally excluded from the reviewer path — the image is pre-published.

docker exec "${TOOLBOX}" /workspace/scripts/20-deploy.sh
