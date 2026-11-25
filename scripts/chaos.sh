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
. "$ROOT/scripts/ui.sh"
. "$ROOT/scripts/security.sh"   # locator_get: the locator REST API, with credentials (chunk 10)

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
    kill)
      ui_title danger KILL "a crash: SIGKILL, no shutdown, no goodbye"
      ui_section "What it does"
      ui_line "$(ui_cmd "docker compose kill <server>")"
      ui_section "Expect"
      ui_bullet "the others log $(ui_log "…unexpectedly left the distributed cache")"
      ui_line   "  $(ui_dim "within ~5s: member-timeout=5000")"
      ui_bullet "Customers + Orders: $(ui_log "Redundancy has dropped below 2 configured copies")"
      ui_line   "  $(ui_dim "and it stays down until the member comes back")"
      ui_bullet "the workload retries on the other servers: ~0 errors"
      ui_blank
      ui_field "MCP signals" "$(ui_tags membership redundancy)"
      ui_field "Undo" "$(ui_cmd "make heal")"
      ;;
    stop)
      ui_title warn STOP "a clean shutdown: SIGTERM, GemFire closes the cache properly"
      ui_section "What it does"
      ui_line "$(ui_cmd "docker compose stop <server>")"
      ui_section "Expect"
      ui_bullet "$(ui_log "…gracefully left the distributed cache: shutdown message received")"
      ui_line   "  $(ui_dim "noticed in ~0.3s, not ~5s like a crash")"
      ui_bullet "the stopped server's own log ends with its shutdown sequence"
      ui_bullet "redundancy drops, just like a crash"
      ui_section "Good test"
      ui_line "Can the AI tell a crash from a clean stop? (gracefully vs unexpectedly)"
      ui_blank
      ui_field "MCP signals" "$(ui_tags membership redundancy)"
      ui_field "Undo" "$(ui_cmd "make heal")"
      ;;
    pause)
      ui_title warn PAUSE "a frozen JVM, like a very long GC pause"
      ui_section "What it does"
      ui_line "$(ui_cmd "docker compose pause <server>")"
      ui_section "Expect"
      ui_bullet "after ~8s the others: $(ui_log "Member isn't responding to heartbeat requests")"
      ui_bullet "after ~13s it's removed $(ui_dim "(a new membership view without it)")"
      ui_bullet "the frozen server logs nothing: it's frozen"
      ui_section "After make heal"
      ui_bullet "$(ui_log "JVM pause with a wakeup delay of …ms"), then ForcedDisconnectException"
      ui_bullet "it reconnects by itself after 60s $(ui_dim "(max-wait-time-reconnect)")"
      ui_bullet "$(ui_dim "quirk: its status then stays \"starting\" for good")"
      ui_blank
      ui_field "MCP signals" "$(ui_tags membership forced_disconnect jvm_pause)"
      ui_field "Undo" "$(ui_cmd "make heal") $(ui_dim "(waits ~60s for the reconnect)")"
      ;;
    isolate)
      ui_title warn ISOLATE "a network cut: awake, but can't reach anyone"
      ui_section "What it does"
      ui_line "$(ui_cmd "docker network disconnect gfmcp <container>")"
      ui_section "Expect"
      ui_bullet "both sides suspect each other"
      ui_bullet "the cut-off server works it out itself: $(ui_log "Quorum has been lost!")"
      ui_line   "  $(ui_dim "it lost 28 of 38 weight units, so it removes itself")"
      ui_bullet "$(ui_log "ForcedDisconnectException: Exiting due to possible network partition")"
      ui_blank
      ui_field "MCP signals" "$(ui_tags membership partition forced_disconnect)"
      ui_field "Undo" "$(ui_cmd "make heal") $(ui_dim "(reconnects it; back in ~40s)")"
      ;;
    locator-down)
      ui_title warn LOCATOR-DOWN "SIGKILL the locator, the MCP server's only LIVE source"
      ui_section "What it does"
      ui_line "$(ui_cmd "docker compose kill locator")"
      ui_section "Expect"
      ui_bullet "servers and workload traffic carry on $(ui_dim "(clients already know the servers)")"
      ui_bullet "live tools fail: $(ui_bold list_members), $(ui_bold list_regions)"
      ui_bullet "history tools still work: $(ui_bold query_stat), $(ui_bold search_logs)"
      ui_bullet "assess_cluster_health: 8 of 9 checks UNKNOWN"
      ui_line   "  $(ui_dim "afterwards the MCP server's circuit breaker waits up to 30s")"
      ui_blank
      ui_field "MCP signals" "$(ui_tags membership)"
      ui_field "Undo" "$(ui_cmd "make heal")"
      ;;
    kill-majority)
      ui_title danger KILL-MAJORITY "SIGKILL 2 of the 3 servers at once"
      ui_section "What it does"
      ui_line "$(ui_cmd "docker compose kill server-1 server-2")"
      ui_section "Expect"
      ui_bullet "the locator: $(ui_log "total weight lost … 25 of 38. Quorum has been lost!")"
      ui_bullet "it declares a network partition and shuts the WHOLE cluster down"
      ui_line   "  $(ui_dim "on purpose: two halves both acting as the cluster = split brain")"
      ui_bullet "Customers + Products data lost; Orders comes back from disk"
      ui_bullet "workload: 0 ops/s until heal"
      ui_blank
      ui_field "MCP signals" "$(ui_tags partition membership redundancy)"
      ui_field "Undo" "$(ui_cmd "make heal") $(ui_dim "(restarts the deadlocked locator; ~2 min)")"
      ;;
    heal)
      ui_title safe HEAL "undo all of the above"
      ui_section "What it does"
      ui_bullet "unpause any paused member"
      ui_bullet "reconnect any member taken off the network"
      ui_bullet "start anything stopped, then wait until the locator lists every server"
      ui_bullet "restart the locator if it's stuck waiting for a lost quorum"
      ui_section "Expect"
      ui_bullet "members rejoin; Orders recovers from disk"
      ui_bullet "$(ui_log "Configured redundancy of 2 copies has been restored")"
      ui_blank
      ui_field "MCP signals" "$(ui_tags redundancy membership)"
      ;;
    *) die "unknown failure '$1' (kill, stop, pause, isolate, locator-down, kill-majority, heal)";;
  esac
}

# Summary panel for the server picker: what that server is doing right now
server_info() {
  local s=$1 st health started m
  st=$(state "$s")
  [ "$st" = running ] && ! on_network "$s" && st=isolated
  case "$st" in
    running) ui_title safe "$s" "running" ;;
    missing) ui_title danger "$s" "no container" ;;
    *)       ui_title warn "$s" "$st" ;;
  esac
  if [ "$st" != missing ]; then
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "$(cid "$s")")
    started=$(docker inspect -f '{{.State.StartedAt}}' "$(cid "$s")" | cut -c1-19)
    ui_blank
    ui_field "Docker" "$health $(ui_dim "(started $started UTC)")"
  fi
  m=$(locator_get "/management/v1/members/$s" -m 2 2>/dev/null) || m=""
  if [ -n "$m" ]; then
    ui_field "GemFire" "$(jq -r '.result.groups[0].runtimeInfo[0] | "\(.status), \(.clientCount) clients, heap \(.heapUsage) MB"' <<<"$m")"
    ui_field "Regions" "$(jq -r '.result.groups[0].runtimeInfo[0].hostedRegions | join(", ")' <<<"$m")"
  else
    ui_field "GemFire" "$(ui_dim "not listed by the locator right now")"
  fi
  ui_blank
  ui_line "$(ui_dim "Only running servers can be broken; heal first otherwise.")"
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
server_ready() { locator_get "/management/v1/members/$1" 2>/dev/null | grep -q '"running":true'; }

wait_for_servers() {
  local s waiting start=$SECONDS restarted_locator=""
  printf '%sWaiting for the locator to list every server as back (a forced-out member waits 60s before reconnecting)...%s\n' "$c_dim" "$c_off"
  while :; do
    waiting=""
    if ! locator_get /management/v1/ping 2>/dev/null | grep -q pong; then
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
  # The list is coloured by risk too (fzf --ansi strips the colours from what it returns)
  what=$(printf '%s\n' "${ui_red}kill${ui_r}" "${ui_yel}stop${ui_r}" "${ui_yel}pause${ui_r}" "${ui_yel}isolate${ui_r}" \
                        "${ui_yel}locator-down${ui_r}" "${ui_red}kill-majority${ui_r}" "${ui_grn}heal${ui_r}" \
    | ui_fzf "make chaos" --height=70% --header "Break something (or heal). Now: $(status_line)" \
          --preview "$0 describe {1}") || exit 0
  case "$what" in
    kill|stop|pause|isolate)
      who=$(for s in $SERVERS; do printf '%s\t%s\n' "$s" "$(state "$s")"; done \
        | ui_fzf "make chaos $what" --height=50% --delimiter='\t' --header "$what which server?" \
              --preview "$0 server-info {1}" | cut -f1) || exit 0
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
  describe)                describe "$(ui_strip "${2:?describe what?}")" ;;
  server-info)             server_info "$(ui_strip "${2:?which server?}")" ;;
  kill|stop|pause|isolate) one_server "$1" "${2:-}" ;;
  locator-down)            locator_down ;;
  kill-majority)           kill_majority ;;
  heal)                    heal ;;
  *)                       describe "$1" ;;   # prints the "unknown failure" error
esac
