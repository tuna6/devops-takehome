# CLAUDE.md — Project Rules & Context

## Rules (always follow these)

### 1. Read the assignment spec first
Before doing any work, read `ASSIGNMENT.md` fully. It is the authoritative, non-negotiable spec.
Do not edit it. Use it as a checklist against everything you produce.
If anything is not documented but are industry standard, follow it.

### 2. Credential and secret check before every commit
Before staging or committing anything, scan all files that will be included:

```bash
grep -rn \
  -e "password\|passwd\|secret\|token\|api.key\|apikey\|private.key\|AKIA\|aws_access\|aws_secret\|ghp_\|-----BEGIN" \
  --include="*.yml" --include="*.yaml" --include="*.sh" \
  --include="*.env" --include="*.json" --include="*.tf" \
  --include="*.md" --include="Dockerfile" \
  . | grep -v ".git/"
```

Then verify sensitive paths are gitignored:
```bash
git check-ignore -v .kube/config        # must print a match
git check-ignore -v .env                # must print a match
git check-ignore -v terraform.tfstate   # must print a match
```

Known sensitive paths in this project and their gitignore status:
- `.kube/config` — kubeconfig with cluster credentials → covered by `.kube/` rule ✅
- `terraform.tfstate*` → covered ✅
- `*.pem`, `*.key`, `*.crt` → covered ✅
- `*.env`, `.env.*` → covered ✅

The assignment says credential leaks are an **instant fail**. Check every time.
Also never commit and push code by yourself. I'll do it manually

### 3. Verify, don't assume
When making infrastructure changes (Dockerfile versions, CLI flags, shell scripts), verify with
real command output — not "this should work." The original generated code had multiple
hallucinated versions and invalid flags that only showed up at runtime.

### 4. Docker access in this environment
The shell user (`tu`) is in the `docker` group but new shell sessions may not have it active.
If `docker ...` returns "permission denied":

```bash
sg docker -c "docker ..."
# or start a new shell with: newgrp docker
```

### 5. Do not scope-creep
The assignment has numbered parts. Do not build Part N+1 while working on Part N.
When a part is done, stop and report — don't start the next one unless asked.

---

## What has been built

### Part 0 — Cluster harness (session 2026-06-19) ✅

`docker compose up -d` alone brings up a working 5-node k3d cluster. No manual steps needed.

| File | Status | Notes |
|---|---|---|
| `toolbox/Dockerfile` | fixed + written | k3d v5.9.0, kubectl v1.36.2, helm v4.2.2, terraform v1.15.6, k6 v1.8.0 |
| `docker-compose.yml` | fixed | DooD via socket `:rw`, `extra_hosts` for cross-platform API access |
| `scripts/00-bootstrap-cluster.sh` | fixed | Creates 5-node cluster, patches kubeconfig, idempotent |
| `scripts/run-all.sh` | exists | Calls numbered scripts in order; expand as parts are added |
| `README.md` | written | All 5 required sections per assignment spec |

**Bugs fixed from the original Haiku-generated code:**

1. **k6 double-v URL bug** — `K6_VERSION=v2.0.0` + `k6-v${K6_VERSION}` → `k6-vv2.0.0` (404). Fixed: `v1.8.0` + `k6-${K6_VERSION}`.
2. **DooD kubeconfig unreachable** — k3d writes `https://0.0.0.0:6443`; unreachable from inside a container. Fixed: `--api-port 6443` + `sed` patches URL to `host.docker.internal:6443` + `--tls-san` + `extra_hosts`.
3. **`KUBECONFIG` not exported** — `prepare.sh` calls had no kubeconfig. Fixed: `export KUBECONFIG` before the invocation.
4. **`k3d node list --cluster` invalid flag** — no such flag in v5.9.0. Fixed: `awk` filter on CLUSTER column.
5. **Duplicate `kubectl wait` block** — copy-paste duplicate. Removed.
6. **Docker socket mounted `:ro`** — changed to `:rw`.
7. **Scripts not executable** — `chmod +x scripts/*.sh` added.

---

### Part 1 — Build & Ship (session 2026-06-20) ✅

FastAPI quote-api service, multi-stage Dockerfile, GHCR push script.

| File | Notes |
|---|---|
| `src/main.py` | FastAPI: `/healthz`, `/readyz`, `/metrics` (prometheus_client), `/api/quote` |
| `src/requirements.txt` | 16 packages fully pinned (direct + transitive, captured from actual pip install) |
| `Dockerfile` | Multi-stage: builder (`python:3.12-alpine` + venv), final (`python:3.12-alpine`, USER 1001) |
| `scripts/10-build-push.sh` | Builds, tags with `git rev-parse --short HEAD`, pushes to GHCR; idempotent |

**Key decisions:**
- CPU burn: SHA-256 hashing loop (`time.perf_counter` deadline) — not `time.sleep` (I/O wait), not bare busy-loop (can be no-op'd). Measured at ~101ms.
- Base image: `python:3.12-alpine` (142 MB) over `python:3.12-slim` (249 MB). All compiled extensions ship musllinux wheels — no gcc/Rust needed in builder.
- Non-root: `adduser -S -u 1001` + explicit `USER 1001`.
- GHCR tag: git SHA only, no floating `latest`.

**GHCR image:** `ghcr.io/tuna6/devops-takehome:2c94e39`
(SHA is pre-commit for Part 1 files; re-run `scripts/10-build-push.sh` after committing to get the correct SHA)

**Verified (real output):**
- `/healthz` → `{"status":"ok"}`, `/readyz` → `{"status":"ready"}`
- `/api/quote` → JSON quote, ~101ms consistently across 5 runs
- `/metrics` → `quote_requests_total` increments correctly after each quote request
- `whoami` inside container → `appuser` (non-root confirmed)

---

### Part 2 — GitOps Deployment (sessions 2026-06-20) ✅

| File | Notes |
|---|---|
| `helm/quote-api/` | Hand-written Helm chart: Deployment, Service, Ingress, HPA (min:3), PDB (minAvailable:2) |
| `argocd/quote-api-application.yaml` | ArgoCD Application syncing from `helm/quote-api/`, automated+selfHeal |
| `scripts/20-deploy.sh` | Installs ArgoCD v3.4.4 (server-side apply for v3 CRD size), applies Application, waits Synced+Healthy |
| `scripts/25-reclaim-drill.sh` | Cordon+drain one spot node, curl loop survivability test, placement PASS/WARN check, uncordon |

**Placement design (soft constraints — see README for full rationale):**
- `requiredDuringScheduling NotIn ["gpu"]` — hard GPU exclusion
- `preferredDuringScheduling weight:100 In ["spot"]` — spot preference
- Two `ScheduleAnyway` topologySpreadConstraints: by `acme.io/capacity` and by `kubernetes.io/hostname`
- Control-plane taint: `node-role.kubernetes.io/control-plane:NoSchedule` added in `00-bootstrap-cluster.sh` — k3s does NOT add this by default (unlike kubeadm). A real pod-on-server-0 placement was observed before this fix.
- `DoNotSchedule` was explicitly rejected: with 2 capacity domains, it blocks rescheduling during a spot drain — the exact scenario the drill tests.

**Observed placement variability (confirmed 2026-06-20 — important context for Part 6 HPA checks):**  
Weight:100 spot preference + `ScheduleAnyway` produces non-deterministic results. Two scheduling rounds in the same session produced different splits: ArgoCD-managed fresh sync → 2 spot / 1 on-demand; manual rolling update → 3 spot / 0 on-demand. Both are valid outcomes of the soft constraint. The "likely 2/1" framing in the README is accurate — it is likely, not guaranteed. Do not be surprised if a future session or reviewer run sees all-spot. The drill's placement check handles this with a non-blocking WARN. The weight:100 value is intentional and must not be lowered to chase a 2/1 demo outcome.

**Drill result (2026-06-20):** 60/60 requests, 0 failures, max gap 2s, placement PASS (2 spot / 1 on-demand post-drain).

### What is NOT yet built

- Part 3: troubleshoot/fixed-app.yaml + TROUBLESHOOTING.md
- Parts 4–6: CI/CD, IaC, load test (pick ≥1)
- Part 7: OPS-ANSWERS.md

---

## Key architecture decisions

| Decision | Choice | Why |
|---|---|---|
| Kubernetes distribution | k3d (k3s in Docker) | Assignment recommends it; agents = containers, fast |
| Docker API access | DooD (bind-mount socket) | No nested daemon; cluster containers survive compose restarts |
| Cross-platform host routing | `extra_hosts` + `host-gateway` | Works on Linux + Mac/Windows Docker Desktop; `network_mode: host` is Linux-only |
| TLS for API server | `--tls-san=host.docker.internal` | Avoids `insecure-skip-tls-verify`; proper cert SAN |
| API server port | Fixed at 6443 via `--api-port` | Stable across cluster recreations; kubeconfig sed patch is predictable |
| Tool versions | All pinned | Reproducibility; `latest` can break between reviewer runs |
| App language | Python + FastAPI | Fastest path to correct ~100-line service with native prometheus_client integration |
| App base image | `python:3.12-alpine` | 142 MB vs 249 MB for slim; all packages have musllinux prebuilt wheels |
| CPU burn method | SHA-256 hashing loop | Real ALU+memory work; `time.sleep` is I/O wait, bare busy-loop can be no-op'd |
| Image tagging | Git SHA only | Immutable, traceable; no floating `latest` |
