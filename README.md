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
              telemetry store  (file:// volume, later s3:// on MinIO)
                     ▲
                     │ uploads .gfs + .log
            telemetry-forwarder ── scans ──▶ /var/gemfire/<member>/   ◀── locator, server-1..3 write here
                                                                         ▲
                                                               workload (Java client)
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
| 4 | Off-the-shelf clients | browse tools in MCP Inspector, ask Claude Code about the cluster | |
| 5 | Workload generator | watch `cache_ops_rate` / `put_latency` move | |
| 6 | Failure scenarios | kill/pause a server and ask the AI what happened | |
| 7 | S3 store (MinIO) | swap the store without touching the cluster | |
| 8 | Runner mode | point the MCP server at `~/dev/gemfire-runner` | |
| 9 | SRE assistant | your own MCP client + Claude, with a JSON-RPC trace | |
| 10 | Security (stretch) | OAuth + RBAC, a secured cluster, TLS | |

## Quickstart

```bash
make                       # list the targets
make start                 # cluster + telemetry forwarder + MCP server (about 30s from scratch)
make status                # containers + health
make tools                 # MCP tools/list via raw JSON-RPC
make call                  # pick a tool + its arguments from a menu (fzf), then call it
make call T=list_members   # or call one directly
make stop                  # stop (keeps ./data)      make clean  # stop + wipe ./data
```

For everything else, use `scripts/mcp-curl.sh` (see [docs/02](docs/02-mcp-server.md)) or `docker compose` directly.
