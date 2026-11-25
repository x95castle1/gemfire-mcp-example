#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Summary panels for the fzf menus in the Makefile (styling in scripts/ui.sh):
#   scripts/preview.sh load <scenario>    make load: what the scenario does + what it's running now
#   scripts/preview.sh logs <service>     make logs: container status + its last log lines
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
. "$ROOT/scripts/ui.sh"

WORKLOAD=http://localhost:18090

load_preview() {
  local p=$1
  case "$p" in
    steady)
      ui_title safe STEADY "the everyday baseline"
      ui_section "What it does"
      ui_bullet "~200 ops/s: 70% gets / 30% puts, 1 KB values over 10k keys"
      ui_bullet "Customers + Orders, plus a few reads of Products"
      ui_section "Where to see it"
      ui_bullet "MCP: $(ui_cmd "query_stat") with $(ui_tags put_rate get_rate put_latency)"
      ui_bullet "Grafana: $(ui_bold "Puts / s per member"), $(ui_bold "Operations / s")"
      ;;
    burst)
      ui_title warn BURST "a traffic spike"
      ui_section "What it does"
      ui_bullet "~3000 ops/s, same mix as steady (15× the baseline)"
      ui_section "Where to see it"
      ui_bullet "MCP: $(ui_cmd "find_stat_threshold_crossings") on $(ui_tags put_rate) finds the spike"
      ui_bullet "Grafana: the jump in $(ui_bold "Puts / s per member")"
      ui_line "$(ui_dim "Switch back with steady to get a clean start and end time.")"
      ;;
    hot-key)
      ui_title warn HOT-KEY "all the traffic on 5 keys"
      ui_section "What it does"
      ui_bullet "500 puts/s on keys hot-0 … hot-4 in Customers"
      ui_bullet "each key's bucket has one primary, so 1–2 servers do all the work"
      ui_section "Where to see it"
      ui_bullet "MCP: $(ui_cmd "query_stat") $(ui_tags put_rate) per server: lopsided"
      ui_bullet "Grafana: uneven lines in $(ui_bold "Puts / s per member")"
      ;;
    heap-hog)
      ui_title warn HEAP-HOG "fill the servers' heap until they refuse puts"
      ui_section "What it does"
      ui_bullet "new 512 KB values into Sessions (no redundancy), 40/s"
      ui_bullet "tenured heap passes eviction (75%) then critical (90%) in ~1 min"
      ui_section "Expect"
      ui_bullet "$(ui_log "above heap critical threshold"), then the workload's puts fail with $(ui_log "LowMemoryException")"
      ui_section "Where to see it"
      ui_bullet "MCP: $(ui_cmd "assess_cluster_health") heap checks; $(ui_cmd "search_logs") with $(ui_tags heap_pressure)"
      ui_bullet "Grafana: $(ui_bold "Tenured heap used") goes red; $(ui_bold "Errors / s") rejected_low_memory"
      ui_field "Undo" "$(ui_cmd "make load P=release-heap")"
      ;;
    release-heap)
      ui_title safe RELEASE-HEAP "undo heap-hog"
      ui_section "What it does"
      ui_bullet "removes every Sessions entry, then goes back to steady"
      ui_section "Expect"
      ui_bullet "servers keep refusing puts for a few minutes: removing entries only makes garbage"
      ui_bullet "heap drops once the garbage collector runs, then the servers accept puts again"
      ;;
    stop)
      ui_title safe STOP "no traffic"
      ui_section "What it does"
      ui_bullet "the workload keeps running but sends nothing: flat lines everywhere"
      ;;
    *)
      ui_title warn "$p"
      curl -fs -m 2 "$WORKLOAD/scenarios" | jq -r --arg p "$p" '.[$p] // empty'
      ;;
  esac
  local st
  st=$(curl -fs -m 2 "$WORKLOAD/status" 2>/dev/null) || st=""
  ui_blank
  if [ -n "$st" ]; then
    ui_field "Now running" "$(jq -r '"\(.scenario): \(.actualOpsPerSecond) ops/s, \(.rejectedAtCriticalHeap) rejected, \(.otherErrors) other errors"' <<<"$st")"
  else
    ui_field "Now running" "$(ui_dim "workload not reachable on :18090")"
  fi
}

logs_preview() {
  local s=$1
  local dc=(docker compose --profile '*')
  if [ "$s" = "(all)" ]; then
    ui_title safe "ALL CONTAINERS" "follow every log at once"
    ui_blank
    "${dc[@]}" ps -a --format '{{.Service}}\t{{.State}}\t{{.Status}}' 2>/dev/null | sort | while IFS=$'\t' read -r svc state status; do
      case "$state:$status" in
        running:*) c=$ui_grn ;; "exited:Exited (0)"*) c=$ui_d ;;   # a one-shot job that finished fine
        exited:*) c=$ui_red ;; *) c=$ui_yel ;;
      esac
      printf '  %s%-20s%s %s\n' "$c" "$svc" "$ui_r" "$(ui_dim "$status")"
    done
    return
  fi
  local line state status
  line=$("${dc[@]}" ps -a --format '{{.State}}\t{{.Status}}' "$s" 2>/dev/null | head -1)
  state=${line%%$'\t'*}; status=${line#*$'\t'}
  case "$state" in
    running) ui_title safe "$s" "$status" ;;
    "")      ui_title warn "$s" "not created (its profile isn't started)" ; return ;;
    exited)  case "$status" in "Exited (0)"*) ui_title safe "$s" "$status (a one-shot job that finished)" ;; *) ui_title danger "$s" "$status" ;; esac ;;
    *)       ui_title warn "$s" "$status" ;;
  esac
  ui_section "Last log lines"
  "${dc[@]}" logs --no-log-prefix --tail 8 "$s" 2>&1 | cut -c1-220 | ui_colorize_log | sed 's/^/  /'
  ui_blank
  ui_line "$(ui_dim "ENTER follows it live (Ctrl-C to stop).")"
}

case "${1:-}" in
  load) load_preview "$(ui_strip "${2:?scenario}")" ;;
  logs) logs_preview "$(ui_strip "${2:?service}")" ;;
  *) echo "usage: $0 load <scenario> | logs <service>" >&2; exit 2 ;;
esac
