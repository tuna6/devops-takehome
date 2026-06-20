#!/usr/bin/env bash
# Builds the quote-api image, tags it with the current git SHA, and pushes to GHCR.
# Idempotent: re-running with the same SHA will rebuild and re-push (safe, not destructive).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

REGISTRY="ghcr.io"
IMAGE_OWNER="tuna6"
IMAGE_NAME="devops-takehome"
GIT_SHA="$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
IMAGE_REF="${REGISTRY}/${IMAGE_OWNER}/${IMAGE_NAME}:${GIT_SHA}"

# Optional: login via GITHUB_TOKEN if provided (CI / first-time setup).
# For interactive sessions run: echo $TOKEN | docker login ghcr.io -u <user> --password-stdin
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  echo "Logging in to ${REGISTRY}..."
  echo "${GITHUB_TOKEN}" | docker login "${REGISTRY}" -u "${IMAGE_OWNER}" --password-stdin
fi

echo "==> Building ${IMAGE_REF}"
docker build -t "${IMAGE_REF}" "${REPO_ROOT}"

echo "==> Pushing ${IMAGE_REF}"
docker push "${IMAGE_REF}"

echo "==> Done: ${IMAGE_REF}"
