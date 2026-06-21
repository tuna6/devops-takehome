# CI/CD Migration Notes — GitLab CI → GitHub Actions (Part 4)

Source file migrated: `ci/legacy.gitlab-ci.yml`  
Target file: `.github/workflows/ci.yml`  
Date: 2026-06-21

---

## What Changed from the Legacy Pipeline and Why

The legacy pipeline's **intent** was preserved (build, scan, push). Its **practices** were not — several are explicitly what we are migrating away from. Each is addressed below.

### Issue 1 — Hardcoded AWS credentials in `variables:`

**Legacy:**
```yaml
variables:
  AWS_ACCESS_KEY_ID: "AKIAIOSFODNN7EXAMPLE"
  AWS_SECRET_ACCESS_KEY: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
```

**What changed:** Dropped entirely. These are example values in the legacy file, but even as a structural pattern they have no place in the new pipeline. The registry in this project is GHCR (GitHub Container Registry), and authentication is handled via `GITHUB_TOKEN` — a short-lived, workflow-scoped token provisioned automatically by GitHub Actions with no IAM credentials required.

**Why:** Baking AWS keys (even placeholders) in CI YAML creates a credential-in-source-of-truth habit and a leak surface. `GITHUB_TOKEN` scoped to `packages: write` is sufficient and requires no rotation or storage.

---

### Issue 2 — `sonar_check` with `allow_failure: true`

**Legacy:**
```yaml
sonar_check:
  allow_failure: true
```

**What changed:** The quality gate is now a **Semgrep SAST scan** in the `build-scan-push` job, running **before** the Docker build step, with `--error` which exits 1 on any finding. `allow_failure` is not used anywhere in the new pipeline.

**Why:** A quality gate that cannot fail the pipeline is not a gate — it is decoration. The legacy `allow_failure: true` means Sonar findings are informational at best. The new pipeline makes the scan a hard prerequisite: the image is not built if Semgrep finds issues.

**Tool choice:** Semgrep over SonarCloud because Semgrep requires no external self-hosted instance, no account for open-source repos with `--config auto`, and its findings are actionable (it scans source, not built artifacts, and maps findings directly to lines). SonarCloud would be an equally valid choice for a team that already uses it.

---

### Issue 3 — `unit_test` swallowing failures

**Legacy:**
```yaml
npm test || echo "tests flaky, continuing"
```

**What changed:** This pattern is not carried forward in any form. The `|| echo` pattern silently converts a test failure into a success, making the CI status meaningless.

**Note:** The legacy pipeline ran `npm test` against what is actually a Python/FastAPI service — another residual error (see Issue 5). No unit test step was added in the new pipeline because the assignment scope for Part 4 is the CI migration itself; if unit tests are added later, they must hard-fail (`pytest` with a non-zero exit code propagating naturally, no swallowing).

---

### Issue 4 — `docker push "$IMAGE_NAME:latest"` (floating tag)

**Legacy:**
```yaml
- docker push "$IMAGE_NAME:latest"
```

**What changed:** The new pipeline pushes **only** `ghcr.io/${{ github.repository }}:${{ github.sha }}` — the full 40-character commit SHA. No `latest` tag, no branch-name tag, no moving tag of any kind.

**Why:** A floating `latest` tag makes image provenance opaque: you cannot determine which source commit produced a running container. The SHA tag is immutable and traceable. This is consistent with Part 1's `scripts/10-build-push.sh` which also tags by git SHA.

---

### Issue 5 — `node:16` base image for a Python service

**Legacy:**
```yaml
unit_test:
  image: node:16
```

**What changed:** Dropped entirely. The service is Python/FastAPI — `node:16` was residual cruft from a prior service or a template copy. All steps in the new pipeline use `ubuntu-latest` GitHub-hosted runners (managed by GitHub), and language tooling (Python for Semgrep, Docker for build) is invoked directly without a per-job image sidecar.

---

### Issue 6 — `docker:20.10-dind` service sidecar

**Legacy:**
```yaml
services:
  - docker:20.10-dind
```

**What changed:** Not used. The new pipeline uses `docker/build-push-action` with `docker/setup-buildx-action`, which operates via the Docker daemon already present on the GitHub-hosted runner without a DinD (Docker-in-Docker) sidecar.

**Why DinD is undesirable:**
- DinD requires `--privileged`, which is a significant security escalation.
- It is fragile: the inner daemon must start before any `docker` command runs, and the TLS/socket handoff between the outer and inner daemon is a common source of flaky CI.
- GitHub-hosted runners have a native Docker daemon; there is no reason to run a second daemon inside a container.

---

### Issue 7 — `deploy_prod` stage with `kubectl set image`

**Legacy:**
```yaml
deploy_prod:
  script:
    - kubectl set image deployment/quote-api quote-api="$IMAGE_NAME:latest" -n production
```

**What changed:** This stage is **not migrated at all**. It is deliberately absent from the new pipeline.

**Why:** Imperative `kubectl set image` is the anti-pattern that GitOps exists to replace. In this project, deployment is handled by the ArgoCD Application in `argocd/quote-api-application.yaml`, which watches `helm/quote-api/values.yaml` in this repository. The new pipeline's write-back step updates `image.tag` in that file and commits it; ArgoCD detects the change and reconciles the cluster to match. The pipeline's responsibility ends at publishing a scanned, tagged image and committing the tag to the Helm values file. ArgoCD owns the rest.

This also eliminates the `KUBECONFIG_CONTENT` secret entirely — see Secrets Migration below.

---

## Loop-Prevention: Path Filter + `[skip ci]`

The write-back step commits and pushes a change to `helm/quote-api/values.yaml`. Without loop prevention, this push would re-trigger the CI workflow, which would build and push the same image again, update the same values.yaml, and loop indefinitely.

Two independent safeguards prevent this:

**Layer 1 — `paths` filter (primary):**
```yaml
on:
  push:
    branches: [main]
    paths:
      - 'src/**'
      - 'Dockerfile'
```
The write-back commit only touches `helm/quote-api/values.yaml`, which is outside `src/**` and `Dockerfile`. GitHub evaluates the paths filter against the changed files in each push; a push that only modifies `helm/quote-api/values.yaml` does not match the filter and does not trigger a workflow run.

**Layer 2 — `[skip ci]` in the commit message (belt-and-suspenders):**
```
ci: update image tag to <sha> [skip ci]
```
GitHub Actions recognizes `[skip ci]` in a commit message and skips all triggered workflows for that push. This is a backup in case the paths filter is ever broadened (e.g., someone adds `helm/**` to it) or is misread.

**Third layer (implicit):** GitHub Actions does not trigger new workflow runs from commits pushed by `GITHUB_TOKEN`. This is a platform-level protection. The path filter and `[skip ci]` make the intent explicit in the code regardless.

All three are documented here because relying on implicit platform behaviour without documentation is a maintenance trap.

---

## Secrets Migration: Legacy GitLab → GitHub Actions

The legacy pipeline used four secrets/variables. Here is how each maps to GitHub Actions:

| Legacy Variable | Legacy Purpose | GitHub Actions Equivalent | Notes |
|---|---|---|---|
| `AWS_ACCESS_KEY_ID` | Push to ECR | — | **Eliminated.** Registry is GHCR; `GITHUB_TOKEN` handles auth. |
| `AWS_SECRET_ACCESS_KEY` | Push to ECR | — | **Eliminated.** Same reason. |
| `SONAR_HOST_URL` + `SONAR_TOKEN` | SonarQube auth | `SEMGREP_APP_TOKEN` (optional) | Semgrep's `--config auto` works without authentication for public repos using the public Semgrep registry. For private repos or commercial Semgrep features, add `SEMGREP_APP_TOKEN` as a **repository secret** (`Settings → Secrets and variables → Actions → New repository secret`). |
| `KUBECONFIG_CONTENT` | `kubectl set image` in `deploy_prod` | — | **Eliminated entirely.** The `deploy_prod` stage was not migrated; the cluster is updated via ArgoCD watching this repo. No CI job needs direct cluster access. |

**GitHub Actions mechanism for real-project secret migration:**
- Short-lived, scoped secrets (tokens, registry auth): use `GITHUB_TOKEN` where possible — it is provisioned per-run with the minimum permissions declared in the workflow `permissions:` block.
- Long-lived credentials that cannot use `GITHUB_TOKEN` (e.g., a third-party service's API key): store as **repository secrets** (`Settings → Secrets and variables → Actions → New repository secret`) for repo-scoped access, or as **environment secrets** (`Settings → Environments → <env name> → Add secret`) if the secret should only be available to deployments targeting a named environment (e.g., `production`). Environment secrets add an approval gate and restrict which branches can trigger the deployment.
- The GitLab CI equivalent of repository secrets is `Settings → CI/CD → Variables`; the mapping is 1:1 in concept.
