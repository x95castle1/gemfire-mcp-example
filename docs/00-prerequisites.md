# 00: Prerequisites & how the MCP server is shipped

## What you download

GemFire MCP 1.0 is **not** a Docker image. Broadcom ships two artifacts (see [vendor/README.md](../vendor/README.md)):

- `gemfire-mcp-server-<v>.jar`: a self-contained Spring Boot app. It doesn't need GemFire installed, and it doesn't need access to the members' disks.
- `gemfire-telemetry-forwarder-<v>.tar`: a small Java tool that runs next to the members, finds `.gfs` and `.log` files, and copies them to the store.

Both need **JDK 17+**. We'll wrap each one in our own small `eclipse-temurin:21-jre` image.

## Version matrix

| Thing | Version here | Why |
|---|---|---|
| GemFire | `10.3.4-jdk17` | MCP supports 10.2.x / 10.3.x. `list_members` only has live CPU, uptime and JVM pauses on **10.2.9+ / 10.3.3+** |
| MCP server / forwarder | 1.0.0 | released 2026-10-20 |
| JDK for our images | 21 | any JDK 17+ works |

Note: `~/dev/gemfire-runner` currently runs `10.2.3`, so in runner mode (chunk 13, optional) those three live metrics will be missing.

## Three ways in, one way out

| Data | Source | Path |
|---|---|---|
| Live membership, regions, health | Locator Management REST API (`/management/v1`) | MCP server → locator, on every tool call |
| Statistics history | Members' `.gfs` archives | member disk → forwarder → store → MCP server |
| Logs | Members' `.log` files | member disk → forwarder → store → MCP server (or Splunk) |

The only way out is **MCP over Streamable HTTP**: `POST http://<host>:8085/mcp`. There is no stdio or SSE transport.

## Settings that will bite you

- `SERVER_ADDRESS` defaults to `127.0.0.1`. Inside a container that means nobody can reach it, so we set it to `0.0.0.0`.
- An **unknown** `GF_MCP_*` variable stops startup. A typo in Compose means the container exits.
- `GF_TELEMETRY_STORE` is required even before the forwarder exists.
- Basic auth needs **both** the username and the password, or the server won't start.
