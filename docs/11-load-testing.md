# 11: Load testing with k6

```bash
make select-load-test              # pick a test (fzf; the preview explains it)
make select-load-test T=spike      # or name it: ramp, spike, soak, hot-key, breakpoint
make select-load-test T=soak DURATION=30m
make load P=stop D=2m              # (background scenarios can now be timed too)
cat data/load.log                  # when each test started and ended: ground truth
open data/loadtest/                # one HTML report per run
```

`make load` (chunk 5) is good at **always-on background traffic** that you switch while it runs, plus GemFire-specific tricks (heap-hog, release-heap). Its old `burst` and `hot-key` scenarios moved here: they're the k6 `spike` and `hot-key` tests now. What it lacked is what load-testing tools are built for: ramps, exact request rates, client-side percentiles, pass/fail, and a **recorded start and end**. This chunk adds **k6** for those, without throwing the workload away:

```
k6 (container) ──HTTP──▶ workload  /ops/get, /ops/put ──GemFire client protocol──▶ servers
                          (one real GemFire call per request, same client pool as the background)
```

This is the same shape as gemfire-runner (k6 → `/hello?key=` → GemFire). k6 can't speak GemFire's client protocol, so it drives an app that does. Calling GemFire's developer REST API (`/gemfire-api`) directly would test a different code path, and chunk 10 (security) may switch that API off.

## What a run does (`scripts/loadtest.sh`)

1. **Pauses the background traffic** (scenario `stop`), so k6's numbers are only k6's.
2. Writes `<UTC>  start <test>` to **`data/load.log`**.
3. Runs `k6 run /scripts/<test>.js` in the `k6` container:
   - requests go to the workload's `/ops/*`
   - metrics go to **Prometheus** (remote write; started with `--web.enable-remote-write-receiver`) if it's up
   - the live dashboard is on **http://localhost:5665** while it runs
   - an **HTML report** is saved to `data/loadtest/`
4. Writes `<UTC>  end <test> passed | failed (thresholds crossed) | interrupted`, then **puts the background scenario back**. Ctrl-C does this too.

## The tests (`k6/`)

| Test | Shape | Thresholds |
|---|---|---|
| `ramp` | 0 → 1000 req/s over 1 min, hold 2 min, down 30 s | failures < 1%, p95 < 50 ms |
| `spike` | 200/s for 1 min → **3000/s for 30 s** → 200/s for 1 min | same |
| `soak` | constant 300/s for `DURATION` (default 10 min) | same |
| `hot-key` | 500 puts/s on 5 keys for 2 min (one or two servers do all the work) | same |
| `breakpoint` | climbs from 500 to 20000 req/s over 10 min, **stops itself** when p95 > 200 ms or > 1% fail | `abortOnFail` |

All of them use **arrival-rate executors**: k6 starts requests at the rate you ask for, whatever the response time, adding virtual users (VUs) as needed. Watching VUs climb is how you see the system slowing down. Each script starts with a `// @title / @what / @expect / @watch` block, which is what the `make select-load-test` menu shows.

Every request is tagged `name=get|put`. Without that, k6 labels each request with its full URL, one per key, and sends thousands of time series to Prometheus.

## Three views of the same request

The dashboard's **"Load tests (k6)"** row puts three layers side by side (spike test, at the 3000/s plateau):

| Layer | Measures | Value |
|---|---|---|
| **k6** `k6_http_req_duration_p95` | HTTP + Tomcat + JSON + the GemFire call | p95 **0.85 ms** over the whole test (max 12 ms) |
| **workload client** `workload_op_seconds` (new, `source=k6`) | network + GemFire server | p95 ≈ **1 ms** at the peak |
| **GemFire server** `putTime / puts`, `getTime / gets` | inside the server only | avg put **0.21 ms**, avg get **0.003 ms** (served from memory) |

The request rate is counted three times too. They agree once you allow for how each is measured:
- **k6:** 3000/s at the plateau
- **client:** 3000 calls/s
- **servers:** gets + puts from each member's cache-wide stats, smoothed over 1 minute, so a 30-second spike shows lower

**Gotcha:** GemFire counts puts only in each member's cache-wide stats (`stat="cachePerfStats"`), not per region, while gets appear in both. Summing per-region series showed **0 puts/s** at 3000 req/s.

## Results on this laptop

| Test | Requests | Failures | p95 | Notes |
|---|---|---|---|---|
| `soak` (30 s smoke test) | 9,001 at 300/s | 0 | 1.08 ms | |
| `spike` | 129,999 | 0 | 0.85 ms | at most 50 VUs needed for 3000/s |
| `breakpoint` | **6,145,892** over 10 min (avg 10,243/s, up to ~18,900/s) | 0 | 1.2 ms | **didn't break.** p95 only rose 0.6 → 1.5 ms; p99 1 → 8.6 ms (the first strain). 4,101 *dropped iterations*: at the top **k6 itself**, on the same laptop, couldn't start requests fast enough |

A breakpoint run that reaches its target without crossing a threshold says "capacity is above this". Push it: `make select-load-test T=breakpoint TARGET=60000 DURATION=15m`. Two caveats:
- **k6's thresholds are judged over the whole run.** p95 over 10 minutes is dominated by the easy early part. The per-minute p95 and p99 in Grafana show the trend much better.
- **Dropped iterations mean the load generator is the bottleneck**, not GemFire. Past that point you're measuring your laptop's k6.

## Ground truth for the AI

After a timed burst (`make load P=burst D=20s`; `burst` has since moved out of `make load`: it's the k6 `spike` now), a `spike` and a `breakpoint` run, we asked the SRE assistant (chunk 9), with no hints: *"Were there traffic spikes or load tests against the GemFire cluster in the last 30 minutes? For each one, give the start and end time in UTC and roughly how high the operation rate went, and say how you can tell."*

| What happened (`data/load.log` + workload log) | Claude (Opus 5.5: 38 s, 11 tool calls, ~$0.50) | Qwen (qwen3:14b: 4 min 16 s, 4 tool calls) |
|---|---|---|
| timed `burst` 15:43:48 → 15:44:08 | ✅ 15:43:49 → 15:44:10, ~1,100 ops/s per server | ❌ missed |
| `spike` 15:48:57 → 15:51:39 (3000/s plateau ≈ 15:50:02 → 15:50:37) | ✅ 15:50:00 → 15:50:39: the plateau to the second (the 200/s lead-in and tail look like normal traffic) | ❌ missed |
| `breakpoint` 15:52:03 → 16:02:09, ramp to ~18,900/s | ✅ 15:52:07 → 16:02:06, "steady climb, then sudden stop… almost certainly a load test", ~20,000/s in total | ⚠️ only the peak, 16:02:01–04, reported as a short spike that "overwhelmed the cluster" (there were 0 failures) |
| background paused around each test | ✅ "a few seconds at 0 ops/s… looks like the regular workload being paused while the test client switched on or off" | |

Claude used `find_stat_threshold_crossings` on `cache_ops_rate` to find every period above twice the baseline, then read the shape (flat burst vs steady ramp). Qwen read each server's whole 30-minute series and reported its maximum. It also recovered from a bad first call (`member_name: "all"` returned the list of valid names, and it retried per server).

`load.log` exists for exactly this check: a ground truth that isn't GemFire's own data.

## Timed background scenarios (`make load P=… D=…`)

`POST /scenario/stop?duration=2m` (what `make load P=stop D=2m` sends) switches, then goes back to the previous scenario by itself. `/status` shows `revertsAt` / `revertsTo`, and the workload logs both switches (`Scenario: steady -> burst`, `Scenario: burst -> steady`). Grafana shows those log lines as purple **annotations**; k6 runs are the blue ones.

## Things we hit

1. **The restore didn't run** the first time. The `EXIT` trap fires after the function has returned, so it couldn't see the function's local variable holding the previous scenario. That variable is global now.
2. **Ctrl-C left k6 running.** Interrupting the `docker compose run` CLI doesn't always stop the container, so the cleanup now stops any k6 container left over. Ctrl-C exits with code 130, which is now reported as `interrupted`.
3. **k6's live dashboard** needs `K6_WEB_DASHBOARD_HOST=0.0.0.0`. By default it listens only inside the container, so the published port 5665 wouldn't reach it.
4. **Virtual threads** (`spring.threads.virtual.enabled`) in the workload, so hundreds of concurrent k6 requests each get a cheap thread instead of waiting for Tomcat's pool of 200.
5. **Docker's virtual disk filled up (58 GB, 100%).** The workload then crashed on start with `Unable to create tempDir … No space left on device`. The lab itself wasn't the cause: it was months of build cache and untagged images from every project on this machine. `docker system df` shows it. Docker builds and `docker compose up --build` leave old images behind, and k6's 6-million-request breakpoint run doesn't help (GemFire's persistent Orders region and the telemetry store live in `./data`, on your Mac's disk, but containers write temp files inside Docker's disk). We freed ~12 GB with `docker builder prune --filter until=24h` (keeps today's cache, so this lab's Gradle downloads stay: no Artifactory login needed) and `docker image prune` (untagged images only). Volumes and tagged images were left alone.
