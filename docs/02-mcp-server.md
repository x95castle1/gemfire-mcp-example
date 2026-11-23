# 02: The MCP server, and speaking MCP by hand

```bash
docker compose --profile mcp up -d --build      # builds gfmcp/gemfire-mcp-server:1.0.0 from vendor/*.jar
docker compose logs mcp-server                  # startup summary: tools, resources, store, listen address

scripts/mcp-curl.sh tools                       # tools/list
scripts/mcp-curl.sh tool query_stat             # one tool's full definition (what the LLM sees)
scripts/mcp-curl.sh call list_members           # tools/call
scripts/mcp-curl.sh call list_regions '{"sort_by":"name"}'
scripts/mcp-curl.sh resources                   # resources/list
scripts/mcp-curl.sh read gemfire://stat-signals # resources/read
VERBOSE=1 scripts/mcp-curl.sh init              # see the raw HTTP headers
```

## How the container is wired

| Setting | Value | Why |
|---|---|---|
| `SERVER_ADDRESS` | `0.0.0.0` | Default `127.0.0.1` is unreachable from outside a container |
| `GF_MCP_GEMFIRE_URL` | `http://locator:7070` | Live state. The server appends `/management/v1` itself |
| `GF_TELEMETRY_STORE` | `file:///telemetry-store` | History. **Required**; startup fails if the store is unreachable and only warns if it is empty |
| `GF_MCP_AUTH_BASIC_*` | from `.env` | Front-door auth for MCP clients. Both values are required |
| `GF_MCP_AUTH_FAILURE_LIMIT_ENABLED` | `false` | Lab only; otherwise 50 bad logins throttle your IP |
| store mount | `:ro` | The MCP server never writes the store; only the forwarder does |

The JAR's built-in config is a great read: `unzip -p vendor/gemfire-mcp-server-1.0.0.jar BOOT-INF/classes/application.yml`.

## The protocol, one session at a time

MCP is **JSON-RPC 2.0**. The transport here is **Streamable HTTP**: every message is a `POST /mcp`.

```
client                                              server
  │ POST {"id":1,"method":"initialize",...}           │
  │──────────────────────────────────────────────────▶│
  │ 200 {"result":{protocolVersion,capabilities,      │
  │      serverInfo}}  + header Mcp-Session-Id: <uuid>│
  │◀──────────────────────────────────────────────────│
  │ POST {"method":"notifications/initialized"}       │  ← notification: no id, so no reply
  │──────────────────────────────────────────────────▶│
  │ 202 Accepted                                      │
  │◀──────────────────────────────────────────────────│
  │ POST {"id":2,"method":"tools/call",               │  ← every later request carries
  │       "params":{"name":"list_members",...}}       │    Mcp-Session-Id + MCP-Protocol-Version
  │──────────────────────────────────────────────────▶│
  │ 200 {"id":2,"result":{"content":[{"type":"text",  │
  │      "text":"{...json...}"}],"isError":false}}    │
  │◀──────────────────────────────────────────────────│
  │ DELETE /mcp  (end the session)                    │
```

Things to notice:
- **Requests have an `id`, and the reply echoes it.** Notifications have no `id` and get no reply. IDs must be unique within a session; my first version of the script reused `1` by mistake.
- **`Accept: application/json, text/event-stream`.** The server may answer with plain JSON or an SSE stream (`data: {...}` lines). Clients must handle both.
- **Capabilities are negotiated.** This server advertises `tools`, `resources`, `prompts`, `logging` and `completions`, but only tools and resources have anything in them.
- **A tool result is content blocks.** Here the single `text` block holds JSON. `isError: true` means "the tool ran and failed", which is different from a JSON-RPC `error` ("the call itself was bad").

## What the LLM actually sees

`scripts/mcp-curl.sh tool query_stat` shows a tool definition:
- `description`: prose written *for the model*. It says when to use the tool and when not to.
- `inputSchema`: JSON Schema. `signal` is an **enum** of 29 named statistics, so the model can't make one up.
- `annotations`: `readOnlyHint: true`, `destructiveHint: false`. Every tool here is read-only.

Resources (`gemfire://stat-signals`, `gemfire://log-signals`) are reference documents a client can pull in. They aren't actions. `stat-signals` maps each friendly signal name to the raw GemFire stat it reads, e.g. `heap_used` → `VMMemoryUsageStats.usedMemory`.

## Live vs. history: what works with an empty store

| Tool | Works now? | Why |
|---|---|---|
| `list_members` | ✅ | REST. Each member has a note: "no statistics in the store yet" |
| `list_regions` | ✅ | REST (type is the data policy, so `PARTITION_REDUNDANT` shows as `PARTITION`) |
| `assess_cluster_health` | ⚠️ mostly `UNKNOWN` | Heap, GC, CPU and pause checks use the **latest stats in the store**, not REST |
| `get_partition_region_health` | ⚠️ `UNKNOWN` | Bucket redundancy comes from the region stats in the archives |
| `query_stat`, `search_logs`, `get_membership_timeline`, … | ❌ empty | Store only |

**Takeaway:** the telemetry store isn't optional history on top of the live data. Most "is it healthy right now?" answers come from it too. Chunk 4 (the forwarder) is what makes this server useful.
