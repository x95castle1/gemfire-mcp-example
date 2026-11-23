# vendor/

Put the licensed GemFire MCP artifacts here. Everything in this folder except this README is gitignored.

1. Sign in at https://support.broadcom.com, find **Tanzu GemFire MCP Server** 1.0.0, and accept the Terms and Conditions.
2. Download both files into this folder:

| File | What it is | Used by |
|---|---|---|
| `gemfire-mcp-server-1.0.0.jar` | Self-contained executable Spring Boot JAR: the MCP server | `docker/mcp-server` (chunk 2) |
| `gemfire-telemetry-forwarder-1.0.0.tar` | Unpacks to `bin/` + `lib/`: ships `.gfs` + `.log` files to the telemetry store | `docker/telemetry-forwarder` (chunk 4) |

Check:

```bash
ls -l vendor/
```
