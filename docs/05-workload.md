# 05: The workload generator

```bash
make load                 # starts the app if needed, then pick a scenario from a menu
make load P=heap-hog      # or name it
curl -s localhost:18090/status | jq      # what it's doing right now
make logs S=workload
```

An idle cluster gives the MCP server nothing to find. `workload/` is a small **Spring Boot 4.1 GemFire client** that generates traffic you can switch between scenarios while it runs, so stats, logs and health have a story in them.

## The scenarios

| Scenario | What it does | What to look for over MCP |
|---|---|---|
| `steady` (default) | ~200 ops/s, 70% gets / 30% puts, 1 KB values over 10k keys in Customers + Orders | `query_stat` with `cache_ops_rate`, `put_rate`, `get_rate`, `put_latency`; `list_regions` entry counts growing |
| `burst` | ~3000 ops/s, same mix | `find_stat_threshold_crossings` on `put_rate` finds the spike |
| `hot-key` | 500 ops/s on just 5 keys in Customers | `put_rate` lopsided across servers: the hot keys' buckets have one primary each |
| `heap-hog` | new 512 KB values into **Sessions** (no redundancy) until servers reach **critical heap** (90% of 768 MB) and start **rejecting puts** | `assess_cluster_health` heap checks go WARNING/CRITICAL; `search_logs` with `signal: heap_pressure`; the `heap_critical_events` signal |
| `release-heap` | removes everything from Sessions, then back to `steady` | heap recovers; `heap_safe_events` |
| `stop` | no traffic | flat lines |

The app keeps running when servers reject puts. `/status` counts them under `rejectedAtCriticalHeap`, and the app logs a warning every 50 rejections.

## How it's built

```
workload/
├── build.gradle               Spring Boot 4.1 + spring-boot-4.1-gemfire-10.3 + gemfire-core/cq 10.3.4
├── Dockerfile                 Gradle build stage → JRE runtime stage
└── src/main/java/.../workload
    ├── WorkloadApplication    @SpringBootApplication; a ClientCache is auto-configured
    ├── Regions                PROXY client regions, plain GemFire API
    ├── LoadGenerator          scenarios, the 100 ms ticker, counters
    └── ControlController      GET /status, GET /scenarios, POST /scenario/{name}
```

- **Connecting:** `spring.data.gemfire.pool.locators: locator[10334]` in `application.yml`. The client asks the locator, which hands it the servers.
- **`PROXY` regions:** the client keeps no local copy, so every operation hits the servers and shows up in the servers' statistics, which is what the MCP server reads.
- **No client statistics archive, on purpose.** A client `.gfs` in `./data/gemfire` would be shipped by the forwarder like a member's, and `assess_cluster_health`'s `members_present` check would flag "a member recorded stats but isn't in the cluster now".
- **Artifactory credentials** come from `.env` as **BuildKit secrets** (`secrets:` in `compose.yaml`, `RUN --mount=type=secret` in the Dockerfile): available to the Gradle step, never stored in an image layer.
- **Port 18090** on your laptop, because gemfire-runner's `goodbye-world` already uses 8090.
- `/actuator/prometheus` is exposed for chunk 10 (observability).

## Bugs and noise we hit

1. **Burst stuck at exactly 640 ops/s**, with idle CPUs and thousands of "dropped" operations. Each 100 ms tick started its 300 operations in a tight loop, and the first 64 took every in-flight permit *before any had run*, so the ceiling was 64 × 10 = 640/s. Raising the cap to 1000 gave about 3000 ops/s with 0 dropped. A neat lesson: a **perfectly flat** number with idle CPUs points to an artificial limit, not a slow system.
2. **`/actuator/health` was DOWN.** The GemFire actuator's continuous-query health check needs the CQ module: `CqService is not available`. Adding `gemfire-cq` fixed it, as gemfire-runner's apps do.
3. **Claude found a bug in *our* setup.** Asked about heap, it also reported "repeating client-connection `EOFException` warnings every 5 seconds… most likely health-check probes". It was right. The server healthcheck opened the cache-server port (`</dev/tcp/127.0.0.1/40404`) and hung up without speaking GemFire's protocol, so each server logged `failed accepting client connection java.io.EOFException` every 5 s: **1,036 lines** of noise in the very logs the MCP server searches. The healthcheck now asks the locator's REST API whether the member is `online` (`GET /management/v1/members/<hostname>`).
4. **`ERROR … DEPRECATED: PoolFactory.setMinConnections / setMaxConnections`** three times at startup. Spring for GemFire calls pool methods that GemFire 10.3 deprecates, and GemFire reports that at ERROR level with a stack trace. Harmless, and not our code; we leave it visible rather than silence a GemFire logger.

## What Claude made of a heap-hog run

Asked "has anything unusual happened to heap in the last 15 minutes?" (no hints), Claude made 9 tool calls: `tenured_heap` per server, `search_logs` with `signal: heap_pressure`, `put_rate`, Sessions `region_entries`, then a second log search *excluding* the threshold messages to rule out other causes. It rebuilt the timeline (eviction → critical crossings, server-1 first, peak about 790 MB, Sessions emptied by 21:23) and concluded "a few big values filled the heap, not a high write rate". Correct. Its guess of "about 1.5 MB per entry" was wrong (they were 512 KB), because it divided heap used by entry count. **Tools return facts; conclusions drawn from them can still be off.**

Also realistic: after `release-heap`, servers kept rejecting puts for a few minutes. Removing entries only creates garbage; the heap drops below critical once the garbage collector runs.

## Ask the AI

With the workload running, try in Claude Code (`claude` in this folder):
- "What's the put rate on each server over the last 10 minutes? Is the load balanced?"
- "Was there a traffic spike recently? When did it start and end?"
- "Has anything unusual happened to heap in the last 15 minutes?" (after a `heap-hog`)
