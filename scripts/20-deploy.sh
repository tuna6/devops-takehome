#!/usr/bin/env bash
# Installs ArgoCD into the cluster and deploys quote-api via an ArgoCD Application.
# Idempotent: safe to re-run. Skips ArgoCD install if argocd-server already exists.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# --- ArgoCD version pin ---
# Pinned to v3.4.4: verified as the latest stable patch in the v3.4 line on
# https://github.com/argoproj/argo-cd/releases (released 2026-06-18).
# v3.x is the current supported generation; v2.13.x is now outside the two-most-
# recent-minors support window. v3.4.4 chosen over v3.3.x as the latest minor.
#
# v3 RBAC note: ArgoCD v3 changed its *internal* API RBAC (policy.csv/casbin) so
# that user-level Application permissions no longer cascade to sub-resources by
# default. This does NOT affect automated sync — the application-controller uses
# its Kubernetes ClusterRole (apiGroups:['*'], resources:['*'], verbs:['*'],
# unchanged in v3.4.4) to manage Deployments/Services/Ingresses/HPAs/PDBs
# directly. The internal RBAC layer is only exercised by human users via the
# ArgoCD API/UI; our Application runs automated sync with no human trigger.
#
# Install method: official manifest (not Helm chart) because:
#   (a) the manifest is the primary supported install path per ArgoCD docs;
#   (b) for a k3d cluster reachable only from inside the toolbox, one
#       `kubectl apply -f <url>` is simpler than helm repo add/update/install;
#   (c) `kubectl apply` is idempotent — subsequent runs update resources in-place.
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.4.4}"
ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

# Determine the git repo URL for the ArgoCD Application.
# Priority: REPO_URL env var → git remote origin → hardcoded default.
REPO_URL="${REPO_URL:-$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null || echo 'https://github.com/tuna6/devops-takehome')}"

printf '\n=== [20-deploy.sh] ArgoCD GitOps deploy for quote-api ===\n'
printf 'ArgoCD version : %s\n' "${ARGOCD_VERSION}"
printf 'Repo URL       : %s\n' "${REPO_URL}"

# ---------------------------------------------------------------------------
# Step 1: Install ArgoCD (idempotent)
# ---------------------------------------------------------------------------
printf '\n--- Step 1: ArgoCD installation ---\n'

if kubectl get deployment argocd-server -n argocd &>/dev/null; then
  printf 'argocd-server deployment found — skipping manifest apply.\n'
else
  printf 'Creating argocd namespace...\n'
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

  printf 'Applying ArgoCD manifest (%s)...\n' "${ARGOCD_VERSION}"
  # --server-side avoids the 262144-byte annotation limit that blocks ArgoCD v3's
  # large applicationsets CRD when using client-side apply.
  kubectl apply -n argocd -f "${ARGOCD_MANIFEST}" --server-side
fi

printf 'Waiting for ArgoCD deployments to be available (timeout 5m)...\n'
kubectl wait --for=condition=Available deployment --all \
  -n argocd --timeout=300s

printf 'Waiting for argocd-application-controller StatefulSet (timeout 5m)...\n'
kubectl rollout status statefulset/argocd-application-controller \
  -n argocd --timeout=300s

printf 'ArgoCD pods:\n'
kubectl get pods -n argocd

# ---------------------------------------------------------------------------
# Step 2: Apply the ArgoCD Application resource
# ---------------------------------------------------------------------------
printf '\n--- Step 2: Apply ArgoCD Application ---\n'

# argocd/quote-api-application.yaml uses the literal placeholder ${REPO_URL};
# we substitute it with sed before piping to kubectl apply.
sed "s|\${REPO_URL}|${REPO_URL}|g" \
  "${REPO_ROOT}/argocd/quote-api-application.yaml" \
  | kubectl apply -f -

# ---------------------------------------------------------------------------
# Step 3: Wait for Application to reach Synced + Healthy
# ---------------------------------------------------------------------------
printf '\n--- Step 3: Wait for sync and health ---\n'

printf 'Waiting for quote-api Application to sync (timeout 5m)...\n'
if ! timeout 300 bash -c '
  until kubectl get application quote-api -n argocd \
        -o jsonpath="{.status.sync.status}" 2>/dev/null \
        | grep -q "^Synced$"; do
    STATUS=$(kubectl get application quote-api -n argocd \
             -o jsonpath="{.status.sync.status}" 2>/dev/null || echo "pending")
    printf "  sync: %s\n" "${STATUS}"
    sleep 10
  done'; then
  printf 'ERROR: Application did not reach Synced within 5 minutes.\n'
  printf 'ArgoCD application describe:\n'
  kubectl describe application quote-api -n argocd || true
  exit 1
fi
printf 'Application is Synced.\n'

printf 'Waiting for quote-api Application to become Healthy (timeout 3m)...\n'
if ! timeout 180 bash -c '
  until kubectl get application quote-api -n argocd \
        -o jsonpath="{.status.health.status}" 2>/dev/null \
        | grep -q "^Healthy$"; do
    STATUS=$(kubectl get application quote-api -n argocd \
             -o jsonpath="{.status.health.status}" 2>/dev/null || echo "pending")
    printf "  health: %s\n" "${STATUS}"
    sleep 10
  done'; then
  printf 'ERROR: Application did not become Healthy within 3 minutes.\n'
  printf 'Pods in quote-api namespace:\n'
  kubectl get pods -n quote-api || true
  printf '\nPod events:\n'
  kubectl get events -n quote-api --sort-by='.lastTimestamp' || true
  exit 1
fi
printf 'Application is Healthy.\n'

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n=== Deployment summary ===\n'
printf '\nArgoCD Application:\n'
kubectl get application quote-api -n argocd \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REPO:.spec.source.repoURL'

printf '\nPods:\n'
kubectl get pods -n quote-api -o wide

printf '\nHPA:\n'
kubectl get hpa -n quote-api

printf '\nPDB:\n'
kubectl get pdb -n quote-api

printf '\nIngress:\n'
kubectl get ingress -n quote-api

printf '\nDone. Test from the host: curl http://localhost:8888/api/quote\n'
