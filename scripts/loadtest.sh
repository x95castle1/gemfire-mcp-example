#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Run a k6 load test against the workload app (chunk 11).
#
#   scripts/loadtest.sh pick            # fzf: pick a test from k6/*.js (the preview is its header)
#   scripts/loadtest.sh <name>          # e.g. spike, ramp, soak, hot-key, breakpoint
#   DURATION=30m scripts/loadtest.sh soak
#   TARGET=60000 DURATION=15m scripts/loadtest.sh breakpoint
#
# What a run does:
#   1. pauses the workload's background traffic (scenario "stop"), so k6's numbers are only k6's
#   2. appends "<UTC>  start <name>" to data/load.log: ground truth for "when did the spike start?"
#   3. runs k6 in a container: requests go to the workload's /ops/* endpoints (real GemFire calls),
#      metrics go to Prometheus if it's up, the HTML report to data/loadtest/<UTC>-<name>.html
#   4. appends "<UTC>  end <name> passed|failed|..." and puts the background scenario back
#      (also when you press Ctrl-C)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
. "$ROOT/scripts/ui.sh"

WORKLOAD=http://localhost:18090
LOAD_LOG="$ROOT/data/load.log"

c_cmd=$'\e[33m'; c_dim=$'\e[2m'; c_ok=$'\e[32m'; c_err=$'\e[31m'; c_off=$'\e[0m'
[ -n "${NO_COLOR:-}" ] && c_cmd='' c_dim='' c_ok='' c_err='' c_off=''
run()  { printf '%s$ %s%s\n' "$c_cmd" "$*" "$c_off"; "$@"; }
die()  { printf '%s%s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }
now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }

record() {
  mkdir -p "$(dirname "$LOAD_LOG")"
  printf '%s  %s\n' "$(now)" "$*" >>"$LOAD_LOG"
  printf '%srecorded in data/load.log: %s%s\n' "$c_dim" "$*" "$c_off"
}

tests() { for f in k6/*.js; do n=$(basename "$f" .js); [ "$n" = lib ] || echo "$n"; done; }

ensure_workload() {
  curl -fs -o /dev/null "$WORKLOAD/actuator/health" && return
  echo "Starting the workload app (the k6 endpoints live there)..."
  run docker compose --profile workload up -d --build --wait workload
}

PREV=""
restore() {
  # A Ctrl-C can stop the docker CLI while the k6 container keeps going: make sure no test is left running
  local left
  left=$(docker ps -q --filter label=com.docker.compose.project=gfmcp --filter label=com.docker.compose.service=k6)
  if [ -n "$left" ]; then
    printf '%sstopping the k6 container that was still running%s\n' "$c_dim" "$c_off"
    docker stop $left >/dev/null
  fi
  if [ -n "$PREV" ] && [ "$PREV" != stop ]; then
    curl -fsS -o /dev/null -X POST "$WORKLOAD/scenario/$PREV" && printf '%sbackground traffic back to: %s%s\n' "$c_ok" "$PREV" "$c_off"
  fi
}

run_test() {
  local name=$1
  [ -f "k6/$name.js" ] || die "no such test '$name'. Tests: $(tests | paste -sd' ' -)"
  ensure_workload

  # 1. pause the background traffic, and make sure it comes back however we exit.
  # PREV is global on purpose: the EXIT trap runs after this function has returned.
  PREV=$(curl -fs "$WORKLOAD/status" | jq -r .scenario)
  trap restore EXIT
  # A handler (not an ignore) for Ctrl-C: k6 still gets it and stops, then we carry on here
  trap ':' INT
  if [ "$PREV" != stop ]; then
    printf '%spausing the background traffic (was: %s)%s\n' "$c_dim" "$PREV" "$c_off"
    run curl -fsS -o /dev/null -X POST "$WORKLOAD/scenario/stop"
  fi

  # 2. where the results go
  local stamp report out=()
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  report="data/loadtest/$stamp-$name.html"
  if curl -fs -o /dev/null http://localhost:19090/-/ready; then
    out=(-o experimental-prometheus-rw)
  else
    printf '%sPrometheus isn'"'"'t running: no Grafana panels for this run (make grafana-ui first to get them).%s\n' "$c_err" "$c_off"
  fi
  printf '%slive k6 dashboard while it runs: http://localhost:5665%s\n' "$c_dim" "$c_off"

  # 3. run it
  record "start  $name"
  local rc
  set +e
  run docker compose --profile workload --profile loadtest run --rm --service-ports \
      -e K6_WEB_DASHBOARD_EXPORT="/reports/$stamp-$name.html" -e DURATION="${DURATION:-}" -e TARGET="${TARGET:-}" \
      k6 run ${out[@]+"${out[@]}"} "/scripts/$name.js"
  rc=$?
  set -e

  # 4. how it went (k6 exit codes: 0 ok, 99 thresholds crossed, 105 stopped early; 130 = Ctrl-C)
  local result
  case "$rc" in
    0)       result=passed ;;
    99)      result="failed (thresholds crossed)" ;;
    105|130) result=interrupted ;;
    *)       result="error (k6 exit $rc)" ;;
  esac
  record "end    $name  $result"
  [ -f "$report" ] && printf '%sHTML report: %s%s\n' "$c_ok" "$report" "$c_off"
  case "$result" in passed) return 0 ;; *) return 1 ;; esac
}

pick() {
  command -v fzf >/dev/null || die "fzf not found (brew install fzf), or run: make select-load-test T=spike"
  local name
  name=$(tests | ui_fzf "make select-load-test" --height=70% --header "Pick a k6 load test (the background traffic is paused while it runs)" \
           --preview "scripts/preview.sh loadtest {1}") || exit 0
  run_test "$name"
}

case "${1:-pick}" in
  pick) pick ;;
  -h|--help) sed -n '2,18p' "$0" ;;
  *)    run_test "$1" ;;
esac
