#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Chunk 10b: credentials for the GemFire MCP server, in whatever mode the lab is in.
#
#   scripts/mcp-token.sh [viewer]            the Authorization header value (Basic ... or Bearer ...)
#   scripts/mcp-token.sh --claims [viewer]   what's inside the token (security on only)
#   scripts/mcp-token.sh --headers           {"Authorization": "..."}: Claude Code's headersHelper (.mcp.json)
#   eval "$(scripts/mcp-token.sh --env)"     before starting `claude`: the https URL + the lab CA for Node
#
# Security on: a client-credentials token from Keycloak, as lab-cli (read + logs) or lab-viewer (read only).
# Security off: Basic admin/admin, like before.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/security.sh"

case "${1:-}" in
  --headers) jq -n --arg a "$(mcp_auth "${2:-}")" '{Authorization: $a}' ;;
  --claims)
    sec_on || { echo "security is off: no token, just Basic admin/admin" >&2; exit 1; }
    jwt_claims "$(mcp_token "${2:-}")" | jq '{iss, aud, azp, sub, preferred_username, scope, exp: (.exp | todate)}' ;;
  --env)
    # Claude Code reads GF_MCP_PUBLIC_URL in .mcp.json; Node only trusts extra CAs given at startup
    printf 'export GF_MCP_PUBLIC_URL=%q\n' "$MCP_PUBLIC_URL"
    if sec_on; then printf 'export NODE_EXTRA_CA_CERTS=%q\n' "$CA_PEM"; else echo 'unset NODE_EXTRA_CA_CERTS'; fi ;;
  -h|--help) sed -n '3,12p' "$0" ;;
  *) mcp_auth "${1:-}"; echo ;;
esac
