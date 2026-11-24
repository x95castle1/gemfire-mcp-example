# 08: Observability (Prometheus + Loki + Grafana)

```bash
make grafana        # starts Prometheus, Loki, Alloy, Grafana and opens the "GemFire MCP Lab" dashboard
                    # Grafana     http://localhost:13000   admin / admin
                    # Prometheus  http://localhost:19090   (Status → Target health: every scrape target)
                    # Alloy       http://localhost:12345   (the log pipeline, drawn as a graph)
make load P=burst   # give it something to show
make chaos          # red markers appear on every panel at each kill / pause / heal
```

Until now we looked at the cluster only **through the MCP server**. This chunk adds the classic operator view next to it: metrics and logs from every piece of the lab in one dashboard. It answers two questions:
- What does an ordinary monitoring stack show for the same incidents the AI diagnosed in chunk 6?
- How do you watch the AI-facing pieces themselves?

```
             metrics (pull, every 15s)                          logs (push)
GemFire members :7070/metrics/ ─┐                 ┌─ container stdout (Docker socket): mcp-server, forwarder, ...
SeaweedFS       :9327/metrics ──┼─▶ Prometheus    │  GemFire log files ./data/gemfire/*/*.log
workload  /actuator/prometheus ─┘        │        │  ./data/chaos.log
                                         │        └──────────▶ Alloy ──▶ Loki
                                         └──────▶ Grafana ◀──────────────────┘
```

## Who exposes what

| Component | Metrics endpoint? | How it gets into Grafana |
|---|---|---|
| **GemFire 10.3.4** | yes, built in, but **off by default** | Prometheus scrapes `:7070/metrics/` on every member |
| **SeaweedFS** | yes (`-metricsPort=9327`) | Prometheus |
| **Workload** | yes (`/actuator/prometheus`), plus our own `workload_*` counters | Prometheus |
| **GemFire MCP Server 1.0.0** | **no** (no Actuator, no Prometheus registry) | Loki parses its **`gf-mcp.audit`** log: one JSON line per HTTP request |
| **Telemetry forwarder 1.0.0** | **no** | Loki parses its **`plane=stats`** log line, once a minute |

The two components built for AI use are the hardest to watch. Turning their logs into numbers is the main LogQL lesson of this chunk.

## Turning GemFire's metrics on (it took 3 settings and a code dive)

In `compose.yaml` (see the notes block at the top):

| Setting | Why |
|---|---|
| `--J=-Dgemfire.prometheus.metrics.emission=Default` | the endpoint is `None` (off) by default. `Default` is a curated set (puts, gets, `lowRedundancyBucketCount`, `heapCriticalEvents`, `jvm.*`, …); `All` is everything |
| `--J=-Dgemfire.prometheus.metrics.interval=15s` | the default for `Default` is **1 minute**, too coarse for a dashboard |
| servers: `--http-service-port=7070` | servers don't run an HTTP service unless asked to, and `/metrics` is served by it |
| servers: `--start-rest-api=true` | the surprise. A **server** starts `/metrics` only if its **developer REST API** is enabled too. All the server logged was `Metrics endpoint will not be started`, so we found the rule by disassembling `GemFireCacheImpl.startMetricsApi`. Side effect: `/gemfire-api` (region read/write over REST) is now on, which is fine in a lab |
| `--http-service-bind-address=<member>` | see the next section |

Two smaller details:
- `/metrics` redirects (301) to `/metrics/`, so the scrape path needs the trailing slash.
- GemFire labels metrics `member="server-2(server-2:1)<v2>:58389"`. The `<v2>:58389` part (membership view id + port) changes on every restart, which would start a new time series each time. `observability/prometheus/prometheus.yml` rewrites it to `server-2`, and renames GemFire's own `instance` label (region / stats instance) to `stat`.

## Bonus: half of every server's log was noise

While planning this chunk we counted: **1,138 of 2,401 lines (47%)** in server-2's log were
```
[info ... server-2 <P2P message reader for locator(...)> tid=0x96] No host/bind address specified: Using localhost server-2
```
They came twice every 5 seconds, from GemFire's metrics `PublishingService` working out its URL whenever the locator asked the server about itself. Our healthcheck asks exactly that every 5 s (`GET /management/v1/members/<server>`). Setting `--http-service-bind-address` took it from **24 lines/minute per server to 0**. These are the same logs the MCP server's `search_logs` searches, with a 500-event cap per call.

The bind address had a knock-on effect: the HTTP service no longer listens on loopback, so the **locator's healthcheck had to change from `127.0.0.1:7070` to `locator:7070`**.

## Logs as metrics (LogQL)

Alloy (`observability/alloy/config.alloy`) ships three things to Loki:

| Source | Labels | Notes |
|---|---|---|
| container stdout of project `gfmcp` (Docker socket) | `job="containers"`, `service="mcp-server"`, … | the MCP audit log and forwarder stats live here |
| `./data/gemfire/*/*.log` | `job="gemfire"`, `member`, `level` | multi-line events (stack traces) are joined; GemFire's own timestamp is used; rolled `*-NN-NN.log` files are skipped (they're the live log renamed, so they'd be read twice) |
| `./data/chaos.log` | `job="chaos"`, `action` | drives the red **annotations** on every panel |

The MCP server panels. The audit JSON sits at the end of a Spring Boot log line, so cut it out first:
```logql
{service="mcp-server"} |= "gf-mcp.audit"
  | regexp `(?P<audit>\{.*\})\s*$` | line_format `{{.audit}}`
  | json method, durationMs | unwrap durationMs          # → quantile_over_time(0.95, ... [5m]) by (method)
```
The forwarder panels:
```logql
{service="telemetry-forwarder"} |= "plane=stats" | logfmt bytesShipped | unwrap bytesShipped   # → rate_counter(... [5m])
```
**Gotcha:** a plain `| logfmt` turns *every* field into a label. `liveShipped` changes on every line, so each line became its own series and `rate_counter` returned 0. `| logfmt bytesShipped` extracts only the field you unwrap.

## What the dashboard shows during chaos and load

Verified with `make chaos C=kill M=server-2`, then `make heal`:

| Panel | During the kill | After heal |
|---|---|---|
| Members | server-2 **DOWN** within one scrape | UP |
| Low-redundancy buckets | **Customers 75, Orders 75** | 0 |
| Workload operations/s | a small dip (~200 → ~180), no errors | ~200 |
| Chaos annotation | red marker "kill" | red marker "heal" |
| GemFire logs, "Warnings and worse" | the 4 `Redundancy has dropped below…` warnings | `…has been restored` (INFO) |

And with `make load P=heap-hog`: **tenured heap went from ~30% to over 90% on all three servers within 60 seconds** and stayed in the red band, each server logged one critical-heap event, and the workload's errors panel showed `rejected_low_memory` at 40/s, which is every put being refused. `make load P=release-heap` brings it back down once the garbage collector runs.

### Compared with the MCP view (chunk 6)

| Question | Grafana | MCP + Claude |
|---|---|---|
| *Is something wrong right now?* | instant: red stat, a line crossing a threshold | `assess_cluster_health`, one call |
| *What happened, in what order, and why?* | you read the panels and the logs yourself | Claude built the timeline from tools, and told a crash from a stop from a pause |
| *Is the MCP server itself healthy / slow?* | yes: requests, p95 latency, warnings (circuit breaker) | no: the MCP server can't see itself |
| Works when the locator is down? | GemFire metrics: yes for the servers (scraped directly) | live tools fail; history tools work |

They complement each other. Dashboards are good at *noticing*; the AI over MCP is good at *explaining*.

## Gotchas

1. **Changing a GemFire member's settings, then `make start`, can take the whole cluster down.** Compose recreates all three servers at once, which the locator sees as losing the majority. That's the chunk 6 kill-majority scenario, deadlock included. `make heal` recovers (it restarts the stuck locator). Gentler: recreate one server at a time (`docker compose up -d --wait server-1`, then 2, then 3).
2. **Loki's image is distroless** (no shell, no wget/curl), so it can't have a Docker healthcheck. Check it from your laptop: `curl localhost:13100/ready`.
3. **Prometheus and Loki run as root** in this lab so they can write to the bind-mounted `./data/prometheus` and `./data/loki`, which keeps `make clean` wiping everything in one go.
4. **Failed MCP logins don't show up.** The MCP server audits rejected logins through its failed-login throttle, and we switched that off in chunk 2 (`GF_MCP_AUTH_FAILURE_LIMIT_ENABLED=false`). A wrong password got a 401 and left no audit line.
5. **The audit log has no tool name.** Every MCP call is `POST /mcp`, so you can see traffic and latency, but not *which* tool the AI called. In chunk 9 our own client can log that.
6. **The forwarder only logs its stats once a minute**, so its panels use 2–5 minute windows and react slowly.

Items 4, 5 and the metrics/bind-address findings are also in [issues-for-broadcom.md](issues-for-broadcom.md) (#7–#9).

## Files

```
observability/
├── prometheus/prometheus.yml           scrape targets, label clean-up
├── loki/loki.yml                       single-process Loki, data in ./data/loki
├── alloy/config.alloy                  container logs + GemFire log files + chaos.log → Loki
└── grafana/
    ├── provisioning/datasources/       Prometheus + Loki, fixed uids
    ├── provisioning/dashboards/        "load every JSON in dashboards/"
    └── dashboards/gfmcp-lab.json       the dashboard (edit in the UI, then export to keep changes)
```
