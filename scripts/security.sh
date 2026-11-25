# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# Chunk 10: the one place scripts ask "is security on?" and "how do I reach X in this mode?".
# Source it:  . "$ROOT/scripts/security.sh"
#
# Security is on when compose.security.yaml is in COMPOSE_FILE (the shell's, else the line in .env),
# the same switch docker compose itself reads.
# ─────────────────────────────────────────────────────────────────────────────

_sec_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

sec_on() {
  local cf=${COMPOSE_FILE:-}
  [ -n "$cf" ] || cf=$(sed -n 's/^COMPOSE_FILE=//p' "$_sec_root/.env" 2>/dev/null | tail -1)
  case "$cf" in *compose.security.yaml*) return 0 ;; *) return 1 ;; esac
}

# ── 10c: with security on, everything answers https with a certificate from the lab CA ───────
# SEC_CURL = the curl options that make curl trust it (empty when security is off)
CA_PEM="$_sec_root/data/certs/ca.pem"
if sec_on; then
  SCHEME=https; SEC_CURL=(--cacert "$CA_PEM")
else
  SCHEME=http;  SEC_CURL=()
fi
MCP_PUBLIC_URL="$SCHEME://localhost:8085/mcp"

# The locator's Management REST API, as the read-only user "monitor". GemFire ignores the
# credentials while security is off, so they're always sent.
LOCATOR_URL=$SCHEME://localhost:17070
locator_get() {   # locator_get <path> [more curl options]
  local path=$1; shift
  curl -fs -u monitor:monitor ${SEC_CURL[@]+"${SEC_CURL[@]}"} "$@" "$LOCATOR_URL$path"
}

# ── 10b: tokens for the MCP front door ───────────────────────────────────────
# Keycloak at the one name that works inside Docker and on the Mac (see compose.security.yaml).
KEYCLOAK_URL=$SCHEME://keycloak.localhost:18180
TOKEN_URL=$KEYCLOAK_URL/realms/gfmcp/protocol/openid-connect/token

# mcp_client <short name>: lab-cli (default) or viewer -> the Keycloak client id
mcp_client() { case "${1:-}" in ""|cli|lab-cli) echo lab-cli ;; viewer|lab-viewer) echo lab-viewer ;; *) echo "$1" ;; esac; }

# A token for a client-credentials client (its lab secret is "<client>-secret", see gfmcp-realm.json)
mcp_token() {
  local c; c=$(mcp_client "${1:-}")
  curl -fsS ${SEC_CURL[@]+"${SEC_CURL[@]}"} -u "$c:$c-secret" -d grant_type=client_credentials "$TOKEN_URL" | jq -er .access_token
}

# The Authorization header VALUE for the MCP server in the current mode:
#   security off -> Basic, from GF_MCP_AUTH_BASIC_* in .env (admin/admin)
#   security on  -> Bearer <a fresh token from Keycloak>
mcp_auth() {
  if sec_on; then
    printf 'Bearer %s' "$(mcp_token "${1:-}")"
  else
    local u p
    u=$(sed -n 's/^GF_MCP_AUTH_BASIC_USERNAME=//p' "$_sec_root/.env" 2>/dev/null | tail -1)
    p=$(sed -n 's/^GF_MCP_AUTH_BASIC_PASSWORD=//p' "$_sec_root/.env" 2>/dev/null | tail -1)
    printf 'Basic %s' "$(printf '%s:%s' "${u:-admin}" "${p:-admin}" | base64 | tr -d '\r\n')"
  fi
}

# The claims inside a JWT (its middle part, base64url), for reading, not for trusting
jwt_claims() {
  local p; p=$(cut -d. -f2 <<<"$1" | tr '_-' '/+')
  while [ $(( ${#p} % 4 )) -ne 0 ]; do p="$p="; done
  base64 -d <<<"$p" 2>/dev/null || base64 -D <<<"$p"
}

# ── Switching modes: `make start` runs `scripts/security.sh guard` first ─────
# GemFire's cluster configuration (kept by the locator in data/gemfire/locator/ConfigDiskDir_locator and
# handed to every server that joins) RECORDS the security-manager while the locator runs secured, and
# keeps it after security is switched off. Servers then still load ExampleSecurityManager, can't find
# security.json, and exit ("The security-manager configuration attribute can not be modified").
# So when the mode changes, the cluster configuration is reset; gemfire-init recreates the regions, and
# the Orders data is safe in the servers' own disk stores.
sec_guard() {
  local mode=off last marker="$_sec_root/data/.security-mode" cc="$_sec_root/data/gemfire/locator/ConfigDiskDir_locator"
  sec_on && mode=on
  last=$(cat "$marker" 2>/dev/null || true)
  if [ -n "$last" ] && [ "$last" != "$mode" ]; then
    if [ -n "$(docker ps -q --filter label=com.docker.compose.project=gfmcp --filter label=com.docker.compose.service=locator)" ]; then
      echo "Security was switched ($last -> $mode) while the cluster is running: every member must switch together." >&2
      echo "Run: make stop && make start" >&2
      return 1
    fi
    if [ -d "$cc" ]; then
      echo "Security switched $last -> $mode: resetting GemFire's cluster configuration (it remembers the security-manager)."
      echo "  rm -rf data/gemfire/locator/ConfigDiskDir_locator   (gemfire-init recreates the regions; see docs/10-security.md)"
      rm -rf "$cc"
    fi
  fi
  mkdir -p "$_sec_root/data"
  echo "$mode" >"$marker"
  echo "Security: $mode"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    guard) sec_guard ;;
    *) echo "usage: scripts/security.sh guard   (otherwise: source it)" >&2; exit 2 ;;
  esac
fi
