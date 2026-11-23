#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Speak MCP by hand: JSON-RPC 2.0 over Streamable HTTP, with nothing but curl + jq.
#
#   scripts/mcp-curl.sh init                          # just the handshake
#   scripts/mcp-curl.sh tools                         # tools/list  -> name + first line of description
#   scripts/mcp-curl.sh tool <name>                   # tools/list  -> one tool's full definition (inputSchema!)
#   scripts/mcp-curl.sh call <tool> ['<json args>']   # tools/call
#   scripts/mcp-curl.sh resources                     # resources/list
#   scripts/mcp-curl.sh read <uri>                    # resources/read, e.g. gemfire://stat-signals
#
#   VERBOSE=1 scripts/mcp-curl.sh ...   also prints HTTP headers and raw response bodies
#   MCP_URL=http://host:8085/mcp        target another server (default http://localhost:8085/mcp)
#
# Every run is one complete MCP session:
#   1. POST initialize                 -> server returns capabilities + an Mcp-Session-Id header
#   2. POST notifications/initialized  -> a notification (no "id"), so no JSON-RPC reply: HTTP 202
#   3. POST <your request>             -> must carry Mcp-Session-Id + MCP-Protocol-Version headers
#   4. DELETE /mcp                     -> politely end the session
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$ROOT/.env" ] && { set -a; . "$ROOT/.env"; set +a; }

MCP_URL="${MCP_URL:-http://localhost:8085/mcp}"
VERBOSE="${VERBOSE:-0}"
: "${GF_MCP_AUTH_BASIC_USERNAME:?set in .env}" "${GF_MCP_AUTH_BASIC_PASSWORD:?set in .env}"
AUTH="Basic $(printf '%s:%s' "$GF_MCP_AUTH_BASIC_USERNAME" "$GF_MCP_AUTH_BASIC_PASSWORD" | base64 | tr -d '\r\n')"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SESSION=""; PROTO=""
echo 1 >"$TMP/next_id"   # a file, not a variable: request() runs inside $(...) subshells

c_dim=$'\e[2m'; c_out=$'\e[36m'; c_in=$'\e[32m'; c_err=$'\e[31m'; c_off=$'\e[0m'
step() { printf '\n%s── %s%s\n' "$c_dim" "$*" "$c_off" >&2; }

# POST one JSON-RPC message. Prints the JSON-RPC response (if any) on stdout.
rpc() {
  local body="$1"
  printf '%s→ %s%s\n' "$c_out" "$(jq -c . <<<"$body")" "$c_off" >&2
  local hdr=(-H "Content-Type: application/json"
             -H "Accept: application/json, text/event-stream"   # Streamable HTTP: server may answer either way
             -H "Authorization: $AUTH")
  [ -n "$SESSION" ] && hdr+=(-H "Mcp-Session-Id: $SESSION")
  [ -n "$PROTO" ]   && hdr+=(-H "MCP-Protocol-Version: $PROTO")

  local code
  code=$(curl -sS -X POST "$MCP_URL" "${hdr[@]}" --data "$body" \
              -D "$TMP/headers" -o "$TMP/body" -w '%{http_code}')
  if [ "$VERBOSE" = 1 ]; then
    printf '%s' "$c_dim" >&2; tr -d '\r' <"$TMP/headers" >&2; cat "$TMP/body" >&2; printf '%s\n' "$c_off" >&2
  fi
  printf '%s← HTTP %s%s\n' "$c_in" "$code" "$c_off" >&2
  case "$code" in 2??) ;; *)  # show just the error message, not the server's stack trace
    printf '%s%s%s\n' "$c_err" "$(jq -c '.jsonRpcError // .error // .' "$TMP/body" 2>/dev/null || head -c 400 "$TMP/body")" "$c_off" >&2
    exit 1;; esac

  # A JSON response is plain JSON; an SSE response wraps it in "data: {...}" lines.
  if grep -qi '^content-type: *text/event-stream' "$TMP/headers"; then
    sed -n 's/^data: *//p' "$TMP/body"
  else
    cat "$TMP/body"
  fi
}

request() {  # request <method> [params-json]
  # JSON-RPC ids must be unique within a session; the server echoes the id back on the reply
  local id params="${2:-}"; id=$(cat "$TMP/next_id"); echo $((id + 1)) >"$TMP/next_id"
  [ -z "$params" ] && params='{}'
  rpc "$(jq -nc --argjson id "$id" --arg m "$1" --argjson p "$params" \
          '{jsonrpc:"2.0", id:$id, method:$m, params:$p}')"
}

open_session() {
  step "1. initialize  (client says who it is + which protocol version it speaks)"
  local res
  res=$(request initialize '{
    "protocolVersion": "2025-06-18",
    "capabilities": {},
    "clientInfo": {"name": "mcp-curl.sh", "version": "0.1"}
  }')
  SESSION=$(tr -d '\r' <"$TMP/headers" | awk -F': *' 'tolower($1)=="mcp-session-id"{print $2}')
  PROTO=$(jq -r '.result.protocolVersion' <<<"$res")
  printf '%s  server:   %s\n  protocol: %s\n  session:  %s\n  capabilities: %s%s\n' "$c_in" \
    "$(jq -c '.result.serverInfo' <<<"$res")" "$PROTO" "${SESSION:-<none>}" \
    "$(jq -c '.result.capabilities | keys' <<<"$res")" "$c_off" >&2
  if [ -n "$(jq -r '.result.instructions // empty' <<<"$res")" ]; then
    printf '%s  instructions (sent to the model):%s\n%s\n' "$c_in" "$c_off" "$(jq -r '.result.instructions' <<<"$res" | sed 's/^/    /')" >&2
  fi

  step "2. notifications/initialized  (a notification: no id, so no reply -- expect HTTP 202)"
  rpc '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
}

close_session() {
  [ -z "$SESSION" ] && return
  step "4. DELETE /mcp  (end the session)"
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$MCP_URL" \
              -H "Authorization: $AUTH" -H "Mcp-Session-Id: $SESSION" -H "MCP-Protocol-Version: $PROTO")
  printf '%s← HTTP %s%s\n' "$c_in" "$code" "$c_off" >&2
}

# Tool results come back as content blocks; the text block is usually JSON -> pretty-print it.
show_tool_result() {
  local res="$1"
  if [ "$(jq -r '.error // empty' <<<"$res")" ]; then jq '.error' <<<"$res"; return; fi
  [ "$(jq -r '.result.isError' <<<"$res")" = "true" ] && printf '%sisError: true (the tool ran but failed)%s\n' "$c_err" "$c_off" >&2
  jq -r '.result.content[] | select(.type=="text") | .text' <<<"$res" | while IFS= read -r line; do
    jq . <<<"$line" 2>/dev/null || printf '%s\n' "$line"
  done
  jq -e '.result.structuredContent' <<<"$res" >/dev/null 2>&1 && printf '%s(also returned structuredContent)%s\n' "$c_dim" "$c_off" >&2
  return 0
}

cmd="${1:-tools}"; shift || true
open_session
case "$cmd" in
  init) ;;
  tools)
    step "3. tools/list"
    request tools/list | jq -r '.result.tools[] | "\(.name)\t\(.description | split("\n")[0] | .[0:110])"' | column -t -s $'\t'
    ;;
  tool)
    step "3. tools/list  (showing just '$1')"
    request tools/list | jq --arg n "$1" '.result.tools[] | select(.name==$n)'
    ;;
  call)
    tool="${1:?usage: call <tool> ['<json args>']}"; args="${2:-}"; [ -z "$args" ] && args='{}'
    step "3. tools/call $tool"
    show_tool_result "$(request tools/call "$(jq -nc --arg n "$tool" --argjson a "$args" '{name:$n, arguments:$a}')")"
    ;;
  resources)
    step "3. resources/list"
    request resources/list | jq '.result.resources'
    ;;
  read)
    step "3. resources/read ${1:?usage: read <uri>}"
    request resources/read "$(jq -nc --arg u "$1" '{uri:$u}')" | jq -r '.result.contents[] | .text // .'
    ;;
  *) echo "unknown command: $cmd" >&2; exit 2;;
esac
close_session
