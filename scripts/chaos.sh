#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Break the GemFire cluster on purpose (chunk 6), then see what the MCP server can tell you.
#
#   scripts/chaos.sh pick                    # fzf: pick a failure, then a server
#   scripts/chaos.sh <failure> [server]      # kill | stop | pause | isolate   (default server-2)
#   scripts/chaos.sh locator-down
#   scripts/chaos.sh kill-majority           # 2 of 3 servers at once
#   scripts/chaos.sh heal                    # undo everything above
#
# Every action prints the docker command it runs and appends a UTC timestamp to data/chaos.log:
# the ground truth to compare against what the MCP tools (and Claude) say happened.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NETWORK=gfmcp
SERVERS="server-1 server-2 server-3"
CHAOS_LOG="$ROOT/data/chaos.log"

c_dim=$'\e[2m'; c_cmd=$'\e[33m'; c_ok=$'\e[32m'; c_err=$'\e[31m'; c_hint=$'\e[36m'; c_off=$'\e[0m'

run()  { printf '%s$ %s%s\n' "$c_cmd" "$*" "$c_off"; "$@"; }
die()  { printf '%s%s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }
now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Ground truth for later: "2026-11-24T15:02:11Z  kill  server-2"
record() {
  mkdir -p "$(dirname "$CHAOS_LOG")"
  printf '%s  %s\n' "$TS" "$*" >>"$CHAOS_LOG"
  printf '%srecorded in data/chaos.log: %s  %s%s\n' "$c_dim" "$TS" "$*" "$c_off"
}

# Container id / name / state for a compose service (-a: include stopped ones)
cid()   { docker compose ps -aq "$1" 2>/dev/null | head -1; }
cname() { docker inspect -f '{{.Name}}' "$(cid "$1")" | sed 's|^/||'; }
state() { local id; id=$(cid "$1"); [ -n "$id" ] && docker inspect -f '{{.State.Status}}' "$id" || echo missing; }
on_network() { docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$(cid "$1")" | grep -qw "$NETWORK"; }

require_running() {
  local s; s=$(state "$1")
  [ "$s" = running ] || die "$1 is $s, not running. Run 'make heal' first."
}

# ── What each failure is, and what to look for (also the fzf preview) ─────────
describe() {
  case "$1" in
    kill) cat <<'EOF'
kill: a crash. docker compose kill sends SIGKILL: no shutdown, no goodbye.

Expect:
  - the other members log "<server> ... unexpectedly left the distributed cache"
  - Customers + Orders: "Redundancy has dropped below 1 configured copies"
    (and it stays down: GemFire doesn't re-create copies until the member returns)
  - the workload sees a few errors, then carries on with 2 servers

MCP signals: membership, redundancy
EOF
    ;;
    stop) cat <<'EOF'
stop: a clean shutdown. docker compose stop sends SIGTERM and GemFire closes the cache properly.

Expect:
  - "<server> ... gracefully left the distributed cache" (not "unexpectedly")
  - the stopped server's own log ends with its shutdown messages
  - redundancy drops, just like a crash

Good test: can Claude tell a crash from a clean stop?
MCP signals: membership, redundancy
EOF
    ;;
    pause) cat <<'EOF'
pause: a frozen JVM (think: a very long GC pause). docker compose pause freezes every process.

Expect:
  - after a few seconds the others say it "isn't responding to heartbeat requests"
  - then it's removed from the cluster (a new membership view without it)
  - the frozen server logs nothing, it's frozen. Its side of the story only appears
    after 'make heal' unpauses it: a JVM pause warning, a forced disconnect, a reconnect

MCP signals: membership, forced_disconnect, jvm_pause (after heal)
EOF
    ;;
    isolate) cat <<'EOF'
isolate: a network cut. docker network disconnect takes the server off the gfmcp network.
The JVM stays awake but can't reach anyone: the opposite of pause.

Expect:
  - the others see it stop responding and remove it
  - the isolated server notices by itself and logs it (possible network partition,
    forced disconnect) and keeps trying to reconnect

MCP signals: membership, partition, forced_disconnect
EOF
    ;;
    locator-down) cat <<'EOF'
locator-down: kill the locator (SIGKILL).

The locator is also the MCP server's ONLY live source (Management REST on :7070).
Expect:
  - servers and workload traffic keep going: clients already know where the servers are
  - LIVE MCP tools fail: list_members, list_regions
  - HISTORY MCP tools still work: query_stat, search_logs (they read the S3 store)

MCP signals: membership (the locator leaving)
EOF
    ;;
    kill-majority) cat <<'EOF'
kill-majority: SIGKILL 2 of the 3 servers at the same time.

GemFire gives members weights (server 10, locator 3, +5 for the lead member). If a membership
change loses half of the cluster's weight or more, the survivors suspect a network partition
and may shut THEMSELVES down rather than risk two halves both acting as the cluster.
Customers keeps 1 redundant copy, so losing 2 servers loses some of its data.

Expect: partition / quorum warnings, "copies of some data have been lost", maybe a dead cluster.
MCP signals: partition, membership, redundancy
EOF
    ;;
    heal) cat <<'EOF'
heal: undo all of the above.
  1. unpause any paused member
  2. reconnect any member taken off the network
  3. start anything stopped, and wait until every member is healthy

Expect: members rejoin, Orders (persistent) recovers from disk,
"Redundancy ... copies has been restored".
EOF
    ;;
    *) die "unknown failure '$1' (kill, stop, pause, isolate, locator-down, kill-majority, heal)";;
  esac
}

# What to ask next: ready-to-run make call lines, using this action's timestamp
hints() {
  local what="$1" who="${2:-}"
  printf '\n%sWhat to look for next (give the forwarder ~10-20s to ship the logs):%s\n' "$c_hint" "$c_off"
  local around="\"around\":\"$TS\",\"radius\":\"5m\""
  case "$what" in
    kill|stop)
      echo "  make call T=list_members A='{\"role\":\"servers\"}'"
      echo "  make call T=search_logs A='{$around,\"signal\":\"membership\"}'"
      echo "  make call T=search_logs A='{$around,\"signal\":\"redundancy\"}'"
      echo "  make call T=assess_cluster_health" ;;
    pause)
      echo "  make call T=search_logs A='{$around,\"signal\":\"membership\"}'"
      echo "  make call T=list_members A='{\"role\":\"servers\"}'"
      echo "  then: make heal, and search again with \"signal\":\"forced_disconnect\" or \"jvm_pause\"" ;;
    isolate)
      echo "  make call T=search_logs A='{$around,\"member_names\":[\"$who\"]}'"
      echo "  make call T=search_logs A='{$around,\"signal\":\"forced_disconnect\"}'"
      echo "  make call T=list_members A='{\"role\":\"servers\"}'" ;;
    locator-down)
      echo "  make call T=list_members                                   # live: should fail"
      echo "  make call T=query_stat A='{\"member_name\":\"server-1\",\"signal\":\"put_rate\"}'   # history: should work"
      echo "  curl -s localhost:18090/status | jq .actualOpsPerSecond      # traffic: still flowing?" ;;
    kill-majority)
      echo "  make status                                                 # who is still alive?"
      echo "  make call T=search_logs A='{$around,\"signal\":\"partition\"}'"
      echo "  make call T=search_logs A='{$around,\"signal\":\"redundancy\"}'"
      echo "  make call T=assess_cluster_health" ;;
    heal)
      echo "  make call T=assess_cluster_health"
      echo "  make call T=search_logs A='{$around,\"signal\":\"redundancy\"}'" ;;
  esac
  printf '\n%sOr ask Claude (claude, in this folder): "What happened to the GemFire cluster in the last 15 minutes?"%s\n' "$c_hint" "$c_off"
  printf '%sThen compare with: cat data/chaos.log%s\n' "$c_dim" "$c_off"
}

# ── The failures ──────────────────────────────────────────────────────────────
one_server() {   # kill | stop | pause | isolate
  local what="$1" who="${2:-server-2}"
  case " $SERVERS " in *" $who "*) ;; *) die "'$who' is not a server ($SERVERS)";; esac
  require_running "$who"
  TS=$(now)
  case "$what" in
    kill)    run docker compose kill "$who" ;;
    stop)    run docker compose stop "$who" ;;
    pause)   run docker compose pause "$who" ;;
    isolate) on_network "$who" || die "$who is already off the $NETWORK network"
             run docker network disconnect "$NETWORK" "$(cname "$who")" ;;
  esac
  record "$what  $who"
  hints "$what" "$who"
}

locator_down() {
  require_running locator
  TS=$(now)
  run docker compose kill locator
  record "locator-down  locator"
  hints locator-down
}

kill_majority() {
  local alive="" s
  for s in $SERVERS; do [ "$(state "$s")" = running ] && alive="$alive $s"; done
  set -- $alive
  [ $# -ge 2 ] || die "only $# server(s) running; kill-majority needs 2. Run 'make heal' first."
  TS=$(now)
  run docker compose kill "$1" "$2"   # one command: both die at (nearly) the same moment
  record "kill-majority  $1 $2"
  hints kill-majority
}

heal() {
  local s did=""
  TS=$(now)
  for s in locator $SERVERS; do
    [ "$(state "$s")" = paused ] && { run docker compose unpause "$s"; did="$did unpause:$s"; }
  done
  for s in locator $SERVERS; do
    local st; st=$(state "$s")
    if [ "$st" = running ] && ! on_network "$s"; then
      # --alias: other members and clients find it by its service name (server-2), as compose set it up
      run docker network connect --alias "$s" "$NETWORK" "$(cname "$s")"
      did="$did reconnect:$s"
    fi
  done
  for s in locator $SERVERS; do
    [ "$(state "$s")" = running ] || did="$did start:$s"
  done
  # Start whatever is stopped (no-op otherwise). --no-recreate: start the existing containers, don't
  # replace them. No --wait: Docker's health status lags here (a paused container keeps its old
  # "healthy", an isolated one may already be "unhealthy"), so ask the locator directly instead.
  run docker compose up -d --no-recreate locator $SERVERS
  wait_for_servers
  if [ -n "$did" ]; then
    record "heal ${did# }"
    hints heal
  else
    printf '%sNothing to heal: every member was already running and connected.%s\n' "$c_ok" "$c_off"
  fi
}

# A server is back when the locator lists it with its cache server running (same test as its
# healthcheck in compose.yaml). A member forced out of the cluster (pause, isolate) reconnects by
# itself, but only after max-wait-time-reconnect (60s); one that gives up exits, so restart it.
server_ready() { curl -fs "http://localhost:17070/management/v1/members/$1" 2>/dev/null | grep -q '"running":true'; }

wait_for_servers() {
  local s waiting start=$SECONDS restarted_locator=""
  printf '%sWaiting for the locator to list every server as back (a forced-out member waits 60s before reconnecting)...%s\n' "$c_dim" "$c_off"
  while :; do
    waiting=""
    if ! curl -fs http://localhost:17070/management/v1/ping 2>/dev/null | grep -q pong; then
      waiting=" locator"
      # After a lost quorum (kill-majority) the locator forces itself out, then waits for a quorum
      # of the OLD members before it accepts anyone. They're dead, and new servers can't join it in
      # the meantime ("Connection refused"), so it never ends: only a restart breaks the deadlock.
      if [ -z "$restarted_locator" ] && [ $((SECONDS - start)) -ge 45 ] && [ "$(state locator)" = running ]; then
        printf '%sThe locator is running but not answering: stuck waiting for a quorum of members that are gone. Restarting it.%s\n' "$c_err" "$c_off"
        run docker compose restart locator
        restarted_locator=yes; did="$did restart:locator"
      fi
    else
    for s in $SERVERS; do
      server_ready "$s" && continue
      waiting="$waiting $s"
      [ "$(state "$s")" = exited ] && run docker compose up -d --no-recreate "$s"
    done
    fi
    [ -z "$waiting" ] && break
    [ $((SECONDS - start)) -ge 240 ] && die "still not back after 4 min:$waiting (make logs S=${waiting# })"
    printf '%s  %3ss  not back yet:%s%s\n' "$c_dim" $((SECONDS - start)) "$waiting" "$c_off"
    sleep 10
  done
  printf '%sAll servers back (%ss).%s\n' "$c_ok" $((SECONDS - start)) "$c_off"
}

pick() {
  command -v fzf >/dev/null || die "fzf not found (brew install fzf), or run: make chaos C=kill M=server-2"
  local what who
  what=$(printf '%s\n' kill stop pause isolate locator-down kill-majority heal \
    | fzf --height=60% --reverse --header "Break something (or heal). Current state: $(status_line)" \
          --preview "$0 describe {}" --preview-window=right,65%,wrap) || exit 0
  case "$what" in
    kill|stop|pause|isolate)
      who=$(for s in $SERVERS; do printf '%s\t%s\n' "$s" "$(state "$s")"; done \
        | fzf --height=40% --reverse --delimiter='\t' --header "$what which server?" | cut -f1) || exit 0
      one_server "$what" "$who" ;;
    locator-down)  locator_down ;;
    kill-majority) kill_majority ;;
    heal)          heal ;;
  esac
}

status_line() {
  local s out=""
  for s in locator $SERVERS; do
    local st; st=$(state "$s")
    [ "$st" = running ] && ! on_network "$s" && st=isolated
    out="$out $s=$st"
  done
  echo "${out# }"
}

case "${1:-pick}" in
  pick)                    pick ;;
  describe)                describe "${2:?describe what?}" ;;
  kill|stop|pause|isolate) one_server "$1" "${2:-}" ;;
  locator-down)            locator_down ;;
  kill-majority)           kill_majority ;;
  heal)                    heal ;;
  *)                       describe "$1" ;;   # prints the "unknown failure" error
esac
