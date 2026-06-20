# DevOps Take-Home — Quote API Platform

## Quick Start

```bash
git clone <your-repo> && cd <your-repo>
docker compose up -d
./scripts/run-all.sh
```

`docker compose up -d` builds the toolbox image and immediately runs the cluster bootstrap in one step — no manual commands needed. When the bootstrap container exits you have a 5-node k3d cluster ready for the subsequent scripts.

---

## Architecture Diagram

```mermaid
flowchart TD
    subgraph Host["Host machine (Linux / Docker Desktop)"]
        DC["docker compose up -d"]

        subgraph Compose["Docker Compose"]
            TB["toolbox container\nkubectl · helm · terraform · k6"]
            BS["bootstrap container\n(runs once, exits 0)"]
        end

        DS["/var/run/docker.sock"]

        subgraph K3D["k3d cluster — elsa-devops"]
            LB["serverlb\n:8080→:80 · :6443→:6443"]
            S0["server-0\ncontrol-plane"]
            A0["agent-0\nacme.io/capacity=spot"]
            A1["agent-1\nacme.io/capacity=spot"]
            A2["agent-2\nacme.io/capacity=on-demand"]
            A3["agent-3\nacme.io/node-type=gpu\n(tainted NoSchedule)"]
        end
    end

    DC --> TB
    DC --> BS
    TB & BS --> DS
    DS -->|"DooD — k3d cluster create"| K3D
    BS -->|"k3d kubeconfig get\n+ sed server URL patch"| TB
    LB --> S0
    S0 --- A0 & A1 & A2 & A3

    classDef built fill:#e6f4ea,stroke:#34a853,color:#1a4d2e
    GHCR["ghcr.io/tuna6/devops-takehome:SHA\nFastAPI quote-api\n/healthz · /readyz · /metrics · /api/quote"]:::built
    ARGO["ArgoCD v3.4.4\n+ Helm chart"]:::built
    APP["quote-api pods ×3\n(2 spot · 1 on-demand)"]:::built
    INGRESS["Traefik Ingress\nhost:8080 → /api/quote"]:::built
    A0 & A1 & A2 -->|"affinity + topology spread"| APP:::built
    APP --> ARGO:::built
    GHCR -->|"image pull"| APP:::built
    LB --> INGRESS:::built
    INGRESS --> APP
```

> **Node labels** (applied by `troubleshoot/prepare.sh` during bootstrap):  
> `agent-0`, `agent-1` → `acme.io/capacity=spot`  
> `agent-2` → `acme.io/capacity=on-demand`  
> `agent-3` → `acme.io/node-type=gpu` + taint `nvidia.com/gpu=true:NoSchedule`

---

## Script Reference

| Script | What it does | When to run |
|---|---|---|
| `scripts/00-bootstrap-cluster.sh` | Creates a 5-node k3d cluster (`--api-port 6443`, `--tls-san`), writes kubeconfig, waits for all nodes Ready, runs `troubleshoot/prepare.sh` if present. Idempotent — safe to re-run. | Run automatically by `docker compose up -d` via the bootstrap service. Can also be called directly inside the toolbox container. |
| `scripts/10-build-push.sh` | Builds the `quote-api` Docker image, tags it with the current git SHA (`ghcr.io/tuna6/devops-takehome:<sha>`), and pushes to GHCR. Idempotent — re-running with the same SHA rebuilds and re-pushes safely. Reads `GITHUB_TOKEN` env var for login if provided; otherwise assumes `docker login ghcr.io` has already been run. | Run once after cloning (image is pre-built at the SHA in this repo). Re-run after any code change in `src/`. |
| `scripts/20-deploy.sh` | Installs ArgoCD (v3.4.4, idempotent) and applies the `quote-api` ArgoCD Application pointing at the Helm chart in this repo. Waits for Synced + Healthy. | Run automatically by `run-all.sh`. Re-runnable to check ArgoCD state. |
| `scripts/25-reclaim-drill.sh` | Spot-node reclaim drill: picks a spot node running a quote-api pod, starts a curl loop, cordons + drains the node (respecting PDB), shows pod rescheduling, then uncordons. Exits 0 if the service stayed reachable within the gap tolerance; prints a placement PASS/WARN (not a hard gate). | Run manually inside the toolbox. Not in `run-all.sh` — node drain is disruptive and requires explicit intent. |
| `scripts/run-all.sh` | Waits for the compose bootstrap container to finish, then runs the numbered scripts in order inside the toolbox. | `./scripts/run-all.sh` from the host after `docker compose up -d`. |

---

## Design Decisions & Trade-offs

**Docker-out-of-Docker (DooD), not DinD**  
The toolbox and bootstrap containers bind-mount `/var/run/docker.sock` and talk to the host's Docker daemon directly. This avoids the complexity and security surface of running a nested Docker daemon, and means k3d cluster containers are siblings of the toolbox on the host — they survive compose restarts.

**`extra_hosts: host.docker.internal: host-gateway` instead of `network_mode: host`**  
The k3s API server publishes port 6443 on `0.0.0.0` of the host (via `--api-port 6443`). From inside a container we need to reach that host port. `network_mode: host` would work on Linux only and silently breaks on Docker Desktop (Mac/Windows). `extra_hosts` with the `host-gateway` special value resolves `host.docker.internal` to the Docker bridge gateway — works on Linux, and Docker Desktop provides `host.docker.internal` natively on Mac/Windows. Requires Docker Engine ≥ 20.10.

**`--tls-san=host.docker.internal` on the k3s server**  
k3s generates a self-signed cert at cluster creation time. Changing the kubeconfig server URL to `host.docker.internal:6443` (via `sed`) would cause TLS verification to fail unless `host.docker.internal` is in the cert's Subject Alternative Names. The `--k3s-arg '--tls-san=host.docker.internal@server:*'` flag adds it at creation time — no insecure-skip-tls-verify needed.

**Pinned tool versions in the Dockerfile, not `latest`**  
k3d v5.9.0, kubectl v1.36.2, helm v4.2.2, terraform v1.15.6, k6 v1.8.0. Pinning avoids "works on my machine" breakage if an upstream release changes behaviour mid-review.

**k6 v1.8.0 over v2.0.0**  
v2.0.0 is the newest release but v1.8.0 is a more established release from the stable 1.x line. Lower risk for the load-test script in Part 6. (v2.0.0 was also the version that exposed the double-v URL bug in the original generated Dockerfile — see AI-USAGE.md.)

**FastAPI over Go/Node for the service**  
Python + FastAPI is the fastest path to a correct, readable ~100-line service with Prometheus instrumentation and JSON responses. `prometheus_client` integrates natively. Go would produce a smaller binary but adds no meaningful value at this scale.

**CPU burn: SHA-256 hashing loop, not `time.sleep`**  
`time.sleep` is I/O wait — the process yields to the OS, burns no CPU, and produces misleading results under a load test. A bare `while True: pass` busy-loop does no real work and can be silently no-op'd by the interpreter or CPU. SHA-256 hashing (`hashlib.sha256`) performs real memory reads/writes and ALU computation each iteration. The loop runs until `time.perf_counter()` reaches the 100 ms deadline — consistent regardless of CPU speed.

**Alpine base image (142 MB) over `python:3.12-slim` (249 MB)**  
All compiled extensions pulled in by `uvicorn[standard]` — `httptools`, `uvloop`, `watchfiles` — and `pydantic-core` publish pre-built `musllinux` wheels on PyPI. No gcc or Rust toolchain is needed in the build stage. Alpine gives a 43% smaller final image with the same security posture (musl libc, no shell in runtime path).

**Multi-stage Dockerfile with virtualenv**  
The builder stage creates a venv at `/venv`, installs all deps, and is discarded. The final stage copies only `/venv` and `main.py` — no pip, no build tools, no cache. Running as explicit `USER 1001` (non-root) with no `--create-home`.

**Git SHA tag on GHCR, no floating `latest`**  
`latest` is mutable and breaks reproducibility — the same tag can resolve to a different image on a re-run. Every push is tagged with the short git SHA (`ghcr.io/tuna6/devops-takehome:<sha>`), making deploys traceable to an exact commit.

**All deps pinned including transitive**  
`src/requirements.txt` pins all 16 packages (direct + transitive) at the exact versions produced by the first `pip install` run. This guarantees identical builds across machines and time.

**Spot/on-demand placement: soft constraints over hard pins**  
The assignment asks for "at least one replica always on the on-demand node" but also forbids hard-pinning all replicas to on-demand. These pull in opposite directions for a single Deployment. Three approaches were evaluated:

1. **Hard `DoNotSchedule` topology spread** — would guarantee exactly 1 pod in the on-demand topology bucket, but breaks the reclaim drill: with only 2 topology domains (spot, on-demand) and 0 slack, losing one spot domain leaves a pod Pending with no schedulable domain that satisfies the constraint. The assignment's own drill scenario is the exact failure case.
2. **Two-Deployment split** (one Deployment pinned spot, one pinned on-demand) — would guarantee the split, but fights HPA scale-out semantics (Part 6 needs HPA to control a single replica count, not two coordinated counts), doubles chart/ops surface, and makes PDB reasoning more complex.
3. **Soft `ScheduleAnyway` topology spread + weighted affinity** *(chosen)* — `preferredDuringScheduling` with weight 100 for spot nodes scores them highest; `ScheduleAnyway` topologySpread across `acme.io/capacity` then pulls toward even distribution across capacity types without hard-blocking rescheduling when a domain disappears. The GPU node is excluded by a `requiredDuringScheduling NotIn ["gpu"]` guard (belt-and-suspenders alongside the existing NoSchedule taint).

**Control-plane exclusion:** k3s does NOT apply a `NoSchedule` taint to the server node by default (unlike kubeadm). Without an explicit exclusion, the scheduler treats server-0 as a valid placement target — a user observed exactly this after a deploy cycle. The fix is a cluster-level taint added in `scripts/00-bootstrap-cluster.sh` (`node-role.kubernetes.io/control-plane:NoSchedule`) rather than a chart-level label guard, which more accurately simulates EKS where the control plane is not visible to user workloads at all.

**Residual risk — real, not theoretical:** the 2-spot / 1-on-demand split is the intended steady state but is not guaranteed. This was confirmed by actual measurement in the same verification session that produced the PASS result: one scheduling round (ArgoCD-managed, fresh cluster sync) produced **2 spot / 1 on-demand**; a different scheduling round (manual local apply, rolling update from existing pods) produced **3 spot / 0 on-demand**:

```
# ArgoCD-managed sync (fresh):
NAME                         NODE                      CAPACITY
quote-api-64cbcfdf46-qtjkv   k3d-elsa-devops-agent-0   spot
quote-api-64cbcfdf46-7xgkd   k3d-elsa-devops-agent-1   spot
quote-api-64cbcfdf46-6wvts   k3d-elsa-devops-agent-2   on-demand

# Manual local apply (rolling update):
NAME                       NODE                      CAPACITY
quote-api-9d75bc45-g44j5   k3d-elsa-devops-agent-0   spot  ← 2 pods on same node
quote-api-9d75bc45-ns9fp   k3d-elsa-devops-agent-1   spot
quote-api-9d75bc45-sc9mw   k3d-elsa-devops-agent-0   spot
```

Both runs used the same chart config (weight:100 spot preference, `ScheduleAnyway` topology spread). The variability is the soft constraint working as specified — it scores spot nodes higher and does not block putting all replicas there. Lowering the weight to chase a 2/1 outcome was evaluated and deliberately rejected: a lower weight shifts the probability but still produces no guarantee, and we prefer to document the honest observed range rather than dial in a specific demo result.

The `scripts/25-reclaim-drill.sh` placement check surfaces this at drill time — it will print **WARN** when all-spot placement is observed (not an exit-1 failure) so the outcome is always recorded explicitly. The drill's PASS/FAIL gate is service survivability (curl loop gap ≤ 30 s), not placement split.

**What was cut**  
Parts 3–7 are not yet implemented. Part 1 (build & ship) and Part 2 (GitOps deployment, placement, reclaim drill) are complete.

---

## Troubleshooting Notes

**Port 6443 already in use**  
If you have another local Kubernetes cluster (minikube, kind, Docker Desktop Kubernetes) the k3s API server port will conflict. Either stop the other cluster first, or change `--api-port 6443` in `scripts/00-bootstrap-cluster.sh` and update the `sed` pattern on the next line to match.

**Port 8080 already in use**  
The k3d load balancer maps `host:8080 → cluster:80`. If something else owns 8080, change `--port '8080:80@loadbalancer'` in the same script. Note the assignment's `curl http://localhost:<port>/api/quote` step will need the same updated port.

**`host-gateway` not resolved — Docker Engine < 20.10**  
The `extra_hosts: host.docker.internal: host-gateway` entry in `docker-compose.yml` requires Docker Engine 20.10 or later. On older engines the bootstrap container will start but `kubectl get nodes` will fail with a connection refused or TLS error. Upgrade Docker, or as a workaround replace `host-gateway` with your Docker bridge gateway IP (typically `172.17.0.1`, confirm with `ip route | grep docker0`).
