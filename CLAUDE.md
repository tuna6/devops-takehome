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

## What has been built (session 2026-06-19)

### Cluster harness (bootstrap layer only)

`docker compose up -d` alone brings up a working 5-node k3d cluster. No manual steps needed.

**Files produced / fixed:**

| File | Status | Notes |
|---|---|---|
| `toolbox/Dockerfile` | fixed + written | k3d v5.9.0, kubectl v1.36.2, helm v4.2.2, terraform v1.15.6, k6 **v1.8.0** |
| `docker-compose.yml` | fixed | DooD via socket, `extra_hosts` for cross-platform API access |
| `scripts/00-bootstrap-cluster.sh` | fixed | Creates 5-node cluster, patches kubeconfig, idempotent |
| `scripts/run-all.sh` | exists | Calls 00-bootstrap-cluster.sh; expand as parts are added |
| `README.md` | written | All 5 required sections |

**Bugs fixed from the original Haiku-generated code:**

1. **k6 double-v URL bug** — `K6_VERSION=v2.0.0` + `k6-v${K6_VERSION}` → `k6-vv2.0.0` (404).
   Fixed: changed to `v1.8.0` and `k6-${K6_VERSION}`.

2. **DooD kubeconfig unreachable** — k3d writes `https://0.0.0.0:6443` in kubeconfig; from
   inside a container that address doesn't reach the host's API server.
   Fixed: `--api-port 6443` pins the port; `sed` patches server URL to `host.docker.internal:6443`;
   `--k3s-arg '--tls-san=host.docker.internal@server:*'` adds the hostname to the TLS cert SAN;
   `extra_hosts: host.docker.internal: host-gateway` resolves it inside containers.

3. **`KUBECONFIG` not exported** — bootstrap called `prepare.sh` without exporting `KUBECONFIG`,
   so prepare.sh's bare `kubectl` calls had no kubeconfig to find.
   Fixed: `export KUBECONFIG="$KUBECONFIG_PATH"` added before the prepare.sh invocation.

4. **`k3d node list --cluster` invalid flag** — k3d v5.9.0 has no `--cluster` flag on `node list`.
   Fixed: `awk -v c="$CLUSTER_NAME" '$3 == c && $2 != "loadbalancer"'` to filter by CLUSTER column.

5. **Duplicate `kubectl wait` block** — identical two-line block copy-pasted twice. Removed.

6. **Docker socket mounted `:ro`** — changed to `:rw` on both services.

7. **Scripts not executable** — `chmod +x scripts/*.sh` (permissions were never set).

### What is NOT yet built

- Part 1: app (Python/Go/Node HTTP service + Dockerfile)
- Part 2: Helm chart, ArgoCD Application, spot/on-demand placement, reclaim drill
- Part 3: troubleshoot/fixed-app.yaml + TROUBLESHOOTING.md (provided assets not yet extracted from zip)
- Parts 4–6: CI/CD, IaC, load test (pick ≥1)
- Part 7: OPS-ANSWERS.md
- AI-USAGE.md

### Provided assets (not yet extracted)

The file `../devops-takehome-package.zip` (one level above the repo) contains:
- `troubleshoot/prepare.sh`, `broken-app.yaml`, `verify.sh`, `smoke-job.yaml`
- `ci/legacy.gitlab-ci.yml`

These need to be extracted into the repo when starting Part 2/3/4.

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
