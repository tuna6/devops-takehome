# OPS-ANSWERS.md

## Q1 — EKS 1.33 → 1.35 zero-downtime upgrade

**Order**

1. **Pre-flight.** Scan live manifests with Pluto/`kubent` for APIs removed in 1.34/1.35 and fix hits first. Audit PDBs for drain headroom (`allowedDisruptions ≥ 1` at current replica count) — a tight PDB is the most common cause of a stuck drain. Dry-run on a cloned staging cluster.
2. **Control plane, one minor at a time.** 1.33 → 1.34, wait healthy, then 1.34 → 1.35. EKS rolls the API server with HA; minor versions can't be skipped.
3. **Managed addons after each hop, in dependency order:** `vpc-cni` → `kube-proxy` → `coredns` → `aws-ebs-csi` / `aws-efs-csi`. Pin each to the version certified for the new control-plane minor; don't jump ahead of it.
4. **Worker nodes last.** Kubelet skew tolerance is n-3, so nodes at 1.33 stay valid under a 1.35 control plane — I finish both control-plane + addon hops first and replace nodes **once** rather than per hop. Roll nodegroup-by-nodegroup with surge (`maxSurge:1, maxUnavailable:0`): bring up a new-version node, cordon + drain the old (respecting PDBs), verify Ready, repeat. Spot/cheap pools first, on-demand critical pools last.

**Top 3 risks**

- **PDB deadlock on drain.** `minAvailable` too close to replica count blocks eviction indefinitely. Directly relevant here: my app runs `minAvailable=2` on 3 replicas — fine draining one node at a time, but I'd confirm replicas are spread so two aren't co-located before draining. *Mitigate:* pre-audit PDBs, temporarily bump replicas for headroom.
- **vpc-cni upgraded after nodes → pod IP allocation failures.** A new kubelet against an old `aws-node` DaemonSet can't assign pod IPs. *Mitigate:* upgrade vpc-cni and confirm the DaemonSet fully rolled out **before** draining any node.
- **Removed APIs.** `policy/v1beta1`, older `networking.k8s.io`, etc. silently break controllers post-upgrade. *Mitigate:* the pre-flight Pluto scan + staging dry-run.

## Q2 — Spot reclaim alert storms at 3 AM

**Why it fires.** A reclaimed spot node vanishes in ~2 min, but Kubernetes takes ~5 min to flip it `NotReady` and begin eviction, so `KubeNodeUnreachable` pages for a self-healing event. In Part 6 I watched this exact signature: node goes NotReady, pods reschedule in ~3 min, and the service never drops because `minAvailable=2` + HPA + topology-spread absorb it. The page was pure noise.

**Strategy — alert on impact, not node state**

1. **Intercept the reclaim** so the drain is graceful and recorded: Karpenter's native interruption handling, or EKS managed-node-group auto-drain, or NTH on self-managed nodes. This emits a spot-interruption event we can key off.
2. **Replace the node alert with golden-signal alerts:** request error-rate > 1% for 5m, **or** healthy replicas < `minAvailable` for 5m. These fire only if a reclaim *actually* hurt users — which, with correct placement/PDB, it won't.
3. **If you keep `KubeNodeUnreachable`, gate it — don't delete it.** Raise `for` to 10–15m (a real failure also stays unreachable, so you lose no coverage) **and** add an Alertmanager inhibition: suppress it when the node carries `acme.io/capacity=spot` **and** a spot-interruption event was seen in the last 5 min. Event-gated beats a blanket spot-label exclusion, which would also hide a genuine spot-node hardware failure.

**Don't:** globally silence `KubeNodeUnreachable`. An on-demand kubelet crash looks identical at the node level and must still page.

## Q3 — Cloudflare HTML cache miss → 5s mobile LCP

Mobile LCP surfaces it first because a cache MISS forces an origin round-trip whose RTT dominates on constrained mobile networks; field/CrUX data is mobile-weighted.

1. **Confirm it's caching, not slow origin.** `curl -I https://site/` and read `cf-cache-status`. Repeated `MISS`/`BYPASS`/`DYNAMIC` from one PoP = HTML isn't cached. `HIT` → look elsewhere (render-blocking JS/CSS, hero-image weight).
2. **Check what origin tells Cloudflare.** Hit origin directly: `curl -I --resolve site:443:<origin-ip> https://site/`. `Cache-Control: private/no-store/no-cache` means Cloudflare obeys and won't cache — fix at origin, or knowingly override with a cache rule.
3. **Cookies — the usual marketing-site culprit.** Cloudflare bypasses cache by default on any request carrying cookies. An analytics/consent/A-B cookie set on the HTML response makes every hit a MISS. *Fix:* a cache rule that ignores non-content cookies, and stop `Set-Cookie` on cacheable HTML.
4. **Rules audit.** Confirm no Page/Cache rule sets `Bypass` on `/`. A loosely written `/api/*` bypass (e.g. `*api*`) can accidentally match the root path.
5. **Verify the fix.** A cached response carries `Age:` > 0 and `cf-cache-status: HIT` on the second request; spot-check a couple of PoPs.

## Q4 — Secrets on multi-cluster EKS

**A) AWS Secrets Manager + External Secrets Operator (ESO).** Secrets live once in ASM; ESO in each cluster syncs them into native K8s Secrets; IRSA scopes which namespace reads which secret; rotation in ASM propagates on ESO's refresh interval; CloudTrail provides audit for free.

**B) Sealed Secrets (Bitnami).** Encrypt client-side with a **cluster-specific** public key, commit the `SealedSecret` to Git, in-cluster controller decrypts at runtime. Pure GitOps, no cloud dependency.

**Pick for a startup on multiple EKS clusters: A (ASM + ESO).** One authoritative copy referenced by every cluster — no per-cluster re-encryption and no per-cluster key to rotate, which is exactly where Sealed Secrets hurts past one cluster (rotating a secret = re-sealing against each cluster's key). They're already on AWS, so IRSA + CloudTrail come free. Honest trade-offs: ESO adds a controller per cluster, syncs are eventually-consistent (interval lag), and an over-broad IAM policy widens blast radius — so scope IRSA per namespace. Sealed Secrets remains the better call only for a no-cloud, fully-GitOps shop.
