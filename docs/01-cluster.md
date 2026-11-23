# 01: The GemFire cluster

```bash
docker compose up -d                                   # locator + server-1..3 + gemfire-init
curl localhost:17070/management/v1/ping                # -> pong
curl -s localhost:17070/management/v1/members | jq     # what list_members (chunk 2) is built on
find data/gemfire -name '*.log' -o -name '*.gfs'        # the files the forwarder (chunk 4) will ship
```

## What's running

| Service | Role | Why it's shaped this way |
|---|---|---|
| `locator` | membership + cluster config + **Management REST API** on :7070 (host :17070) | The MCP server's only live data source. Needs `--http-service-port` and `-Dgemfire.enable-management-rest-service=true` |
| `server-1..3` | data, 768m heap each | 3 servers, so we can kill one and still have a cluster; small heaps make heap pressure easy to cause |
| `gemfire-init` | one-shot `gfsh run --file=gemfire/init-cluster.gfsh` | Regions go into **cluster configuration**, so a restarted server gets them back |

Regions and the MCP signal each one is meant to produce later:

| Region | Type | Kill one server and… |
|---|---|---|
| `Customers` | PARTITION_REDUNDANT | `DEGRADED` (one copy left, no data loss) |
| `Orders` | PARTITION_REDUNDANT_PERSISTENT | `DEGRADED`, and it survives a full restart |
| `Sessions` | PARTITION (no redundancy) | `NO_COPIES`: buckets are gone |
| `Products` | REPLICATE | nothing; every server has everything |

## Where telemetry comes from

`gemfire/gemfire.properties` is shared by every member, and every setting in it exists for the MCP server:

- `statistic-sampling-enabled` + `statistic-sample-rate=1000` → `<member>.gfs`, one sample per second
- `enable-time-statistics=true` → needed for the `put_latency` signal
- `archive-file-size-limit` / `log-file-size-limit` → **rolling** files. The forwarder re-uploads a *live* file every time it changes but uploads a *rolled* file only once, so small rolling files keep the uploads cheap.

Each member writes into `./data/gemfire/<member>/`:

```
server-1.log   server-1.gfs        <- what the forwarder ships
meta-server-1-01.log  *.marker  vf.gf.server.pid  <- GemFire bookkeeping
```

## Gotchas we hit

1. **The image runs the member in the current directory.** Its entrypoint does `gfsh start … --dry-run` and then `exec`s the java command it prints, so gfsh's `--dir` doesn't move anything. Compose's `working_dir` decides where the files land.
2. **"Multiple garbage collectors selected".** gfsh adds ZGC by default, so `-XX:+UseG1GC` on its own conflicts. Use `--J=-XX:-UseZGC --J=-XX:+UseG1GC`.
3. **YAML `>` blocks have no comments.** A `# note` inside `command: >` is passed to gfsh as arguments (`Option '' is not available`).
4. **The image has no curl.** Health checks use bash's `/dev/tcp`.
