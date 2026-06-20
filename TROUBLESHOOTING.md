# Troubleshooting Challenge — Part 3

`troubleshoot/broken-app.yaml` was applied as-is, then diagnosed and fixed iteratively against `troubleshoot/verify.sh` until it printed `PASS`. Seven independent issues across three resources, fixed one at a time, each re-verified before moving to the next. Fixed manifests committed as `troubleshoot/fixed-app.yaml`.

All fixes below were diagnosed and applied manually. The exception is noted in **Issue 6** (NetworkPolicy), where AI assistance was used to draft the allow-rules.

---

## Issue 1 — `ai-inference` pod stuck `Pending`

**Symptom**

```
ai-inference-6fdb9f84d7-4zt78   0/1   Pending   0   2m36s
```

**Diagnosis**

```
kubectl describe pod ai-inference-6fdb9f84d7-4zt78 -n troubleshoot
```

Events showed the pod failing to schedule because the GPU node carries the taint `nvidia.com/gpu=true:NoSchedule` (applied by `prepare.sh`) and the pod spec had no matching toleration. Additionally, the pod's `nodeSelector` used `node-type: gpu`, but the actual label `prepare.sh` applies to the node is `acme.io/node-type: gpu` — so even with a toleration, the selector would never have matched any node.

**Root cause:** two separate problems on the same Deployment — (a) missing toleration for the GPU taint, (b) wrong `nodeSelector` key (unprefixed `node-type` instead of the real label `acme.io/node-type`).

**Fix** (`ai-inference` Deployment, `spec.template.spec`):

```yaml
# before
nodeSelector:
  node-type: gpu

# after
nodeSelector:
  acme.io/node-type: gpu
tolerations:
  - key: "nvidia.com/gpu"
    operator: "Equal"
    value: "true"
    effect: "NoSchedule"
```

Per the assignment rules, the node's taint and label were left untouched — only the workload spec was changed.

---

## Issue 2 — `web` Deployment stuck `Pending` / `MinimumReplicasUnavailable`

**Symptom**

```
kubectl describe deploy web -n troubleshoot
Conditions:
  Available    False   MinimumReplicasUnavailable
  Progressing  False   ProgressDeadlineExceeded
```

**Diagnosis**

Inspected the Deployment spec directly. The `nginx` container requested `memory: 16Gi` (both request and limit), which exceeds the capacity of any single node in the cluster, so the scheduler could never place the pod.

**Root cause:** unrealistic memory request/limit on the `web` container — a sizing typo, not an infra problem.

**Fix** (`web` Deployment container resources):

```yaml
# before
resources:
  requests:
    cpu: 100m
    memory: 16Gi
  limits:
    cpu: 500m
    memory: 16Gi

# after
resources:
  requests:
    cpu: 100m
    memory: "200Mi"
  limits:
    cpu: 500m
    memory: "500Mi"
```

---

## Issue 3 — `web` pod stuck `ContainerCreating` (volume mount failure)

**Symptom**

```
Warning  FailedMount  13s (x8 over 77s)  kubelet  MountVolume.SetUp failed for volume "html" : configmap "web-conf" not found
```

**Diagnosis**

The ConfigMap actually created by the manifest is named `web-config`, but the Deployment's volume references `web-conf` — a name mismatch.

**Root cause:** typo in the Deployment's `volumes[].configMap.name`.

**Fix** (`web` Deployment, `spec.template.spec.volumes`):

```yaml
# before
volumes:
  - name: html
    configMap:
      name: web-conf

# after
volumes:
  - name: html
    configMap:
      name: web-config
```

---

## Issue 4 — `web` pod `ErrImagePull`

**Symptom**

```
web-7cf68cdf69-bvjc2   0/1   ErrImagePull   0   13s
```

**Diagnosis**

`kubectl describe pod` showed the pull failing for `nginx:1.25.99` — not a real published tag on Docker Hub.

**Root cause:** invalid image tag.

**Fix** (`web` Deployment container image):

```yaml
# before
image: nginx:1.25.99

# after
image: nginx:1.30.3
```

---

## Issue 5 — `web` pod `Running` but never `Ready` (liveness/readiness failing, pod restarting)

**Symptom**

```
Warning  Unhealthy  Liveness probe failed: Get "http://10.42.2.11:8080/": dial tcp 10.42.2.11:8080: connect: connection refused
Warning  Unhealthy  Readiness probe failed: Get "http://10.42.2.11:8080/": dial tcp 10.42.2.11:8080: connect: connection refused
Normal   Killing    Container nginx failed liveness probe, will be restarted
```

**Diagnosis**

The container exposes and listens on port 80 (`containerPort: 80`, stock nginx default), but both probes were configured to check port `8080` — a port nothing in the container was listening on, so the probe connections were refused, causing repeated restarts.

**Root cause:** probe port (`8080`) didn't match the actual container port (`80`).

**Fix** (`web` Deployment, both probes):

```yaml
# before
livenessProbe:
  httpGet:
    path: /
    port: 8080
readinessProbe:
  httpGet:
    path: /
    port: 8080

# after
livenessProbe:
  httpGet:
    path: /
    port: 80
readinessProbe:
  httpGet:
    path: /
    port: 80
```

---

## Issue 6 — `verify.sh` step 6/7: Service has no endpoints

**Symptom**

```
[6/7] Service must have ready endpoints...
FAIL: Service 'web-svc' has no endpoints (selector/targetPort?)
```

**Diagnosis**

```
kubectl get svc web-svc -n troubleshoot -o yaml
```

Two problems in the Service spec: the `selector` was `app: webapp`, but the actual pod label (set by the `web` Deployment) is `app: web` — so the Service matched zero pods. Separately, `targetPort: 8080` pointed at the same wrong container port already fixed in Issue 5.

**Root cause:** Service selector didn't match the Deployment's pod labels, and `targetPort` didn't match the container's actual listening port.

**Fix** (`web-svc` Service):

```yaml
# before
spec:
  selector:
    app: webapp
  ports:
    - protocol: TCP
      port: 80
      targetPort: 8080

# after
spec:
  selector:
    app: web
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
```

---

## Issue 7 — `verify.sh` step 7/7: in-cluster smoke test fails despite endpoints being ready

**Symptom**

```
[7/7] In-cluster smoke test through the Service...
curl: (7) Failed to connect to web-svc.troubleshoot.svc.cluster.local port 80 after 2 ms: Couldn't connect to server
FAIL: smoke test failed (check NetworkPolicy/DNS/Service path)
```

**Diagnosis**

By this point the Service had correct selectors/ports and ready endpoints (confirmed by step 6/7 passing), so the remaining blocker had to be the `default-deny` NetworkPolicy from `broken-app.yaml`, which sets `policyTypes: [Ingress, Egress]` with an empty `podSelector` — i.e. default-deny on **all** traffic, both directions, cluster-wide in the namespace. With no allow rules, `verify.sh`'s smoke-test client pod could neither resolve DNS (egress to kube-dns blocked) nor reach `web-svc` (ingress to `web` blocked), even though the Service itself was healthy.

**Root cause:** missing allow-rules to complement the required default-deny policy — not a bug in the app, but a deliberately incomplete network policy that the task requires completing, not deleting.

**This is the one step where AI assistance was used.** Per the assignment's explicit instruction not to delete `default-deny`, I asked Claude to help draft the two least-privilege allow rules needed: ingress to `web` pods from the smoke-test client on port 80, and egress from the smoke-test client to `web` (port 80) and to kube-system for DNS (UDP/TCP 53). I reviewed and verified the rules against `troubleshoot/smoke-job.yaml` to confirm the label selectors (`app: smoke-client`, `app: web`) actually matched the real pod labels before applying, rather than accepting them on trust.

**Fix** (two new NetworkPolicy resources added, `default-deny` left untouched):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-smoke-to-web
  namespace: troubleshoot
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: smoke-client
      ports:
        - protocol: TCP
          port: 80
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-smoke-egress
  namespace: troubleshoot
spec:
  podSelector:
    matchLabels:
      app: smoke-client
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: web
      ports:
        - protocol: TCP
          port: 80
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

After applying, `verify.sh` passed all 7 checks:

```
[1/7] default-deny NetworkPolicy must still exist ... PASS
[2/7] Node labels and taints must be untouched ... PASS
[3/7] Deployment 'web' must be fully rolled out ... PASS
[4/7] Deployment 'ai-inference' must be fully rolled out ... PASS
[5/7] ai-inference pod must be running ON the GPU node ... PASS
[6/7] Service must have ready endpoints ... PASS
[7/7] In-cluster smoke test through the Service ... PASS

PASS
```

---

## Summary

| # | Resource | Symptom | Root cause | Diagnosed/fixed by |
|---|---|---|---|---|
| 1 | `ai-inference` Deployment | Pod `Pending` | Missing GPU toleration + wrong `nodeSelector` key (`node-type` vs `acme.io/node-type`) | Manual |
| 2 | `web` Deployment | `Pending`, `MinimumReplicasUnavailable` | `memory: 16Gi` request/limit exceeds node capacity | Manual |
| 3 | `web` Deployment | `ContainerCreating`, mount failure | ConfigMap name mismatch (`web-conf` vs `web-config`) | Manual |
| 4 | `web` Deployment | `ErrImagePull` | Invalid image tag `nginx:1.25.99` | Manual |
| 5 | `web` Deployment | `Running` but not `Ready`, restart loop | Liveness/readiness probes pointed at port `8080`, container listens on `80` | Manual |
| 6 | `web-svc` Service | No endpoints | Selector mismatch (`app: webapp` vs `app: web`) + wrong `targetPort` (`8080` vs `80`) | Manual |
| 7 | NetworkPolicy | Smoke test can't connect despite healthy Service | `default-deny` had no complementary allow rules for ingress to `web` or egress to DNS/`web` | AI-assisted (Claude), manually verified against `smoke-job.yaml` labels before applying |

Node taints/labels and the `default-deny` NetworkPolicy itself were left fully intact throughout, per the assignment's constraints.
