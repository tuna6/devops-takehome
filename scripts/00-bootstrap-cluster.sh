#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLUSTER_NAME=elsa-devops
KUBECONFIG_PATH="$REPO_ROOT/.kube/config"
TRIAGE_SCRIPT="$REPO_ROOT/troubleshoot/prepare.sh"

printf 'Bootstrapping k3d cluster "%s"...\n' "$CLUSTER_NAME"
mkdir -p "$(dirname "$KUBECONFIG_PATH")"

cluster_exists=false
if k3d cluster list --no-headers | awk '{print $1}' | grep -xq "$CLUSTER_NAME"; then
  cluster_exists=true
fi

if [ "$cluster_exists" = true ]; then
  printf 'Cluster "%s" already exists. Verifying existing cluster topology...\n' "$CLUSTER_NAME"
  existing_nodes=$(k3d node list --no-headers | awk -v c="$CLUSTER_NAME" '$3 == c && $2 != "loadbalancer"' | wc -l)
  printf 'Found %s node containers for cluster "%s".\n' "$existing_nodes" "$CLUSTER_NAME"
  if [ "$existing_nodes" -lt 5 ]; then
    echo 'ERROR: existing cluster does not contain at least 5 nodes (1 server + 4 agents).'
    echo 'Please delete the cluster or adjust it before continuing.'
    exit 1
  fi
else
  printf 'Creating k3d cluster "%s" with 1 server + 4 agents and host port 8080 mapped to cluster port 80...\n' "$CLUSTER_NAME"
  k3d cluster create "$CLUSTER_NAME" \
    --servers 1 \
    --agents 4 \
    --port '8080:80@loadbalancer' \
    --api-port 6443 \
    --k3s-arg '--tls-san=host.docker.internal@server:*' \
    --wait
fi

printf 'Writing kubeconfig to %s\n' "$KUBECONFIG_PATH"
k3d kubeconfig get "$CLUSTER_NAME" > "$KUBECONFIG_PATH"
sed -i 's|https://0\.0\.0\.0:6443|https://host.docker.internal:6443|' "$KUBECONFIG_PATH"

printf 'Verifying Kubernetes nodes are Ready...\n'
kubectl get nodes --kubeconfig "$KUBECONFIG_PATH"
kubectl wait --for=condition=Ready nodes --all --timeout=180s --kubeconfig "$KUBECONFIG_PATH"

export KUBECONFIG="$KUBECONFIG_PATH"

if [ -x "$TRIAGE_SCRIPT" ]; then
  printf 'Found troubleshoot/prepare.sh; running prepare step...\n'
  "$TRIAGE_SCRIPT"
else
  printf 'No troubleshoot/prepare.sh found yet; skipping prepare step safely.\n'
fi

printf 'Bootstrap complete; cluster "%s" is ready.\n' "$CLUSTER_NAME"
