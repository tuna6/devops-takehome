# DevOps Engineer | Take-Home Assignment

Welcome! This assignment mirrors the actual work you would do on our platform team: Kubernetes operations on a multi-nodepool cluster, GitOps with ArgoCD, CI/CD migration, infrastructure as code, load testing, and troubleshooting — with AI tools as a first-class part of your workflow.

- **Structure — everything below is required:**
  - **CORE** (Parts 1–3 + documentation, ~5 focused hours)
  - **Parts 4–6** — hands-on tracks: **pick at least ONE** — doing two or all three is welcome and scored, but one done well beats three rushed.
  - **Part 7** — short written ops questions (~1 hour).
- **Submission window:** communicated separately with your invitation. Partial submissions are fine: an unfinished part with a clear note beats a missing one.
- **AI tools are encouraged** (Copilot, ChatGPT, Claude, Cursor…). We evaluate *how* you use them. Be aware: we expect you to **verify** AI output — blind, unreviewed AI output will be visible to us, and we will walk through your code together live in the next round.
- **No cloud account needed.** Everything runs locally in Docker. Terraform is validate-only.
- **If you believe a provided file is broken, inconsistent, or missing** — treat it like a production incident: diagnose, decide, work around or fix it, and document what you found and did in your README. How you respond to an imperfect handoff is part of the assessment.

---

## The Golden Rule

Your reviewer will do exactly this — and nothing more — to run your solution:

```bash
git clone <your-repo> && cd <your-repo>
docker compose up -d
./scripts/run-all.sh        # or run scripts/NN-*.sh one by one
```

If that works **without reading any documentation**, you pass the first gate. Specifically:

1. Submit a **public Git repository** (GitHub preferred).
2. Container images must be published to a **public registry** (GHCR is free).
3. `docker-compose.yml` must be **fully self-contained**: it brings up a local Kubernetes cluster with **at least 4 worker nodes** (k3d recommended — agents are just containers) plus a **toolbox container** (kubectl, helm, terraform, k6 pre-installed).
4. Every task is an **individual, numbered script** in `./scripts/`, **bind-mounted** into the toolbox container. Scripts must be idempotent (safe to re-run).
5. As part of cluster bootstrap, run the provided `troubleshoot/prepare.sh` — it labels and taints nodes to simulate our production nodepools (spot / on-demand / GPU).
6. A write-up (`README.md`) explains what each script does — but the reviewer should not *need* it to get a running system.

> **Note on CNI:** Part 3 requires NetworkPolicy enforcement. k3d/k3s enforces it out of the box; if you choose kind, install Calico/Cilium yourself.

---

# CORE (required, ~5h)

## Part 1 — Build & Ship a Small Service

Write a small HTTP API (~100 lines, Python/Go/Node — your choice) that exposes:

- `GET /healthz` — liveness
- `GET /readyz` — readiness
- `GET /metrics` — Prometheus format (at least one custom counter, e.g. requests total)
- `GET /api/quote` — returns a random motivational quote as JSON, **with ~100ms of simulated CPU work per request** (so it can be load-tested meaningfully in Part 6)

Requirements:

- **Multi-stage Dockerfile**, runs as **non-root**, sensible image size.
- Image pushed to GHCR, tagged with the **git SHA** (a floating `latest` alone is not acceptable).

## Part 2 — GitOps Deployment with Spot/On-Demand Placement

Our production clusters mix spot and on-demand nodepools; high-priority services must survive spot reclaims. `troubleshoot/prepare.sh` has labeled your local nodes to simulate our nodepools:

- 2 nodes: `acme.io/capacity=spot`
- 1 node: `acme.io/capacity=on-demand`
- 1 node: `acme.io/node-type=gpu` + tainted `nvidia.com/gpu=true:NoSchedule` (used in Part 3 — your Part 2 app should not land there)

Your job, via `scripts/20-deploy.sh`:

1. **Install ArgoCD** into the cluster and deploy your service through an ArgoCD `Application` that syncs **your own Helm chart from your repo** — no manual `helm install` of your app.
2. Write **your own Helm chart** (no copying a full chart) with: probes, resource requests/limits, `securityContext` (non-root, read-only rootfs), Service + Ingress, **HPA (minReplicas: 3)** and PodDisruptionBudget.
3. **Placement policy:** with 3 replicas —
   - replicas must **prefer spot** nodes (cost),
   - but **at least one replica must always run on the on-demand node** (availability),
   - replicas should be spread across nodes — keep the spread **soft enough that rescheduling still works when a node disappears** (think through what a hard constraint would do during the drill below).
   Implement with node affinity weights + topology spread constraints (or equivalent). Hard-pinning all replicas to on-demand defeats the purpose and scores zero.
4. **Prove it survives a reclaim:** `scripts/25-reclaim-drill.sh` must drain one spot node, show the service still answers (`curl` loop), show pods rescheduling, then uncordon.
5. After deploy, `curl http://localhost:<port>/api/quote` from the host must work.

## Part 3 — Troubleshooting Challenge

The folder `troubleshoot/` (provided) contains `broken-app.yaml` — workloads broken in **multiple independent ways** — plus `prepare.sh`, `verify.sh` and `smoke-job.yaml`.

1. Make sure `troubleshoot/prepare.sh` has been run (your compose bootstrap should already do this).
2. Apply the broken manifests: `kubectl apply -f troubleshoot/broken-app.yaml`
3. Diagnose and fix **all** issues until `./troubleshoot/verify.sh` prints `PASS`.
4. Rules:
   - **Deleting the NetworkPolicy is not an accepted fix.** Keep default-deny and add least-privilege allow rules.
   - **Removing taints or labels from nodes is not an accepted fix.** Fix the workloads, not the nodes. (`verify.sh` checks both.)
   - Commit your fixed manifests as `troubleshoot/fixed-app.yaml`.
5. Write `TROUBLESHOOTING.md`: for **each** issue — the symptom, the exact commands you used to diagnose it, the root cause, and the fix. The narrative matters as much as the fix.

## Documentation (required)

Your `README.md` must contain:

1. **Quick start** — the exact commands to bring everything up (should match the Golden Rule).
2. **Architecture diagram** — how the pieces fit together: compose → cluster → nodepools → ArgoCD → your app → ingress path. Mermaid in the README is perfect; a committed image also works. We read this diagram *before* your code.
3. **Script reference** — one line per script: what it does and when to run it.
4. **Design decisions & trade-offs** — short bullets: what you chose, what you cut, and why.
5. **Troubleshooting notes** — 2–3 things that can go wrong on the reviewer's machine (ports, resources, arch) and the fix.

**Bonus:** a second diagram showing how you would run this same service in production on AWS (EKS, nodepools incl. GPU/spot, RDS, ingress/CDN path, observability) — boxes and arrows, not marketing art.

## AI Usage Disclosure (required)

Create `AI-USAGE.md`:

- Which AI tools you used and for which parts.
- 2–3 representative prompts that actually moved you forward.
- **At least one example where the AI was wrong or suboptimal**, how you caught it, and what you did.

We expect heavy AI usage. What we screen for is whether you can **verify, correct, and own** AI output. "I didn't use AI" is a valid answer only if it's true — we will ask you to walk through your code live either way.

---

# Hands-On Tracks — Parts 4–6 (required: pick at least ONE)

Choose the part that shows you best — your choice is part of the signal. Doing more than one is welcome and scored, quality first.

## Part 4 — CI/CD Migration (GitLab → GitHub Actions)

We are migrating pipelines from GitLab CI to GitHub Actions — a real, ongoing project here. The provided `ci/legacy.gitlab-ci.yml` is a typical legacy pipeline. **It contains practices we are explicitly migrating away from. Migrate it, don't photocopy it.**

Deliver a working GitHub Actions workflow (green runs visible in your public repo) that:

1. Builds your Part 1 image and pushes to GHCR with correct tagging.
2. Runs a **static code-quality/SAST scan that hard-fails the pipeline** on findings. Pick one: **SonarQube Community Edition** (self-hosted in your compose harness), **Semgrep**, or **SonarCloud** (free for public repos). Whatever you pick, the legacy pipeline's broken quality job must not survive the migration in spirit — a scan that can never fail is decoration, not a gate.
3. A short `MIGRATION-NOTES.md`: what you changed from the legacy pipeline and **why**, and how you would migrate the GitLab CI variables/secrets for a real project.

**Bonus:** Trivy image scan gating on HIGH/CRITICAL, cosign image signing.

## Part 5 — IaC Design: Karpenter & Cloudflare (validate-only)

Real tickets from our backlog, scaled down:

**5a — Karpenter for GPU AI services.** Write the Karpenter resources (YAML) for a GPU inference workload on EKS:

- A NodePool + its node class for GPU instances: **spot preferred, on-demand fallback** (weights), proper taint (`nvidia.com/gpu:NoSchedule`), consolidation policy that won't kill long-running inference mid-request, sensible limits.
- Use the **current stable Karpenter API**. Outdated API versions are an automatic red flag — verify against current docs, not just your AI's memory.
- One paragraph: spot vs on-demand trade-off for AI inference workloads.

**5b — Cloudflare in Terraform.** Our DNS/CDN runs on Cloudflare managed by Terraform:

- A proxied DNS record for `quote-api.example.com`, a cache rule that bypasses cache for `/api/*` and caches static assets aggressively, and an **`import` block** adopting a pre-existing manually-created record (we regularly adopt manually-created resources into Terraform).
- `scripts/50-validate-tf.sh` runs `terraform fmt -check`, `init -backend=false`, `validate` in the toolbox and passes.

## Part 6 — Load Test, Scaling Proof & Observability (k6 + Prometheus)

Using the toolbox container (`scripts/60-loadtest.sh`):

1. **Install Prometheus + Grafana** in the cluster (kube-prometheus-stack gives you both) with Prometheus scraping your app's `/metrics` from Part 1.
2. A k6 script ramping load against your deployed service **through the Ingress**, with `thresholds` you chose — justify each threshold from your own measured baseline, not generic numbers.
3. **Prove HPA scale-out:** capture `kubectl get hpa -w` / pod events during the run showing replicas scaling beyond 3, and confirm new replicas still respect the Part 2 spot/on-demand placement.
4. **One meaningful alert rule** (PrometheusRule) for your service — e.g. error rate or latency based — with one paragraph justifying the threshold using what you observed under load.
5. **A small Grafana dashboard** for your service (3–4 panels: request rate, latency, replica count, CPU) — commit the dashboard JSON + a screenshot taken **during** the load test.
6. `LOADTEST.md` (half a page): max sustainable RPS on your machine, where the bottleneck is (app CPU? node capacity? ingress?), and what you would scale first in production and why.

# Part 7 — Ops Questions (required, max 1.5 pages total, `OPS-ANSWERS.md`)

1. You must upgrade EKS 1.33 → 1.35 across control plane, addons (vpc-cni, coredns, kube-proxy, EBS/EFS CSI) and worker nodes with zero downtime. Outline order and top 3 risks.
2. Spot reclaims at 3 AM trigger `KubeNodeUnreachable` alert storms, paging the on-call for non-issues. Design an alerting strategy that kills the false positives **without** missing real node failures.
3. A marketing site sits behind Cloudflare, but mobile Core Web Vitals are failing (LCP 5s). You suspect HTML caching isn't working. Walk through your diagnosis step by step (headers, rules, origin).
4. How would you manage application secrets on EKS? Compare two approaches and pick one for a startup running multiple production EKS clusters.

**Bonus (any part):** APM-style tracing (e.g. OpenTelemetry sidecar/SDK) on the quote endpoint.

---

## Deliverables Checklist

| # | Item | Tier |
|---|------|------|
| 1 | Public repo: compose harness (≥4-node cluster) + numbered scripts in `./scripts/` (bind-mounted) | CORE |
| 2 | App + multi-stage Dockerfile; image on GHCR tagged by git SHA | CORE |
| 3 | Helm chart deployed **via ArgoCD Application**; spot/OD placement + reclaim drill script | CORE |
| 4 | `troubleshoot/fixed-app.yaml` + `TROUBLESHOOTING.md`; `verify.sh` prints PASS | CORE |
| 5 | `README.md` (quick start, **architecture diagram**, script reference, decisions, troubleshooting notes) | CORE |
| 6 | `AI-USAGE.md` | CORE |
| 7 | Part 4: GitHub Actions migration + hard-failing quality gate (SonarQube CE / Semgrep / SonarCloud) + `MIGRATION-NOTES.md` | PARTS 4–6 — pick ≥1 |
| 8 | Part 5: Karpenter YAML + Cloudflare TF + validate script | PARTS 4–6 — pick ≥1 |
| 9 | Part 6: Prometheus + Grafana (dashboard JSON + screenshot under load) + k6 script + HPA scale-out evidence + alert rule + `LOADTEST.md` | PARTS 4–6 — pick ≥1 |
| 10 | `OPS-ANSWERS.md` | PART 7 — required |

**Do not:** commit secrets of any kind (instant fail), require manual reviewer steps, or gold-plate. Say what you cut and why in the README — knowing what to skip is a senior skill.

Submit the repo URL + GHCR image URL by email. Good luck — and have fun with it.
