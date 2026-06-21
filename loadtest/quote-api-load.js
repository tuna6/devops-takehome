import http from "k6/http";
import { check } from "k6";

// ---------------------------------------------------------------------------
// Baseline (measured 2026-06-21, toolbox container, k6 v1.8.0, via Ingress):
//   VUs: 1, Duration: 30s
//   Requests: 271 (9.0 RPS sequential)
//   p50: 102ms  p90: 138ms  p95: 139ms  max: 139ms  errors: 0%
//
// The 102ms floor = SHA-256 CPU burn in _cpu_burn_100ms() (src/main.py).
// The ~39ms above floor = Traefik ingress + HTTP stack overhead.
//
// Capacity model — revised after first real load test run:
//
// Initial (WRONG) estimate:
//   Assumed get_quote() is serial — 1 request/100ms per pod → 5 RPS/pod max.
//   3 pods × 5 RPS/pod = 15 RPS total → HPA saturated quickly → Little's Law
//   predicted p95 ≈ 1333-1700ms. This was wrong for two reasons:
//
//   1. FastAPI/anyio runs sync handlers (`def`, not `async def`) in a thread pool.
//      Default pool size = min(32, os.cpu_count()+4). Pod containers see the host's
//      16 CPUs → min(32, 20) = 20 threads per pod. Each pod can handle up to 20
//      concurrent requests simultaneously, not 1-at-a-time.
//      Evidence: at t=1:01 into the test (5 VUs on 3 pods), k6 measured 42 RPS actual
//      vs 15 RPS predicted. The serial model was off by ~3×.
//
//   Note on CPU throttling — the quota IS enforced (confirmed via cgroup data):
//      $ kubectl exec -n quote-api <pod> -- cat /sys/fs/cgroup/cpu.max
//      50000 100000   ← 500m quota correctly programmed
//      $ kubectl exec -n quote-api <pod> -- cat /sys/fs/cgroup/cpu.stat
//      nr_periods    48333   (pod jsnh8, running since first load test, captured 2026-06-21T09:55:59Z)
//      nr_throttled   5213   (10.8% of periods hit the CPU limit)
//      throttled_usec 225877632   (226 seconds of cumulative throttle time)
//      Pod csjf9 (same era): nr_throttled=6034/44380 periods = 13.6%, throttled_usec=291s
//      The kernel IS enforcing cfs_quota — throttling is real and significant under load.
//      But throttling is NOT why the original prediction failed. Throttling slows down
//      individual thread execution (each thread's 100ms of CPU work takes longer in wall
//      time when the cgroup quota is depleted), but it does NOT cause the serial backlog
//      that Little's Law assumed. Because requests are spread across ~20 concurrent threads
//      rather than queued single-file, throttling adds latency jitter to each request but
//      doesn't cause the multiplicative queuing explosion the serial model predicted.
//      Threading (reason 1 above) is the dominant explanation for the 10× gap.
//
// What actually happened (from k6 progress log + HPA describe events):
//   t=0:00-1:00  ramp 0→5 VUs; 3 pods handling ~34-42 RPS without saturation
//   t=1:01       5 VUs, 42 RPS, 3 pods — no significant queuing (116ms avg response)
//   t=1:39       HPA fires: 3→5 pods (based on CPU metrics crossing 70% threshold)
//   t=2:09-2:39  New pods ready — 5 pods now handling load
//   t=4:09       HPA fires: →6 pods (at 10 VUs / start of stage 3)
//   t=4:24       HPA fires: →8 pods = maxReplicas (ScalingLimited: TooManyReplicas)
//   t=4:00-6:00  ramp 10→20 VUs; 8 pods absorbing load, p95 stays well below 250ms
//   t=7:00       test ends; lastScaleTime 06:03:52 = HPA scale-down 5 min after end
//
// Threshold for p(95):
//   Real run result: p(95) = 178.82ms at peak 20 VUs / 8 pods.
//   Setting threshold at 400ms = 2.2× the observed p95.
//   Justification for this margin (not a tighter bound like 250ms):
//     - Image cold-start: if quote-api image is not cached on a new node, pod startup
//       takes 10-30s longer → more queuing during scale-out → p95 can spike temporarily
//     - CPU throttling is real (10-14% of periods throttled at peak load, verified above).
//       Under sustained high concurrency, throttling extends individual request wall time
//       beyond the 100ms CPU-burn floor. 400ms allows for ≈2× wall-time increase from
//       throttle pressure while still catching a genuine 3× regression.
//   Not set tighter (e.g. 200ms) because that would make the test fragile to scheduling
//   jitter on the first cold-start scale-out step.
//   Not left at 2000ms (original estimate) because p95=179ms at 2000ms bound means the
//   threshold cannot catch any realistic regression — equivalent to a scan set to
//   `allow_failure: true`. 400ms is an actual gate.
//
// Error rate threshold: rate<0.01 (1%)
//   Baseline: 0% errors. Real run: 0.10% (28 quick 502s from Traefik during pod
//   scale-in at ramp-down). 1% threshold gives 10× headroom — valid because the
//   underlying value (0.10%) is already stable and physically caused by transient
//   backend churn, not runaway errors. No change needed here.
// ---------------------------------------------------------------------------

export const options = {
  stages: [
    // Ramp up: even 3 VUs at ~42 RPS fires HPA (CPU > 70m/pod average).
    { duration: "1m", target: 5 },

    // Sustain: HPA scales 3→5→6 pods during this window. Hold long enough
    // for new pods to become Ready (readiness probe: 3s period, 3 failures).
    { duration: "3m", target: 10 },

    // Peak: 10→20 VUs. HPA is already at 8 pods (maxReplicas) by ~t=4:24,
    // so this stage exercises the saturated-at-max-replicas scenario.
    { duration: "2m", target: 20 },

    // Cool-down: let HPA observe low CPU before test ends.
    { duration: "1m", target: 0 },
  ],

  thresholds: {
    // < 1% HTTP errors — transient 502s during scale-out/in are expected;
    // sustained errors or >1% indicates a real problem.
    http_req_failed: ["rate<0.01"],

    // p95 < 400ms — 2.2× the observed 179ms, allows for cold-start variance
    // and mild CPU throttling increase. See capacity model comment above.
    "http_req_duration{expected_response:true}": ["p(95)<400"],
  },
};

const BASE_URL = "http://host.docker.internal:8080";

export default function () {
  const res = http.get(`${BASE_URL}/api/quote`, {
    tags: { name: "quote" },
  });

  check(res, {
    "status is 200": (r) => r.status === 200,
    "has quote field": (r) => {
      try {
        return JSON.parse(r.body).quote !== undefined;
      } catch {
        return false;
      }
    },
  });

  // No sleep: maximum throughput to keep HPA above threshold throughout ramp.
}
