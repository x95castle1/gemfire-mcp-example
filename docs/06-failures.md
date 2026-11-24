# 06: Failure scenarios

```bash
make load P=steady                 # traffic first: failures are more interesting under load
make chaos                         # pick a failure (fzf), then a server
make chaos C=kill M=server-2       # or name them
make heal                          # undo everything, wait until every server is back
cat data/chaos.log                 # what you did and when (UTC): the ground truth
```

Chunk 5 made the cluster busy; this chunk breaks it on purpose. Each failure prints the exact docker command it runs, records a timestamp in `data/chaos.log`, and suggests the `make call` lines (already filled in with the right time window) that should reveal it. The question every time: **can the MCP tools, and an AI using them, tell what broke, when, and how?**

## The failures, and what actually happened

All numbers below are from real runs in this lab (GemFire 10.3.4, defaults: `member-timeout=5000`, `enable-network-partition-detection=true`, `max-wait-time-reconnect=60000`, `max-num-reconnect-tries=3`).

| `C=` | What we do | What GemFire did | Best MCP evidence |
|---|---|---|---|
| `kill` | `docker compose kill server-2` (SIGKILL: a crash) | Others suspected it at once, removed it **~5.5s** later: "unexpectedly left the distributed cache". Customers + Orders: "Redundancy has dropped below 2 configured copies to 1 actual copies", and it stays dropped until the member returns | `assess_cluster_health`: `members_present` CRITICAL ("recorded stats in the last 15 minutes but the cluster does not report it now"), `partitioned_region_redundancy` WARNING (75 low-redundancy buckets each); `search_logs` signals `membership`, `redundancy` |
| `stop` | `docker compose stop server-3` (SIGTERM: clean shutdown) | Noticed in **0.3s**: "gracefully left the distributed cache: shutdown message received". The stopped server's own log shows its orderly shutdown | Same tools. `gracefully` vs `unexpectedly` is how you tell a stop from a crash |
| `pause` | `docker compose pause server-1` (frozen JVM, like a huge GC pause) | 8s: "isn't responding to heartbeat requests"; 13s: removed ("unexpectedly left"). The frozen server logs **nothing**. On unpause it wrote its side: "JVM pause with a wakeup delay of 32117 ms", "task overslept", then `ForcedDisconnectException: The coordinator removed this member`. It **reconnected by itself 60s later** ("Reconnect completed") | `search_logs` signals `jvm_pause`, `forced_disconnect`; `membership_events` check: "1 forced disconnect(s)" |
| `isolate` | `docker network disconnect gfmcp …server-3` (awake but cut off) | Both sides suspect each other. The isolated server did the maths itself: "total weight lost in this view change is 28 of 38. **Quorum has been lost!**", a FATAL "Possible loss of quorum", then `ForcedDisconnectException: Exiting due to possible network partition`. Reconnected ~40s after the network came back | `search_logs` signal `partition`, all from the isolated member's own log |
| `locator-down` | `docker compose kill locator` | Servers and traffic **carried on** (200 ops/s, 0 errors): clients already knew the servers | **Live** `list_members` → `isError`; **history** `query_stat` / `search_logs` fine; `assess_cluster_health`: **8 of 9 checks UNKNOWN** (even heap/CPU need the member list), only the log-based `membership_events` still works |
| `kill-majority` | `docker compose kill server-1 server-2` | The locator (coordinator): "total weight lost … 25 of 38. Quorum has been lost!", declared a network partition, forced **server-3 and itself** out. **The whole cluster shut itself down.** Workload: 0 ops/s, `MemberDisconnectedException` | `search_logs` signal `partition`; health all UNKNOWN except `membership_events` CRITICAL ("2 quorum loss(es)…") |

### Why kill-majority takes the whole cluster down

GemFire weighs members: **server 10, locator 3, +5 for the "lead" member**. Here: 3 + 3×10 + 5 = **38**. When one membership change loses **half or more** of the weight, the survivors can't know if the others crashed or are alive on the other side of a network split. If both halves kept going you'd get two clusters writing different data ("split brain"), so the side that lost shuts itself down. Two servers including the lead = 25 of 38 lost → shut down.

`isolate` is the same logic from the other side: the cut-off server saw 28 of 38 disappear and removed *itself*, which is exactly right.

### What was lost (after kill-majority)

| Region | Type | After the full outage |
|---|---|---|
| Orders | `PARTITION_REDUNDANT_PERSISTENT` | **all 10,000 entries recovered from disk** (despite "All in memory copies of some data have been lost for /Orders") |
| Customers | `PARTITION_REDUNDANT` | **gone**; only what the workload wrote afterwards |
| Products | `REPLICATE` | **gone** (0 entries; the workload seeds it only at startup) |

Redundancy protects against losing *a* server. Persistence protects against losing *all* of them.

## `make heal`, and the surprises that shaped it

`heal` unpauses, reconnects (`docker network connect --alias server-3 gfmcp …`, the alias so others still find it by name), starts anything stopped, then **asks the locator** until every server is back. Four things we learned the hard way:

1. **Docker's health status lags.** A paused container keeps its old "healthy"; a long-isolated one turns "unhealthy". So `heal` doesn't trust `docker compose up --wait`; it polls `GET /management/v1/members/<server>` itself.
2. **After an auto-reconnect, GemFire reports `"status":"starting"` forever.** The member is fully back (regions, clients, redundancy), but the Management API never updates the status, and `list_members` passes that on faithfully (`server-1 = starting`). It even survived a locator restart. Our server healthcheck used to wait for `"online"`, so the reconnected container stayed "unhealthy". It now checks the member's cache server is `"running":true` instead (see `compose.yaml`). A good example of a tool returning something *true but misleading*.
3. **A forced-out member waits 60s before reconnecting** (`max-wait-time-reconnect`). Expect `heal` to sit at "not back yet" for about a minute after `pause` or `isolate`.
4. **After a lost quorum the locator deadlocks.** It forces itself out, then waits for a quorum of the *old* members ("quorum check: contacted 2 processes with 13 member weight units. Threshold for a quorum is 19"). Those are dead; the restarted servers can't join meanwhile ("Connection refused", "Server is shutting down due to an exception during startup"). Nothing ends it except restarting the locator, so `heal` does that if the locator is running but silent for 45s. This is the "after losing quorum, restart the cluster" step real operators do.

Two smaller ones:
- **The MCP server has a circuit breaker** in front of the Management API: after 5 failures it stops trying for 30s ("5 consecutive failures tripped the circuit breaker. Not retrying for another 11s"). So live tools can lag ~30s behind the locator coming back.
- **`docker kill` does not trigger `restart: on-failure`.** Docker counts it as a manual stop, so the locator stays down until `heal`.

## The client's view

The workload barely noticed single failures: on `kill`, its pool logged "Pool unexpected closed socket on server connection" and **retried on another server: 0 errors**. On `locator-down`: nothing at all. Only kill-majority hurt (63,580 failed operations during the outage), and it recovered by itself once the cluster was back.

## Ask the AI

With failures in `data/chaos.log`, ask in Claude Code (`claude`, in this folder) with no hints:

> "What happened to the GemFire cluster in the last 30 minutes? Give me a timeline (UTC) of each incident: what kind of failure it was, which member, and how you can tell."

Then `cat data/chaos.log` and compare.

### What Claude made of it

We ran exactly that, headless and blind:

```bash
claude -p "What happened to the GemFire cluster in the last 40 minutes? ..." \
  --mcp-config .mcp.json --strict-mcp-config --allowedTools "mcp__gemfire__*" \
  --disallowedTools "Read,Bash,Glob,Grep,Edit,Write,WebFetch,WebSearch,Agent"
```

(The `--disallowedTools` matters. Without it, the first attempt also **read `scripts/chaos.sh`**, which describes every scenario: not a fair test. `--allowedTools` only pre-approves tools; it doesn't forbid the others.)

20 tool calls, about 2.5 minutes, about $1.20. The calls: `get_membership_timeline`, `collect_member_departure_evidence` per departed member, `search_logs` with patterns, `get_member_final_stats`, `get_partition_region_health`, `list_regions`. Against `data/chaos.log`:

| chaos.log | Claude's verdict (times UTC) | Right? |
|---|---|---|
| 18:45:32 kill server-2 | 18:45:32 "process died suddenly… looks like a `kill -9`": connections closed instantly, no log lines, healthy heap/GC just before | ✅ |
| 18:47:06 stop server-3 | 18:47:06 "clean shutdown" (GRACEFUL_EXIT) | ✅ |
| 18:48:15 pause server-1 | 18:48:15–48 "process froze for about 32 s… as with `SIGSTOP` or `docker pause`": JVM-pause warning + a 33 s gap in the stats, GC only 34 ms. "It was the same process when it reconnected… not restarted" | ✅ |
| *(not in the log: I re-created the servers by hand to apply a healthcheck change)* | 18:56:02–17 "rolling restart, one server at a time" | ✅ found something the ground truth missed |
| 18:56:53 isolate server-3 | 18:57 "cut off from the network": suspicion went **both ways**, "No thread delays observed", reconnected in the same process | ✅ |
| 18:58:55 locator-down | 18:58:55 "process died suddenly", server-1 took over as coordinator | ✅ |
| 19:00:08 kill-majority server-1 server-2 | 19:00:08 both died together → quorum lost (25 of 38) → full outage until 19:06; spotted the **deadlock** ("got answers from only 2 members, worth 13 of the 19 weight units it needs") and that Customers was lost but Orders came back from disk | ✅ |

It also flagged both quirks from this chunk without being asked: server-3 "still shows as starting… My guess is the status wasn't updated after it reconnected on its own", and the health check is CRITICAL only "because the check counts membership events from the last 15 minutes".

**And it caught a weakness in an MCP tool.** `get_membership_timeline` marks the locator `CRASHED` and server-1/server-2 `LOST_IN_QUORUM_LOSS` at 18:57:11. That's server-3's one-sided view while it was isolated (we checked: the timeline really says that). It then has no departure event for the locator's real kill at 18:58:55, or for the servers' real deaths at 19:00:08. Claude noticed the timeline contradicted the logs and rebuilt incidents 6 and 7 from `search_logs` and stats instead. Same lesson as chunk 5: **tools return facts as they see them; the reasoning on top is what turns them into the truth.**

## Things to try

- `kill` the same server twice in a row without healing: what does `members_present` say about a member that's been gone more than 15 minutes?
- `make load P=heap-hog`, then `kill` a server: Sessions has no redundancy, so what happens to its data?
- `pause` for only 3 seconds (`docker compose pause server-1; sleep 3; docker compose unpause server-1`): under `member-timeout`, so does anyone notice?
