# Issues found while building the lab (candidates to report to Broadcom)

Found between 2026-11-23 and 2026-11-24 while building this lab, mostly during chunk 6 (failure scenarios). Each issue has the versions, steps to reproduce, what we expected, what happened, the evidence (log lines and tool output copied verbatim), the workaround we used, and how sure we are.

| # | Product | Issue | Type | Confidence |
|---|---|---|---|---|
| 1 | GemFire MCP Server 1.0.0 | `get_membership_timeline` records an isolated member's one-sided view as fact for the whole cluster, then misses the real departures that follow | Bug | High: reproduced and checked against ground truth |
| 2 | GemFire 10.3.4 | After an auto-reconnect, the Management REST API reports the member's `status` as `"starting"` permanently | Bug | High: seen on 3 different servers |
| 3 | GemFire 10.3.4 | After a quorum loss, the reconnecting locator waits indefinitely for a quorum of members that no longer exist; restarted servers can't join and exit | Question / docs | Medium: seen twice; might be by design |
| 4 | GemFire MCP Server 1.0.0 | `assess_cluster_health` returns UNKNOWN for stats-based checks while the Management REST API is down, though the telemetry store has the data | Enhancement | High (observed); whether it's intended is unknown |
| 5 | GemFire MCP Server 1.0.0 | `membership_events` keeps the overall status CRITICAL for 15 minutes after a full recovery, with no sign the event is over | Enhancement | High (observed); likely by design |
| 6 | Spring for GemFire 2.0.1 + GemFire 10.3.4 | Every client startup logs 3 ERROR-level `DEPRECATED` stack traces from `ClientCacheFactoryBean.configurePool` | Bug / noise | High: every startup |

## Environment

| Component | Version / setting |
|---|---|
| GemFire | `gemfire/gemfire:10.3.4-jdk17` Docker image, G1 GC; 1 locator + 3 servers in Docker Compose (Docker Desktop on macOS) |
| Membership settings | defaults: `member-timeout=5000`, `enable-network-partition-detection=true`, `disable-auto-reconnect=false`, `max-wait-time-reconnect=60000`, `max-num-reconnect-tries=3` |
| Regions | `Customers` PARTITION_REDUNDANT, `Orders` PARTITION_REDUNDANT_PERSISTENT, `Sessions` PARTITION, `Products` REPLICATE |
| GemFire MCP Server | `gemfire-mcp-server-1.0.0.jar` on Eclipse Temurin 21; `GF_MCP_GEMFIRE_URL` → locator Management REST |
| Telemetry forwarder | `gemfire-telemetry-forwarder-1.0.0`, 10 s interval, S3 store (SeaweedFS 4.55) |
| Client | Spring Boot 4.1.1, `com.vmware.gemfire:spring-boot-4.1-gemfire-10.3:2.0.1` (pulls in `spring-data-4.1-gemfire-10.3-2.0.1`), `gemfire-core:10.3.4` |

---

## 1. `get_membership_timeline` takes an isolated member's view as cluster-wide fact

**Product:** GemFire MCP Server 1.0.0, tool `get_membership_timeline`

**Steps to reproduce**
1. Healthy cluster: locator + server-1..3.
2. Isolate one server from the network: `docker network disconnect <net> server-3` (it stays running).
3. Wait ~20 s. server-3 detects it's cut off, logs a quorum loss, and forces itself out. Reconnect it to the network; it rejoins.
4. Later, kill the locator for real (`docker kill`), then bring it back.
5. Later, kill two servers for real at once (`docker kill server-1 server-2`).
6. Call `get_membership_timeline` over the whole window.

**What actually happened** (from our record of what we did, UTC):
```
18:56:53  isolate        server-3
18:58:55  locator-down   locator          (docker kill)
19:00:08  kill-majority  server-1 server-2 (docker kill)
```

**What the tool returned** (filtered to time, member and kind):
```
18:57:01.872  locator   SUSPECTED
18:57:02.886  server-3  SUSPECTED
18:57:04.374  server-1  SUSPECTED
18:57:06.871  server-2  SUSPECTED
18:57:08.255  server-3  FORCED_DISCONNECT
18:57:11.930  -         QUORUM_LOSS
18:57:11.931  locator   CRASHED                <- wrong: the locator was fine; only server-3 lost contact
18:57:11.931  server-1  LOST_IN_QUORUM_LOSS    <- wrong: server-1 stayed in the cluster
18:57:11.931  server-2  LOST_IN_QUORUM_LOSS    <- wrong: server-2 stayed in the cluster
18:58:13.491  server-3  RECONNECTED
18:59:37.087  locator   REJOINED               <- but no departure event for the real kill at 18:58:55
19:00:14.085  -         QUORUM_LOSS
19:00:14.105  server-3  FORCED_DISCONNECT
19:00:15.109  locator   FORCED_DISCONNECT
                                               <- no departure events for server-1/server-2 killed at 19:00:08
19:06:00.915  server-1  REJOINED
19:06:00.915  server-2  REJOINED
19:06:25.051  server-3  RECONNECTED
```

**Expected**
- The 18:57 quorum loss was declared by **server-3 alone**, from its own isolated side. It should be attributed to server-3, or marked as one member's view, not turned into `CRASHED` / `LOST_IN_QUORUM_LOSS` events for the members that stayed in the cluster.
- The real locator departure at 18:58:55 (the other members logged "Member at locator… unexpectedly left the distributed cache" at 18:59:01) should appear as a departure.
- The real departures of server-1 and server-2 at 19:00:08 should appear.

**Evidence behind the 18:57:11 events** (server-3's own log, the only member that logged them):
```
2026-11-24T18:57:11.930Z server-3 WARN  total weight lost in this view change is 28 of 38.  Quorum has been lost!
2026-11-24T18:57:11.931Z server-3 FATAL Possible loss of quorum due to the loss of 3 cache processes: [locator(...), server-2(...), server-1(...)]
2026-11-24T18:57:12.948Z server-3 ERROR cluster membership failed due to
  org.apache.geode.ForcedDisconnectException: Exiting due to possible network partition event due to loss of 3 cache processes: [locator(...
```

**Impact:** An AI client relying on this tool gets a wrong incident history: a locator "crash" that never happened, and servers counted as gone (Claude worked out "528 s") when they never left. In our test, Claude noticed the timeline contradicted `search_logs` and rebuilt the history from logs and stats, but a less careful client would report the wrong story.

**Workaround:** cross-check with `search_logs` (signals `membership`, `partition`, `forced_disconnect`) and the stats history.

---

## 2. Member `status` stays `"starting"` after an auto-reconnect

**Product:** GemFire 10.3.4, Management REST API (`GET /management/v1/members/{id}`). The GemFire MCP Server's `list_members` passes it on as-is.

**Steps to reproduce**
1. Healthy cluster, defaults (`disable-auto-reconnect=false`).
2. Freeze a server long enough to be removed: `docker pause server-1`, wait ~30 s, `docker unpause server-1`. (Also reproduced by cutting a server off the network for ~45 s and reconnecting it.)
3. The server gets a `ForcedDisconnectException`, waits `max-wait-time-reconnect` (60 s), reconnects, and logs `Reconnect completed.`
4. `GET /management/v1/members/server-1`.

**Expected:** `"status":"online"` once the reconnect has finished.

**Actual:** `"status":"starting"` **permanently**. server-3 stayed `starting` for ~15 minutes, through two locator restarts, until we tore the lab down. We saw it on 3 different servers: server-1 after a pause, server-3 after a network isolation, and server-2 after a pause on a freshly started cluster, even though the member is fully working:
```json
{"status":"starting",
 "cacheServerInfo":[{"maxConnections":1200,"maxThreads":0,"port":40404,"running":true}],
 "hostedRegions":["Orders","Products","Customers","Sessions"],
 "clientCount":10}
```
Server log at the end of the reconnect:
```
[info 2026/11/24 18:49:49.976 GMT server-1 <ReconnectThread> tid=0x20a] Cache server connection listener bound to address server-1-0.0.0.0/0.0.0.0:40404 with backlog 1280.
[info 2026/11/24 18:50:04.983 GMT server-1 <ReconnectThread> tid=0x20a] Reconnect completed.
```
`list_members` via the GemFire MCP Server, at the same time:
```json
[{"name":"server-1","status":"starting"},{"name":"server-2","status":"online"},{"name":"server-3","status":"online"}]
```
A restarted (not reconnected) member goes back to `online`. Only the auto-reconnect path leaves it at `starting`.

**Impact**
- Any health check or automation that waits for `online` treats a healthy member as down forever. Our Docker healthcheck did exactly that until we changed it.
- MCP clients and AI assistants are told the member is still starting.

**Workaround:** check `cacheServerInfo[].running == true` instead of `status == "online"`.

---

## 3. After a quorum loss, the locator waits for members that no longer exist; restarted servers can't join

**Product:** GemFire 10.3.4 (membership / locator auto-reconnect). This may be by design; we'd like it confirmed and documented.

**Steps to reproduce**
1. Healthy cluster: 1 locator + 3 servers, defaults.
2. `docker kill server-1 server-2`, both at the same moment.
3. The locator, acting as coordinator, sees 25 of 38 weight lost, declares a network partition, and forces server-3 **and itself** out (expected: split-brain protection).
4. Restart server-1 and server-2 (`docker start`).

**Expected:** the surviving locator re-forms the cluster, and the restarted servers join it, or at least keep retrying until it's ready.

**Actual**
- The locator's reconnect waits for a quorum of the **old** view's members, which are dead:
  ```
  [info 2026/11/24 19:04:45.908 GMT locator <Location services restart thread> tid=0xdd] quorum check: timeout waiting for responses.  2 responses received
  [info 2026/11/24 19:04:45.909 GMT locator <Location services restart thread> tid=0xdd] quorum check: contacted 2 processes with 13 member weight units.  Threshold for a quorum is 19
  ```
- Meanwhile its locator port refuses connections, so the restarted servers **give up and exit** on startup:
  ```
  [info 2026/11/24 19:01:05.704 GMT server-1 <main> tid=0x1] Unable to contact locator locator/<unresolved>:10334: java.net.ConnectException: Connection refused
  [fatal 2026/11/24 19:01:05.712 GMT server-1 <main> tid=0x1] Server is shutting down due to an exception during startup
  ```
- No progress for ~5 minutes until we restarted the locator by hand. After that, everything recovered within about a minute: the servers joined and server-3's reconnect succeeded. We reproduced this a second time with the same result.

**Questions for Broadcom**
- Is the reconnecting locator supposed to wait indefinitely when the old quorum members are gone, or does it give up after `max-num-reconnect-tries`?
- Is "restart the locator(s) after a quorum loss" the documented recovery procedure? If so, a log line saying that would help operators (and AI assistants reading the logs).
- Should a starting server retry the locator for longer, rather than exiting after one refused connection?

**Workaround:** restart the locator if it's running but its Management REST API hasn't answered for ~45 s, then start the servers.

---

## 4. `assess_cluster_health` returns UNKNOWN for stats-based checks while the locator is down

**Product:** GemFire MCP Server 1.0.0, tool `assess_cluster_health`. Enhancement request.

**Steps to reproduce:** `docker kill <locator>` (the servers keep running and serving clients), then call `assess_cluster_health`.

**Actual**
```json
{"status":"CRITICAL","checksByStatus":{"CRITICAL":1,"UNKNOWN":8}, "checks":[
 {"check":"members_present","status":"UNKNOWN","message":"The cluster's members could not be read from the Management REST API."},
 {"check":"tenured_heap","status":"UNKNOWN", ...same message},
 {"check":"heap_critical_state","status":"UNKNOWN", ...},
 {"check":"gc_time","status":"UNKNOWN", ...},
 {"check":"jvm_pauses_and_sampler_delay","status":"UNKNOWN", ...},
 {"check":"cpu","status":"UNKNOWN", ...},
 {"check":"partitioned_region_redundancy","status":"UNKNOWN","message":"The cluster's regions could not be read from the Management REST API."},
 {"check":"membership_events","status":"CRITICAL", ...}]}
```

**Suggestion:** the heap, GC, JVM-pause and CPU checks read the stats history in the telemetry store, which is still there and fresh (the forwarder keeps shipping every 10 s). With no live member list, they could fall back to "members with stats in the last N minutes", clearly labelled as such. When the locator is down is exactly when an operator most needs the rest of the health picture, and `query_stat` / `search_logs` keep working at that point.

---

## 5. `membership_events` keeps the overall status CRITICAL for 15 minutes after recovery

**Product:** GemFire MCP Server 1.0.0, `assess_cluster_health` check `membership_events`. Minor enhancement; likely by design.

**Observed:** after a full recovery (every member back, all redundancy restored, every other check HEALTHY), the overall status stayed CRITICAL:
```json
{"status":"CRITICAL","checks":[{"check":"membership_events","status":"CRITICAL",
  "message":"2 quorum loss(es), 6 partition line(s) and 3 forced disconnect(s) in the last 15 minutes."}]}
```

**Suggestion:** say whether the events are still in progress or already resolved (e.g. "…all members have since rejoined"), or report resolved events as WARNING. Otherwise a client polling health sees CRITICAL for 15 minutes on a cluster that's fine. Claude explained it correctly ("only because the check counts membership events from the last 15 minutes"), but simpler clients won't.

---

## 6. Spring for GemFire logs 3 ERROR-level `DEPRECATED` stack traces at every client startup

**Product:** `spring-boot-4.1-gemfire-10.3:2.0.1` / `spring-data-4.1-gemfire-10.3-2.0.1` with `gemfire-core:10.3.4`

**Steps to reproduce:** a minimal Spring Boot 4.1 app with the starter and `spring.data.gemfire.pool.locators` set. Start it.

**Actual:** three ERROR lines, each with a full `DeprecatedException` stack trace:
```
ERROR o.a.g.internal.cache.PoolFactoryImpl : DEPRECATED: Method public abstract org.apache.geode.cache.client.PoolFactory org.apache.geode.cache.client.PoolFactory.setMinConnections(int) is deprecated and will be removed in the next major release.
org.apache.geode.logging.internal.deprecation.DeprecatedException:
	at org.apache.geode.internal.cache.PoolFactoryImpl.setMinConnections(PoolFactoryImpl.java:250) ~[gemfire-core-10.3.4.jar!/:na]
	at org.springframework.data.gemfire.client.ClientCacheFactoryBean.configurePool(ClientCacheFactoryBean.java:289) ~[spring-data-4.1-gemfire-10.3-2.0.1.jar!/:na]
	...
ERROR ... PoolFactory.setMaxConnections(int) is deprecated ...       (PoolFactoryImpl.java:229)
ERROR ... PoolFactory.setPRSingleHopEnabled(boolean) is deprecated ... (PoolFactoryImpl.java:428)
```

**Expected:** a supported Spring for GemFire release shouldn't call APIs its matching GemFire release deprecates, or it should at least only call them when the user set those properties. Separately: should a deprecation notice be logged at **ERROR** with a stack trace? WARN without a trace seems more proportionate.

**Impact:** ERROR-level noise in every client's logs. These are exactly the logs an operator, or an AI assistant using `search_logs` with `min_severity: ERROR`, will look at first.

**Workaround:** none in our code (the calls come from the framework). We left them visible rather than silence a GemFire logger.

---

## Not Broadcom issues (for completeness)

- **SeaweedFS 4.01** stored AWS SDK `aws-chunked` uploads with their framing still attached, so the MCP server read them as "Not in GZIP format". Fixed in SeaweedFS 4.55.
- **Our own setup:** a healthcheck that connected to the cache-server port and hung up made servers log an `EOFException` every 5 s (Claude found this, chunk 5). It was our probe, not a GemFire bug.
- **Claude Code:** `--allowedTools` only pre-approves tools; it doesn't forbid the rest. For a blind test you also need `--disallowedTools`.
