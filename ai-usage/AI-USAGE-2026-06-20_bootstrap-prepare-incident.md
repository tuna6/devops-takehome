# AI Usage Disclosure — Bootstrap Incident: prepare.sh not applied to live cluster

**Date:** 2026-06-20  
**Part:** Part 0 (Golden Rule / cluster bootstrap)

---

## What was broken

After running `docker compose up -d`, the k3d cluster had **no `acme.io/*` labels and no GPU taint** on any node. `kubectl get nodes --show-labels` showed only the default k3s system labels. The assignment requires:

- agent-0, agent-1: `acme.io/capacity=spot`
- agent-2: `acme.io/capacity=on-demand`
- agent-3: `acme.io/node-type=gpu` + taint `nvidia.com/gpu=true:NoSchedule`

`troubleshoot/prepare.sh` was present and executable in the repo, and `scripts/00-bootstrap-cluster.sh` already contained the correct call site with an `[ -x "$TRIAGE_SCRIPT" ]` guard. So the invocation logic was right.

---

## Diagnosis

Checked the bootstrap container logs:

```
docker logs devops-takehome-bootstrap-1
```

Key line near the end:

```
No troubleshoot/prepare.sh found yet; skipping prepare step safely.
Bootstrap complete; cluster "elsa-devops" is ready.
```

The guard evaluated false at runtime. Cross-referencing timestamps: the bootstrap container ran ~13 hours ago; `troubleshoot/prepare.sh` was extracted from `devops-takehome-package.zip` and committed **after** that initial bootstrap run. The file simply didn't exist on disk when the bootstrap container executed the `[ -x ]` check.

No bug in the script logic — a sequencing issue: bootstrap ran before the troubleshoot assets were in place.

---

## Fix

Full teardown and fresh boot to verify the fix holds from a clean state.

**1. Tear down — compose stack and all k3d cluster containers:**

```bash
docker compose down -v
docker ps -a --filter "name=k3d-elsa-devops" --format '{{.Names}}' | xargs -r docker rm -f
docker network ls --filter "name=k3d-elsa-devops" --format '{{.Name}}' | xargs -r docker network rm
docker volume ls --filter "name=k3d-elsa-devops" --format '{{.Name}}' | xargs -r docker volume rm
```

(`docker compose down -v` stops the toolbox/bootstrap containers; the k3d cluster containers are not part of the compose stack and must be removed separately.)

**2. Fresh boot — Golden Rule path:**

```bash
docker compose up -d
```

Bootstrap log (relevant section):

```
Verifying Kubernetes nodes are Ready...
NAME                       STATUS   ROLES           AGE   VERSION
k3d-elsa-devops-agent-0    Ready    <none>          8s    v1.35.5+k3s1
...
node/k3d-elsa-devops-agent-3 condition met
Found troubleshoot/prepare.sh; running prepare step...
Labeling k3d-elsa-devops-agent-0 as SPOT
node/k3d-elsa-devops-agent-0 labeled
Labeling k3d-elsa-devops-agent-1 as SPOT
node/k3d-elsa-devops-agent-1 labeled
Labeling k3d-elsa-devops-agent-2 as ON-DEMAND
node/k3d-elsa-devops-agent-2 labeled
Labeling + tainting k3d-elsa-devops-agent-3 as GPU
node/k3d-elsa-devops-agent-3 labeled
node/k3d-elsa-devops-agent-3 modified

Node preparation done:
NAME                       STATUS   ROLES           AGE   VERSION        CAPACITY    NODE-TYPE
k3d-elsa-devops-agent-0    Ready    <none>          9s    v1.35.5+k3s1   spot
k3d-elsa-devops-agent-1    Ready    <none>          9s    v1.35.5+k3s1   spot
k3d-elsa-devops-agent-2    Ready    <none>          9s    v1.35.5+k3s1   on-demand
k3d-elsa-devops-agent-3    Ready    <none>          9s    v1.35.5+k3s1               gpu
k3d-elsa-devops-server-0   Ready    control-plane   12s   v1.35.5+k3s1
Bootstrap complete; cluster "elsa-devops" is ready.
```

Exit 0. Bootstrap container (`devops-takehome-bootstrap-1`) exited cleanly.

---

## Verification output (from inside toolbox container)

```
$ docker exec elsa-devops-toolbox kubectl get nodes --show-labels

NAME                       STATUS   ROLES           AGE   VERSION        LABELS
k3d-elsa-devops-agent-0    Ready    <none>          21s   v1.35.5+k3s1   acme.io/capacity=spot,...
k3d-elsa-devops-agent-1    Ready    <none>          21s   v1.35.5+k3s1   acme.io/capacity=spot,...
k3d-elsa-devops-agent-2    Ready    <none>          21s   v1.35.5+k3s1   acme.io/capacity=on-demand,...
k3d-elsa-devops-agent-3    Ready    <none>          21s   v1.35.5+k3s1   acme.io/node-type=gpu,...
k3d-elsa-devops-server-0   Ready    control-plane   24s   v1.35.5+k3s1   node-role.kubernetes.io/control-plane=true,...

$ docker exec elsa-devops-toolbox kubectl describe node k3d-elsa-devops-agent-3 | grep Taints
Taints: nvidia.com/gpu=true:NoSchedule
```

---

## Lessons / what the AI missed

The original Claude Code session (2026-06-19) that wrote `00-bootstrap-cluster.sh` included the `prepare.sh` call and guard. That part was correct. What it didn't flag was the **ordering dependency**: if someone runs `docker compose up -d` before the troubleshoot assets are extracted from the zip, the guard silently skips without error, leaving the cluster in an unlabeled state with no warning in the final "Bootstrap complete" message.

The silent skip is a reasonable design choice (it lets bootstrap succeed even when troubleshoot is absent), but the misleading "Bootstrap complete" message at the end gives no indication that node preparation was skipped. A reviewer cloning a fresh repo and running the Golden Rule commands would end up with an unlabeled cluster and Part 2/3 would silently break.

**The AI also skipped the correct verification path.** When asked to fix and verify, the AI's first instinct was to run `prepare.sh` directly inside the running toolbox container (`docker exec elsa-devops-toolbox /workspace/troubleshoot/prepare.sh`) rather than tearing down the entire stack and re-running `docker compose up -d` from scratch. That shortcut proved the script works in isolation but did not prove the end-to-end bootstrap flow — a reviewer cloning the repo and running the Golden Rule would have exercised a different code path entirely. The correct verification is always: full teardown → fresh boot → confirm the expected state, which is what was done after the issue was flagged.

**Remediation already in place:** `troubleshoot/` is now committed alongside all other scripts. On a fresh clone the files will be present before bootstrap runs, so the guard will pass on the first run. A dedicated `scripts/99-teardown.sh` was also added to make the full teardown + re-verify cycle a one-command operation.
