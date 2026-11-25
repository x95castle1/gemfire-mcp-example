# gemfire-mcp-example

A Docker Compose lab for learning the **Tanzu GemFire MCP Server 1.0**, built one small chunk at a time.

## The big picture

```
  curl / MCP Inspector / Claude Code / sre-assistant
                     │  MCP (JSON-RPC 2.0 over Streamable HTTP, POST /mcp)
                     ▼
            gemfire-mcp-server :8085 ──── live state ────▶ locator Management REST API (:7070)
                     │
                     │ history (stats + logs)
                     ▼
              telemetry store  (s3://gemfire-telemetry/gfmcp on SeaweedFS)
                     ▲
                     │ uploads .gfs + .log
            telemetry-forwarder ── scans ──▶ /var/gemfire/<member>/   ◀── locator, server-1..3 write here
                                                                         ▲
                                                     workload (Spring Boot GemFire client, :18090)
```

The MCP server is **read-only**: its 11 tools observe the cluster and never change it. It answers two kinds of questions:

- **"What is true right now?"** It calls the locator's Management REST API.
- **"What happened?"** It reads statistics archives and logs from the telemetry store, which the forwarder fills. The MCP server and the forwarder never talk to each other directly. The store sits between them.

Note: even "is it healthy *now*?" (heap, GC, CPU, bucket redundancy) is judged from the latest stats in the store, so the forwarder isn't optional.

## Chunks

| # | Chunk | You can now… | Notes |
|---|---|---|---|
| 0 | Prerequisites & skeleton | have the artifacts and know the version matrix | [docs/00](docs/00-prerequisites.md) |
| 1 | GemFire cluster | `curl localhost:17070/management/v1/ping` → `pong` | [docs/01](docs/01-cluster.md) |
| 2 | MCP server (live state) | call `list_members` with raw JSON-RPC via curl | [docs/02](docs/02-mcp-server.md) |
| 3 | Telemetry pipeline (file store) | query stats history, search logs, see real health | [docs/03](docs/03-telemetry.md) |
| 4 | Off-the-shelf clients | browse tools in MCP Inspector (`make inspector`), ask Claude Code about the cluster | [docs/04](docs/04-clients.md) |
| 5 | Workload generator | drive traffic with `make load` (steady, burst, hot-key, heap-hog…) and watch `cache_ops_rate` / `put_latency` / heap move | [docs/05](docs/05-workload.md) |
| 6 | Failure scenarios | break the cluster with `make chaos` (kill, stop, pause, isolate, locator-down, kill-majority), ask the AI what happened, `make heal` | [docs/06](docs/06-failures.md) |
| 7 | S3 store (SeaweedFS) | swap the store without touching the cluster; browse it with `make seaweed` | [docs/07](docs/07-s3-store.md) |
| 8 | Observability | `make grafana-ui`: Prometheus + Loki + Grafana for the whole lab: GemFire's built-in metrics, the workload, SeaweedFS, and the MCP server + forwarder from their logs (they have no metrics endpoint). Chaos runs show up as annotations | [docs/08](docs/08-observability.md) |
| 9 | SRE assistant | `make sre`: our own MCP client (Spring AI) on :18080. Pick Claude or Qwen (local Ollama) per question and watch every tool call and JSON-RPC message live | [docs/09](docs/09-sre-assistant.md) |
| 10 | Security (optional) | OAuth + RBAC, a secured cluster, TLS | |
| 11 | Load testing with k6 | k6 drives timed runs (ramps, spikes, soaks: p95/p99, pass/fail thresholds) through new HTTP endpoints on the workload, so GemFire still sees a real client; results in Grafana, with k6 start/end as ground truth for the AI. The switchable scenarios stay for always-on background load | |
| 12 | Runner mode (optional) | point the MCP server at `~/dev/gemfire-runner` | |

## Quickstart

```bash
make                       # list the targets
make start                 # cluster + S3 store + telemetry forwarder + MCP server (~45s from scratch)
make status                # containers + health
make tools                 # MCP tools/list via raw JSON-RPC
make call                  # pick a tool + its arguments from a menu (fzf), then call it
make call T=list_members   # or call one directly
make seaweed               # browse the telemetry bucket (SeaweedFS UI)
make inspector             # MCP Inspector web UI, already connected to the MCP server
make load                  # start the workload app + pick a traffic scenario (needs Artifactory creds in .env)
make chaos                 # break something on purpose (fzf menu); make heal puts it back
make grafana-ui            # Prometheus + Loki + Grafana, opens the lab dashboard (:13000, no login)
make sre                   # the SRE assistant, our own MCP client (needs ANTHROPIC_API_KEY in .env and/or Ollama)
claude                     # Claude Code in this folder picks up .mcp.json (approve 'gemfire' once)
make stop                  # stop (keeps ./data)      make clean  # stop + wipe ./data
```

For everything else, use `scripts/mcp-curl.sh` (see [docs/02](docs/02-mcp-server.md)) or `docker compose` directly.
