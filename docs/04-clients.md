# 04: Real MCP clients: MCP Inspector and Claude Code

So far *you* were the MCP client (`make tools`, `make call`). Now two real clients talk to the same `http://localhost:8085/mcp`:

| Client | Who decides which tool to call? | Good for |
|---|---|---|
| **MCP Inspector** | you, by clicking | seeing every JSON-RPC message; debugging a server |
| **Claude Code** | the model, from the tool descriptions | seeing how an LLM actually uses the tools |

Auth is **admin/admin** everywhere in this lab: the header is `Authorization: Basic YWRtaW46YWRtaW4=` (`printf 'admin:admin' | base64`).

## MCP Inspector

```bash
make start        # the MCP server must be running
make inspector    # starts the container and opens http://localhost:6274?MCP_INSPECTOR_API_TOKEN=...
```

The container starts **already pointed at our server** (see `compose.yaml`):

```
mcp-inspector --web --transport http --server-url http://mcp-server:8085/mcp \
              --header "Authorization: Basic YWRtaW46YWRtaW4="
```

Click **Connect**, then:

| Inspector tab | MCP method underneath | Same as |
|---|---|---|
| Tools → List | `tools/list` | `make tools` |
| Tools → pick `list_members` → Run | `tools/call` | `make call T=list_members` |
| Resources → `gemfire://stat-signals` | `resources/read` | `scripts/mcp-curl.sh read gemfire://stat-signals` |
| History / notifications pane | every JSON-RPC request and response | the `→` / `←` lines `mcp-curl.sh` prints |

Notes:
- **The token in the URL.** Inspector makes a new auth token on every start and prints it in its log; `make inspector` reads it from there. The token stops *other web pages* from driving your Inspector. It is not real access control.
- **Who connects?** The URL is `mcp-server:8085` (a Docker network name) because Inspector's own backend, inside the container, makes the MCP connection, not your browser.
- **There's a CLI mode too**, handy for scripts:
  ```bash
  docker run --rm --network gfmcp ghcr.io/modelcontextprotocol/inspector:2.16.0 --cli \
    http://mcp-server:8085/mcp --header 'Authorization: Basic YWRtaW46YWRtaW4=' \
    --method tools/call --tool-name list_members --tool-arg role=servers
  ```

## Claude Code

`.mcp.json` (committed) was created with:

```bash
claude mcp add --transport http --scope project gemfire http://localhost:8085/mcp \
  --header "Authorization: Basic YWRtaW46YWRtaW4="
```

`--scope project` writes the server into `.mcp.json` in the repo, so anyone who clones it gets the same server. (`--scope user` would put it in your personal config instead.)

**Since chunk 10**, `.mcp.json` doesn't hold a fixed header any more. It has `"headersHelper": "scripts/mcp-token.sh --headers"`, a command Claude Code runs on every connect. It prints Basic admin/admin with security off, and a fresh Keycloak token with it on. The URL is `${GF_MCP_PUBLIC_URL:-http://localhost:8085/mcp}` (https with security on: see [docs/10](10-security.md)). Changing `.mcp.json` means approving `gemfire` once more.

**First run:** start `claude` in this folder. It asks whether to trust the project's MCP servers, because a repo could otherwise point your Claude at anything. Approve `gemfire` once. Check with:

```bash
claude mcp list            # gemfire: http://localhost:8085/mcp - ✓ Connected
/mcp                       # inside a session: server status + its 11 tools
```

Inside Claude Code the tools are named **`mcp__gemfire__<tool>`**, e.g. `mcp__gemfire__list_members`.

### What actually happens when you ask a question

We ran a one-shot test and recorded every step:

```bash
claude -p "Using only the gemfire MCP tools: how many servers are in the cluster, and is the cluster healthy?" \
  --mcp-config .mcp.json --strict-mcp-config --allowedTools "mcp__gemfire__*" \
  --output-format stream-json --verbose
```

Tool calls, in order:

```
ToolSearch                            {"query":"select:mcp__gemfire__list_members,mcp__gemfire__assess_cluster_health"}
mcp__gemfire__list_members            {"role":"servers"}
mcp__gemfire__assess_cluster_health   {}
```

1. **`ToolSearch` first.** Claude Code doesn't load every MCP tool's full schema up front. It sees the tool *names*, then loads the schemas it needs. This keeps the context small when you have many MCP servers.
2. **It picked arguments from the schema**: `role: "servers"`, the same enum value you'd pick in `make call`.
3. **It noticed something unprompted:** "server-3 has a second stats archive that starts at 20:40, which may mean it restarted". That was our stop/start test in chunk 7. It read that from the `stored` block of `list_members`, and it said it hadn't confirmed the restart instead of claiming it as fact.

### Permissions

Claude Code asks before running a tool unless you allow it. All 11 GemFire tools have `readOnlyHint: true` (see `make call` → the preview), so they're safe to allow:
- per session: answer "Yes, and don't ask again"
- or in `.claude/settings.json`: `"permissions": {"allow": ["mcp__gemfire__*"]}`

### Prompts to try (each pulls in different tools)

| Ask | Expect it to use |
|---|---|
| "Is my GemFire cluster healthy?" | `assess_cluster_health` |
| "What happened to server-3 in the last hour?" | `get_membership_timeline`, maybe `collect_member_departure_evidence` |
| "Show heap usage for server-1 over the last 30 minutes" | `query_stat` with `signal: heap_used` |
| "Any warnings in the logs in the last 15 minutes?" | `search_logs` with a time window + `min_severity` |
| "Which regions have no redundancy?" | `list_regions` / `get_partition_region_health` |

**Exercise:** ask one of these, then do the same thing yourself with `make call`. Did Claude choose the same tool and arguments? Did it need more than one call? Where did the tool *descriptions* steer it?
