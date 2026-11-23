# 03: The telemetry forwarder and the store

> **Update (chunk 7):** the store is now an S3 bucket, `s3://gemfire-telemetry/gfmcp` on SeaweedFS. Everything below still applies, and the layout is identical, but as object keys. Browse it with `make seaweed` instead of `find data/telemetry-store`. See [docs/07](07-s3-store.md).

```bash
make start                                   # now also starts telemetry-forwarder
make logs S=telemetry-forwarder              # watch it ship: "Shipped LIVE / ROLLED / LOG chunk"
find data/telemetry-store | head -40         # the store is just files (file://); later S3 objects
make call T=assess_cluster_health A='{"response_format":"detailed"}'
```

## Why put stats and logs in a store at all?

The MCP server could in theory read files off each member's disk. It deliberately doesn't:

1. **The MCP server lives outside the cluster.** It needs no SSH, no shared filesystem and no agent inside GemFire. The forwarder runs *next to* the members and **pushes**; the MCP server only **reads**, from one place.
2. **Post-mortems need the files of dead members.** When a server crashes and its container, pod or disk is gone, its last stats and logs are exactly the evidence you want. Once those files are in the store, they outlive the member.
3. **GemFire deletes its own history.** `log-disk-space-limit` and `archive-disk-space-limit` remove old rolled files. The forwarder never deletes; retention is the store's job, e.g. an S3 lifecycle rule.
4. **One place, every member, one timeline.** "Who saw server-3 leave?" is one read across all members, not N hosts.
5. **Least privilege and decoupling.** The forwarder can only *write*, and the MCP server mounts the store `:ro`. They never talk to each other; the only contract is the same `GF_TELEMETRY_STORE` URL. Swapping `file://` for `s3://` (chunk 7) changes nothing else.
6. **Logs in particular:** the only other log source is Splunk (`GF_MCP_LOGS_LOG_PLATFORM_*`). Without a log platform, the store *is* your log platform.

## What the forwarder ships (and what it skips)

It identifies members by **file content**, not file names:

| File | Rule | What happened here |
|---|---|---|
| `server-1.gfs` (live) | re-shipped whenever it changes (every 10s here) | `Shipped LIVE server-1/server-1.gfs -> server-1/stats/live/server-1.gfs.gz` |
| `server-1-01-02.gfs` (rolled) | shipped **once**, keyed by the archive's start time | left over from earlier restarts |
| `server-1.log` (live) | shipped from byte 0, then followed as **byte-range chunks** | `[0, 206240)`, then `[206240, 207868)`, … |
| `server-1-NN-NN.log` (rolled) | **not** shipped; only the live log is followed | |
| `meta-*.log` | skipped by a name rule | GemFire bookkeeping |
| `pulse.log` | skipped: "no Startup Configuration block with name=" | a log, but not a *member* log |

It also creates `/var/gemfire/.forwarder.lock`: **exactly one forwarder per scan folder**. Two forwarders would ship conflicting state for the same member.

## The store layout

```
data/telemetry-store/
└── server-1/
    ├── stats/
    │   ├── live/server-1.gfs.gz                                   ← overwritten each cycle
    │   └── 2026/11/23/20261123T193739.694Z_server-1-01-02.gfs.gz  ← rolled, keyed by start time
    └── logs/
        ├── _gen/20261123T195823.793Z.properties                   ← one "generation" per live log file
        └── 2026/11/23/19/<gen>-<fromByte>-<toByte>.log.gz         ← log chunks, bucketed by hour
```

Everything is gzipped and keyed by **member + time**, so "server-2's logs 19:00–20:00" means opening a few objects, not scanning everything. A log chunk is just gzipped GemFire log text: `gzip -dc <chunk>.log.gz | head`.

## Before vs after

| Tool | Chunk 2 (empty store) | Now |
|---|---|---|
| `list_members` | note: "no statistics in the store yet" | `stored`: archive count, first archive, last copied, log hours |
| `assess_cluster_health` | 6 × `UNKNOWN` | `HEALTHY`: 9 checks (heap, GC, pauses, CPU, redundancy, membership…) |
| `get_partition_region_health` | `UNKNOWN` | `OK`, 0 low-redundancy buckets |
| `query_stat` server-1 `heap_used` | `isError`: no archives | min/max/mean/p99 over 1250 one-second samples, with gaps labelled `"cause": "restart"` |
| `search_logs` | empty | events from all 4 members, merged on one timeline |
| `get_membership_timeline` | empty | `server-3 GRACEFUL_EXIT` → `REJOINED` 17s later, flagged as a **flap** |

The membership timeline is the best demo of *why logs*: `server-3`'s departure is reconstructed from the **other** members' logs (`"sources": ["locator","server-1","server-2"]`). That evidence is still there even if `server-3` never comes back.

## Gotchas

- **`search_logs` needs a time window**: `start` + `end`, or `around` + `radius` (e.g. `"radius":"30m"`). Without one you get `isError` with a message written for the model to read and fix its call. This is a good example of tool errors as instructions.
- **Health is only as fresh as the last forwarder cycle** (10s). `list_members` → `stored.statsLastCopiedToStore` tells you how fresh.
- **Small rolling archives matter.** The live archive is re-copied every cycle. With gemfire-runner's 177 MB never-rolling archive, each cycle would copy 177 MB (the forwarder even warns about it). `archive-file-size-limit=10` in `gemfire/gemfire.properties` keeps it cheap.
