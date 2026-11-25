#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Speak MCP by hand: JSON-RPC 2.0 over Streamable HTTP, with nothing but curl + jq.
#
#   scripts/mcp-curl.sh init                          # just the handshake
#   scripts/mcp-curl.sh tools                         # tools/list  -> name + first line of description
#   scripts/mcp-curl.sh tool <name>                   # tools/list  -> one tool's full definition (inputSchema!)
#   scripts/mcp-curl.sh call <tool> ['<json args>']   # tools/call
#   scripts/mcp-curl.sh pick                          # fzf menu: pick a tool, fill args from its inputSchema, call it
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
. "$ROOT/scripts/ui.sh"
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

# ── pick: interactive tools/call built from the tool's own inputSchema (needs fzf) ──
# This is roughly what an AI client does: read the schema, then produce arguments that fit it.
# The difference is that here YOU are the model.

# fzf preview of one tool: what the LLM reads when deciding whether and how to call it
# Colours for the jq previews below (empty strings when NO_COLOR is set; see scripts/ui.sh)
jq -n --arg b "$ui_b" --arg d "$ui_d" --arg r "$ui_r" --arg red "$ui_red" --arg yel "$ui_yel" --arg grn "$ui_grn" \
      --arg mag "$ui_mag" --arg cyn "$ui_cyn" '$ARGS.named' >"$TMP/colors.json"

# fzf preview of one tool: what the LLM reads when deciding whether and how to call it.
# Heading green for a read-only tool (annotations.readOnlyHint), yellow otherwise.
cat >"$TMP/preview.jq" <<'JQ'
$c[0] as $c |
.result.tools[] | select(.name == $n) |
(if (.annotations.readOnlyHint // false) then [$c.grn, "read-only"] else [$c.yel, "may change things"] end) as $risk |
"\($c.b)\($risk[0])\(.name)\($c.r)  \($c.d)\(.title // "") · \($risk[1])\($c.r)",
"",
.description,
"",
"\($c.b)\($c.mag)Arguments\($c.r)  \($c.red)*\($c.r) = required",
( (.inputSchema.required // []) as $req | (.inputSchema.properties // {}) | to_entries[] | . as $e |
  "  \(if ($req | index($e.key)) then "\($c.red)*\($c.r)" else " " end) \($c.b)\($e.key)\($c.r)  \($c.d)(\($e.value.type)\(if $e.value.items then " of \($e.value.items.type)" else "" end))\($c.r)" +
  (if $e.value.enum then "\n      one of: " + ($e.value.enum | map("\($c.cyn)\(.)\($c.r)") | join("  ")) else "" end) +
  "\n      \($e.value.description // "")" )
JQ

# fzf preview of one argument
cat >"$TMP/arg.jq" <<'JQ'
$c[0] as $c |
.properties[$k] |
"\($c.b)\($c.grn)\($k)\($c.r)  \($c.d)\(.type)\(if .items then " of \(.items.type)" else "" end)\($c.r)",
(if .enum then "\n\($c.b)\($c.mag)One of\($c.r)\n  " + (.enum | map("\($c.cyn)\(.)\($c.r)") | join("  ")) else empty end),
"\n\($c.b)\($c.mag)What it means\($c.r)\n\(.description // "")"
JQ

tty_read() {  # tty_read <prompt> -> prints what the user typed
  local v; printf '%s' "$1" >/dev/tty; IFS= read -r v </dev/tty || true; printf '%s' "$v"
}

member_names() {  # current members, fetched with a real tools/call (watch it go by on stderr)
  [ -f "$TMP/members" ] || request tools/call '{"name":"list_members","arguments":{}}' \
    | jq -r '.result.content[0].text | fromjson | .members[].name' >"$TMP/members"
  cat "$TMP/members"
}

build_args() {  # build_args <tool> -> prints the arguments JSON object
  local tool="$1" schema required optional chosen key type enum val args='{}'
  schema=$(jq -c --arg n "$tool" '.result.tools[] | select(.name==$n) | .inputSchema' "$TMP/tools.json")
  printf '%s' "$schema" >"$TMP/schema.json"
  required=$(jq -r '.required // [] | .[]' <<<"$schema")
  optional=$(jq -r '(.required // []) as $r | .properties // {} | keys[] | select(. as $k | $r | index($k) | not)' <<<"$schema")

  chosen=""
  if [ -n "$optional" ]; then
    chosen=$(printf '%s\n' "$optional" | ui_fzf "make call $tool" --multi --height=60% \
      --header "Optional arguments for $tool: TAB to select, ENTER to continue (select none = server defaults)" \
      --preview "jq -r --arg k {1} --slurpfile c '$TMP/colors.json' -f '$TMP/arg.jq' '$TMP/schema.json'") || true
  fi

  for key in $required $chosen; do
    type=$(jq -r --arg k "$key" '.properties[$k].type' <<<"$schema")
    enum=$(jq -r --arg k "$key" '.properties[$k].enum // [] | .[]' <<<"$schema")
    if [ -n "$enum" ]; then
      val=$(printf '%s\n' "$enum" | ui_fzf "make call $tool" --height=50% --header "$key ($tool)" \
            --bind="focus:transform-preview-label:echo ' $key = {1} '" \
            --preview "jq -r --arg k '$key' --slurpfile c '$TMP/colors.json' -f '$TMP/arg.jq' '$TMP/schema.json'") || true
    elif [ "$key" = member_name ]; then
      # ENTER on no match uses what you typed: stats/log tools also accept members that have LEFT
      val=$(member_names | fzf --height=40% --reverse --bind 'enter:accept-or-print-query' \
            --header "member_name: pick one, or type a departed member's name") || true
    elif [ "$key" = member_names ]; then
      val=$(member_names | fzf --multi --height=40% --reverse --header "member_names: TAB to select several" | paste -sd, -) || true
    else
      case "$key" in start|end|around|until)
        printf '%s  time: ISO-8601 UTC. now=%s  1h ago=%s%s\n' "$c_dim" "$(date -u +%FT%TZ)" \
          "$(date -u -v-1H +%FT%TZ 2>/dev/null || date -u -d '-1 hour' +%FT%TZ)" "$c_off" >/dev/tty ;;
      esac
      val=$(tty_read "$key ($type): ")
    fi
    [ -z "$val" ] && { printf '%s  (skipped %s)%s\n' "$c_dim" "$key" "$c_off" >/dev/tty; continue; }
    case "$type" in
      integer|number) args=$(jq -c --arg k "$key" --argjson v "$val" '. + {($k): $v}' <<<"$args") ;;
      array)          args=$(jq -c --arg k "$key" --arg v "$val" '. + {($k): ($v | split(",") | map(gsub("^ +| +$"; "")))}' <<<"$args") ;;
      *)              args=$(jq -c --arg k "$key" --arg v "$val" '. + {($k): $v}' <<<"$args") ;;
    esac
  done
  printf '%s' "$args"
}

cmd="${1:-tools}"; shift || true
[ "$cmd" = pick ] && ! command -v fzf >/dev/null && { echo "pick needs fzf: brew install fzf" >&2; exit 2; }
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
  pick)
    step "3. tools/list  (to build the menu)"
    request tools/list >"$TMP/tools.json"
    # Only the title column is coloured: {1} (the tool name) must stay plain for the preview's jq lookup
    tool=$(jq -r --arg d "$ui_d" --arg r "$ui_r" '.result.tools[] | "\(.name)\t\($d)\(.title // "")\($r)"' "$TMP/tools.json" \
      | ui_fzf "make call" --height=80% --delimiter=$'\t' --with-nth=1,2 \
            --header "Pick a tool (the preview is what the AI model reads)" \
            --preview "jq -r --arg n {1} --slurpfile c '$TMP/colors.json' -f '$TMP/preview.jq' '$TMP/tools.json'" \
            | cut -f1) || true
    if [ -n "$tool" ]; then
      args=$(build_args "$tool")
      step "3b. tools/call $tool"
      show_tool_result "$(request tools/call "$(jq -nc --arg n "$tool" --argjson a "$args" '{name:$n, arguments:$a}')")"
      printf '\n%sRe-run without the menu:  make call T=%s A='"'"'%s'"'"'%s\n' "$c_in" "$tool" "$args" "$c_off" >&2
    fi
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
