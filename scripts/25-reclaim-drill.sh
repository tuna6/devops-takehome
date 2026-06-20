#!/usr/bin/env bash
# Spot-node reclaim drill: cordon + drain one spot node, prove the service survives.
# Idempotent: safe to re-run. Always uncordons the target node at exit, even on failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export KUBECONFIG="${REPO_ROOT}/.kube/config"

NAMESPACE="quote-api"
# Port 8080 is mapped host:8080 → cluster:80 via k3d loadbalancer.
# From inside the toolbox container, reach the host via host.docker.internal.
CURL_URL="http://host.docker.internal:8080/api/quote"
# How long to watch pod rescheduling before snapshotting final state.
WATCH_SECONDS=60
# Max tolerated gap (seconds) between consecutive successful curl responses.
# A drain + reschedule + probe cycle typically takes 10–20 seconds on a local
# k3d cluster; 30 seconds gives 50% headroom before calling it a failure.
MAX_GAP_TOLERANCE_S=30

printf '\n=== [25-reclaim-drill.sh] Spot-node reclaim drill ===\n'
printf 'Namespace       : %s\n' "${NAMESPACE}"
printf 'Curl URL        : %s\n' "${CURL_URL}"
printf 'Gap tolerance   : %ss\n' "${MAX_GAP_TOLERANCE_S}"

# ---------------------------------------------------------------------------
# Step 1: Pick a spot node that currently hosts at least one quote-api pod
# ---------------------------------------------------------------------------
printf '\n--- Step 1: Current pod placement ---\n'
kubectl get pods -n "${NAMESPACE}" -o wide

printf '\nSearching for a drainable spot node...\n'
DRAIN_NODE=""
while IFS= read -r node; do
  pod_count=$(kubectl get pods -n "${NAMESPACE}" \
    --field-selector="spec.nodeName=${node}" \
    --no-headers 2>/dev/null | wc -l)
  if [ "${pod_count}" -gt 0 ]; then
    DRAIN_NODE="${node}"
    break
  fi
done < <(kubectl get nodes -l acme.io/capacity=spot --no-headers \
          -o custom-columns='NAME:.metadata.name')

if [ -z "${DRAIN_NODE}" ]; then
  printf 'ERROR: No spot node found with a quote-api pod. Current placement:\n'
  kubectl get pods -n "${NAMESPACE}" -o wide
  exit 1
fi
printf 'Selected node to drain: %s\n' "${DRAIN_NODE}"

# Always uncordon on exit so a failed run does not leave the cluster permanently degraded.
trap 'printf "\nUncordoning %s (trap on exit)...\n" "${DRAIN_NODE}"; kubectl uncordon "${DRAIN_NODE}" 2>/dev/null || true' EXIT

# ---------------------------------------------------------------------------
# Step 2: Start background curl loop
# ---------------------------------------------------------------------------
printf '\n--- Step 2: Starting background curl loop ---\n'
CURL_LOG=$(mktemp /tmp/reclaim-drill-curl.XXXXXX)

{
  req=0
  while true; do
    req=$((req + 1))
    ts=$(date +%s)
    if curl -sf --max-time 5 "${CURL_URL}" > /dev/null 2>&1; then
      printf 'OK %s %s\n' "${ts}" "${req}" >> "${CURL_LOG}"
    else
      printf 'FAIL %s %s\n' "${ts}" "${req}" >> "${CURL_LOG}"
    fi
    sleep 1
  done
} &
CURL_PID=$!
# Clean up the curl loop on exit regardless of how we exit.
trap 'kill "${CURL_PID}" 2>/dev/null || true; printf "\nUncordoning %s (trap on exit)...\n" "${DRAIN_NODE}"; kubectl uncordon "${DRAIN_NODE}" 2>/dev/null || true' EXIT

printf 'Curl loop started (PID %s). Waiting 5 s for baseline...\n' "${CURL_PID}"
sleep 5

baseline_ok=$(grep -c '^OK' "${CURL_LOG}" 2>/dev/null || echo 0)
if [ "${baseline_ok}" -eq 0 ]; then
  printf 'ERROR: Service unreachable before drain. Aborting.\n'
  printf 'Check: curl %s\n' "${CURL_URL}"
  exit 1
fi
printf 'Baseline OK: %s successful requests in first 5 seconds.\n' "${baseline_ok}"

# ---------------------------------------------------------------------------
# Step 3: Cordon + Drain
# ---------------------------------------------------------------------------
printf '\n--- Step 3: Cordon + drain %s ---\n' "${DRAIN_NODE}"
kubectl cordon "${DRAIN_NODE}"
printf 'Node cordoned. Draining (respecting PDB, no --force/--disable-eviction)...\n'
# --ignore-daemonsets: DaemonSet pods (kube-proxy, etc.) cannot be evicted — skip them.
# --delete-emptydir-data: emptyDir volumes are ephemeral by design; safe to lose.
# kubectl drain uses the eviction API by default. With PDB minAvailable=2 of 3,
# it will block if evicting would drop below 2 ready pods, waiting for a replacement
# to become Ready before proceeding to the next eviction. This is the proof the PDB
# is correctly configured.
kubectl drain "${DRAIN_NODE}" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=180s
printf 'Drain complete.\n'

# ---------------------------------------------------------------------------
# Step 4: Watch pod rescheduling for a bounded window
# ---------------------------------------------------------------------------
printf '\n--- Step 4: Pod rescheduling (%ss window) ---\n' "${WATCH_SECONDS}"
printf 'State at drain completion:\n'
kubectl get pods -n "${NAMESPACE}" -o wide

printf '\nWatching pod events for %ss...\n' "${WATCH_SECONDS}"
timeout "${WATCH_SECONDS}" kubectl get pods -n "${NAMESPACE}" -o wide -w 2>&1 || true

printf '\nState after %ss watch window:\n' "${WATCH_SECONDS}"
kubectl get pods -n "${NAMESPACE}" -o wide

printf '\nWaiting for all pods to be Ready...\n'
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=quote-api \
  -n "${NAMESPACE}" --timeout=120s

# ---------------------------------------------------------------------------
# Step 5: Stop curl loop, compute summary
# ---------------------------------------------------------------------------
printf '\n--- Step 5: Curl loop summary ---\n'
kill "${CURL_PID}" 2>/dev/null || true
sleep 2  # allow last in-flight request to land

TOTAL=$(wc -l < "${CURL_LOG}" 2>/dev/null || echo 0)
SUCCESSES=$(grep -c '^OK' "${CURL_LOG}" 2>/dev/null || echo 0)
FAILURES=$(grep -c '^FAIL' "${CURL_LOG}" 2>/dev/null || echo 0)

# Max gap between consecutive successful responses (seconds, integer resolution).
MAX_GAP=0
PREV_TS=""
while IFS=' ' read -r status ts _req; do
  if [ "${status}" = "OK" ]; then
    if [ -n "${PREV_TS}" ]; then
      gap=$((ts - PREV_TS))
      [ "${gap}" -gt "${MAX_GAP}" ] && MAX_GAP="${gap}"
    fi
    PREV_TS="${ts}"
  fi
done < "${CURL_LOG}"

printf 'Total requests    : %s\n' "${TOTAL}"
printf 'Successes         : %s\n' "${SUCCESSES}"
printf 'Failures          : %s\n' "${FAILURES}"
printf 'Max gap (s)       : %s  (tolerance: %s)\n' "${MAX_GAP}" "${MAX_GAP_TOLERANCE_S}"
printf '\nFull request log:\n'
cat "${CURL_LOG}"
rm -f "${CURL_LOG}"

# ---------------------------------------------------------------------------
# Step 6: Placement observability check (not a hard gate)
# ---------------------------------------------------------------------------
printf '\n--- Step 6: Post-drain placement check ---\n'
printf '%-45s %-32s %s\n' 'POD' 'NODE' 'CAPACITY'

SPOT_COUNT=0
OD_COUNT=0
OTHER_COUNT=0

while IFS= read -r line; do
  pod=$(printf '%s' "${line}" | awk '{print $1}')
  node=$(printf '%s' "${line}" | awk '{print $7}')
  capacity=$(kubectl get node "${node}" \
    -o jsonpath='{.metadata.labels.acme\.io/capacity}' 2>/dev/null || echo "(none)")
  printf '%-45s %-32s %s\n' "${pod}" "${node}" "${capacity}"
  case "${capacity}" in
    spot)      SPOT_COUNT=$((SPOT_COUNT + 1)) ;;
    on-demand) OD_COUNT=$((OD_COUNT + 1)) ;;
    *)         OTHER_COUNT=$((OTHER_COUNT + 1)) ;;
  esac
done < <(kubectl get pods -n "${NAMESPACE}" --no-headers -o wide \
           | grep -v 'Terminating\|Error')

printf '\nObserved split: %s spot / %s on-demand / %s other\n' \
  "${SPOT_COUNT}" "${OD_COUNT}" "${OTHER_COUNT}"

if [ "${SPOT_COUNT}" -eq 2 ] && [ "${OD_COUNT}" -eq 1 ] && [ "${OTHER_COUNT}" -eq 0 ]; then
  PLACEMENT_RESULT="PASS — 2 spot / 1 on-demand"
else
  PLACEMENT_RESULT="WARN — expected 2 spot / 1 on-demand, got ${SPOT_COUNT}/${OD_COUNT}/${OTHER_COUNT}. Soft constraints make this non-guaranteed; the service is still healthy."
fi
printf 'Placement: %s\n' "${PLACEMENT_RESULT}"

# ---------------------------------------------------------------------------
# Step 7: Uncordon (trap handles this on abnormal exit; explicit call here for
# normal exit so the trap's 2>/dev/null path doesn't hide errors on success)
# ---------------------------------------------------------------------------
printf '\n--- Step 7: Uncordon %s ---\n' "${DRAIN_NODE}"
# Disable trap so we can see errors on normal exit.
trap - EXIT
kubectl uncordon "${DRAIN_NODE}"

printf '\nCluster nodes after uncordon:\n'
kubectl get nodes -o wide

# ---------------------------------------------------------------------------
# Step 8: Exit code — service survivability determines pass/fail
# ---------------------------------------------------------------------------
printf '\n=== Drill result ===\n'
printf 'Drained node        : %s\n' "${DRAIN_NODE}"
printf 'Requests total/ok/fail : %s/%s/%s\n' "${TOTAL}" "${SUCCESSES}" "${FAILURES}"
printf 'Max success gap     : %ss (tolerance: %ss)\n' "${MAX_GAP}" "${MAX_GAP_TOLERANCE_S}"
printf 'Placement check     : %s\n' "${PLACEMENT_RESULT}"

if [ "${MAX_GAP}" -le "${MAX_GAP_TOLERANCE_S}" ]; then
  printf '\nPASS — service remained reachable within the %ss gap tolerance.\n' "${MAX_GAP_TOLERANCE_S}"
  exit 0
else
  printf '\nFAIL — max gap of %ss exceeded tolerance of %ss.\n' "${MAX_GAP}" "${MAX_GAP_TOLERANCE_S}"
  exit 1
fi
