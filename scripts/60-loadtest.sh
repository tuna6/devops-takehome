#!/usr/bin/env bash
# Part 6 — Load Test, Scaling Proof & Observability
#
# Idempotent: safe to re-run. Skips steps already done.
# Steps:
#   1. Install kube-prometheus-stack (if not already installed).
#   2. Apply ServiceMonitor for quote-api (idempotent via kubectl apply).
#   3. Verify Prometheus is scraping quote-api (/metrics endpoint).
#   4. Run k6 load test against the Ingress URL.
#
# Prerequisites: scripts/20-deploy.sh must have run (quote-api must be deployed).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Pinned chart version — verified 2026-06-21 via:
#   helm search repo prometheus-community/kube-prometheus-stack --versions | head -3
# Latest: 86.3.2 (app v0.91.0 / Prometheus v3.12.0)
CHART_VERSION="86.3.2"
HELM_RELEASE="kube-prometheus-stack"
MONITORING_NS="monitoring"
PROM_VALUES="${REPO_ROOT}/kube-prom-values.yaml"
SERVICEMONITOR_MANIFEST="${REPO_ROOT}/monitoring/servicemonitor.yaml"
K6_SCRIPT="${REPO_ROOT}/loadtest/quote-api-load.js"

# Ingress URL — verified reachable from toolbox container:
#   - k3d maps host:8080 → cluster:80 via Traefik LoadBalancer
#   - docker-compose.yml sets extra_hosts: host.docker.internal → host-gateway
#   - Ingress has no host filter; routes all traffic (values.yaml ingress.host: "")
INGRESS_URL="http://host.docker.internal:8080"

printf '\n=== [60-loadtest.sh] Part 6 — Load Test & Observability ===\n'

# ---------------------------------------------------------------------------
# Step 1: Install kube-prometheus-stack (idempotent)
# ---------------------------------------------------------------------------
printf '\n--- Step 1: kube-prometheus-stack ---\n'

if helm status "${HELM_RELEASE}" -n "${MONITORING_NS}" &>/dev/null; then
  printf 'kube-prometheus-stack already installed — skipping.\n'
  printf 'Installed chart info:\n'
  helm list -n "${MONITORING_NS}" | grep "${HELM_RELEASE}" || true
else
  printf 'Adding prometheus-community Helm repo...\n'
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo update prometheus-community

  printf 'Creating monitoring namespace...\n'
  kubectl create namespace "${MONITORING_NS}" --dry-run=client -o yaml | kubectl apply -f -

  printf 'Installing kube-prometheus-stack v%s...\n' "${CHART_VERSION}"
  printf '  Node resources at install time:\n'
  kubectl top nodes || printf '  (metrics-server unavailable — skipping top)\n'

  helm install "${HELM_RELEASE}" prometheus-community/kube-prometheus-stack \
    --namespace "${MONITORING_NS}" \
    --version "${CHART_VERSION}" \
    --values "${PROM_VALUES}" \
    --wait \
    --timeout 10m

  printf 'kube-prometheus-stack installed.\n'
fi

printf '\nMonitoring pods:\n'
kubectl get pods -n "${MONITORING_NS}" -l "release=${HELM_RELEASE}"

# ---------------------------------------------------------------------------
# Step 2: Apply ServiceMonitor (idempotent via kubectl apply)
# ---------------------------------------------------------------------------
printf '\n--- Step 2: ServiceMonitor ---\n'

# The Prometheus CR's serviceMonitorSelector requires: release: kube-prometheus-stack
# Verified via: kubectl get prometheus -n monitoring -o yaml | grep -A5 serviceMonitorSelector
# The ServiceMonitor matches the quote-api Service by:
#   app.kubernetes.io/name: quote-api
#   app.kubernetes.io/instance: quote-api
# (labels confirmed from: kubectl get svc -n quote-api -o yaml)
kubectl apply -f "${SERVICEMONITOR_MANIFEST}"
printf 'ServiceMonitor applied.\n'

# ---------------------------------------------------------------------------
# Step 3: Verify Prometheus is scraping quote-api
# ---------------------------------------------------------------------------
printf '\n--- Step 3: Verify scraping ---\n'

printf 'Waiting for Prometheus pod to be ready...\n'
kubectl wait --for=condition=Ready pod \
  -l "app.kubernetes.io/name=prometheus" \
  -n "${MONITORING_NS}" \
  --timeout=120s

# Port-forward to Prometheus service and query the `up` metric for quote-api.
# `up{job="quote-api"} == 1` means Prometheus successfully scraped each pod.
printf 'Port-forwarding to Prometheus (9090)...\n'
kubectl port-forward -n "${MONITORING_NS}" \
  svc/kube-prometheus-stack-prometheus 9090:9090 &>/tmp/prom-pf.log &
PF_PID=$!
# shellcheck disable=SC2064
trap "kill ${PF_PID} 2>/dev/null || true" EXIT

# Give port-forward time to establish
sleep 5

printf 'Querying up{job="quote-api"} — expect value=1 for each pod...\n'
ATTEMPT=0
while true; do
  ATTEMPT=$((ATTEMPT + 1))
  RESULT=$(curl -sf --max-time 10 \
    "http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22quote-api%22%7D" \
    2>/dev/null || echo "")
  if [ -z "${RESULT}" ]; then
    printf '  attempt %d: no response from Prometheus (port-forward may still be starting)\n' "${ATTEMPT}"
    sleep 10
    continue
  fi
  UP_COUNT=$(echo "${RESULT}" | grep -o '"value":\[.*,"1"\]' | wc -l | tr -d ' ')
  if [ "${UP_COUNT}" -gt 0 ]; then
    printf 'Prometheus scrape confirmed: %s pod(s) reporting up=1\n' "${UP_COUNT}"
    printf 'Sample target: %s\n' "$(echo "${RESULT}" | grep -o '"instance":"[^"]*"' | head -1)"
    break
  fi
  printf '  attempt %d: quote-api not yet in targets (got: %s)\n' "${ATTEMPT}" "${RESULT:0:120}"
  sleep 10
done

kill "${PF_PID}" 2>/dev/null || true
trap - EXIT

printf '\nCurrent quote-api pods and HPA:\n'
kubectl get pods -n quote-api
kubectl get hpa -n quote-api

# ---------------------------------------------------------------------------
# Step 4: k6 load test
# ---------------------------------------------------------------------------
printf '\n--- Step 4: k6 load test ---\n'
printf 'Script: %s\n' "${K6_SCRIPT}"
printf 'Target: %s/api/quote\n' "${INGRESS_URL}"
printf '\nBaseline (pre-measured, 1 VU 30s):\n'
printf '  p50=102ms  p90=138ms  p95=139ms  errors=0%%  throughput=9.0 RPS\n'
printf '  (floor ~100ms = SHA-256 burn in _cpu_burn_100ms(), ~39ms = Traefik overhead)\n'
printf '\nStarting load test (stages: 5VU/1m → 10VU/3m → 20VU/2m → 0VU/1m)...\n'
printf 'Watch HPA in another terminal: kubectl get hpa -n quote-api -w\n\n'

k6 run "${K6_SCRIPT}"

printf '\n=== [60-loadtest.sh] Done ===\n'
printf 'Next steps (separate pass):\n'
printf '  - Capture kubectl get hpa -w output showing scale-out\n'
printf '  - Add PrometheusRule alert\n'
printf '  - Commit Grafana dashboard JSON + screenshot\n'
printf '  - Write LOADTEST.md\n'
