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
  printf 'Found %s node container(s) for cluster "%s".\n' "$existing_nodes" "$CLUSTER_NAME"
  if [ "$existing_nodes" -lt 5 ]; then
    # Fewer than 5 containers visible means the cluster is still being created
    # (e.g. by the compose bootstrap container running concurrently). Wait
    # rather than error immediately — the kubectl wait below will gate on
    # actual node readiness once all containers are registered.
    printf 'Only %s/5 node containers visible — cluster may still be initialising.\n' "$existing_nodes"
    printf 'Waiting up to 2 minutes for all 5 containers to register...\n'
    elapsed=0
    while [ "$(k3d node list --no-headers | awk -v c="$CLUSTER_NAME" '$3 == c && $2 != "loadbalancer"' | wc -l)" -lt 5 ]; do
      if [ "$elapsed" -ge 120 ]; then
        printf 'ERROR: timed out — only %s node containers for cluster "%s" after 2 minutes.\n' \
          "$(k3d node list --no-headers | awk -v c="$CLUSTER_NAME" '$3 == c && $2 != "loadbalancer"' | wc -l)" \
          "$CLUSTER_NAME"
        printf 'If the cluster is broken, run scripts/99-teardown.sh then docker compose up -d\n'
        exit 1
      fi
      sleep 3
      elapsed=$((elapsed + 3))
    done
    printf 'All 5 node containers now registered.\n'
  fi
else
  printf 'Creating k3d cluster "%s" with 1 server + 4 agents and host port 8888 mapped to cluster port 80...\n' "$CLUSTER_NAME"
  k3d cluster create "$CLUSTER_NAME" \
    --servers 1 \
    --agents 4 \
    --port '8888:80@loadbalancer' \
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

# In EKS the control-plane is fully managed and not visible as a schedulable node.
# k3s does NOT add NoSchedule to the server node by default (unlike kubeadm).
# Taint it here so our local simulation matches production: workloads that don't
# explicitly tolerate the control-plane taint cannot land on server-0.
printf 'Tainting control-plane node(s) NoSchedule (EKS simulation)...\n'
kubectl get nodes --kubeconfig "$KUBECONFIG_PATH" \
  -l node-role.kubernetes.io/control-plane \
  -o custom-columns='NAME:.metadata.name' --no-headers \
  | while read -r node; do
      kubectl taint node "$node" \
        node-role.kubernetes.io/control-plane:NoSchedule \
        --overwrite --kubeconfig "$KUBECONFIG_PATH"
    done

printf 'Bootstrap complete; cluster "%s" is ready.\n' "$CLUSTER_NAME"
