# 09: The SRE assistant, our own MCP client

```bash
make sre            # builds and starts it, opens http://localhost:18080
```

Until now other people's clients talked to the GemFire MCP server: curl (`make call`), MCP Inspector, Claude Code. This chunk is **our own client**: a Spring Boot app (`sre-assistant/`) that connects to the MCP server, gives its 11 tools to a model, runs the tool-calling loop, and shows every step live in the browser. The model is picked **per question**: Claude, or Qwen running locally on Ollama, so you can ask both the same thing and compare.

## Setup

| For | You need | Check |
|---|---|---|
| Claude | `ANTHROPIC_API_KEY=...` in `.env` (from console.anthropic.com → API keys), then `make sre` | the "claude" chip in the page header turns green |
| Qwen | Ollama on your Mac: `brew install ollama`, start it (the app, or `ollama serve`), `ollama pull qwen3:14b` (~9 GB) | the "qwen" chip turns green; `curl localhost:11434/api/tags` lists the model |

Claude Code's own login can't be reused by an app; the assistant needs its own API key. Models can be changed in `.env` (`CLAUDE_MODEL`, default `claude-opus-5-5`; `OLLAMA_MODEL`, default `qwen3:14b`), then `make sre`.

## How an MCP client works (what you'll see in the trace)

```
 browser ──POST /api/ask──▶ sre-assistant ──────────── JSON-RPC over HTTP ───────────▶ GemFire MCP server
                              │  at startup:  initialize → notifications/initialized
                              │  first use:   tools/list  (11 tools: name, description, JSON schema)
                              │
                              │  per question:
                              ├─▶ model: system prompt + question + the 11 tool definitions
                              │◀─ model: "call search_logs with {...}"            ← tool_call in the trace
                              ├─────────────────────────────── tools/call ───────▶ ← JSON-RPC → in the trace
                              │◀────────────────────────────── result ────────────  ← result in the trace
                              ├─▶ model: the result
                              │      ... repeat until the model answers in plain text ...
                              └─▶ answer (+ tokens, time, number of tool calls)
```

The trace panel's two collapsible sections at the top show the parts that happen before any question: **the startup handshake** (`initialize`, `notifications/initialized`, `tools/list`) and **the tools exactly as the model gets them** (`GET /api/tools`). Their descriptions and input schemas are all the model knows about GemFire's tools.

Our client and the server agreed on MCP protocol **2025-11-25**, newer than the `2025-06-18` our curl script offers (chunk 2). Negotiating the version in `initialize` is the client's job.

## What Spring AI does for us, and what we wrote

| Spring AI (configuration only, `application.yml`) | Our code (`sre-assistant/src/main/java/...`) |
|---|---|
| the MCP connection over Streamable HTTP (`spring.ai.mcp.client.streamable-http.connections.gemfire`) and the session handshake | `McpClientConfig`: adds the **Basic auth header** (no property for that) and copies every outgoing JSON-RPC body to the trace |
| turning MCP tools into `ToolCallback`s (one per tool, each doing `tools/call`) | `TracingToolCallback`: wraps each tool to report calls/results, log one `sre.tool` line, count Prometheus metrics, and stop a runaway model after 25 calls |
| the tool-calling **loop** (call model → run tools → feed back → repeat) | `AssistantService`: system prompt, model choice per question, current time in the user turn, usage + errors |
| Claude via the **official Anthropic Java SDK**; Qwen via Ollama's API | `AssistantController` + `static/index.html`: the streaming page (Server-Sent Events) |

**Swapping models** is just picking a different `ChatModel`: both starters are on the classpath and `spring.ai.model.chat` is unset, so Spring AI creates both, and `ChatClient.create(model)` with the same prompt and the same tools does the rest.

## Things we learned building it

- **Spring AI 2.1 needs Spring Boot 4.2.** The workload is on 4.1 because Spring for GemFire targets 4.1. The assistant has no GemFire dependency at all (it only speaks MCP), so it can move freely, and it needs **no Artifactory credentials**.
- **`--profile assistant` alone isn't enough**: the assistant depends on `mcp-server`, which lives in the `mcp` profile, so `make sre` passes both.
- **Claude Opus 5.5 rejects `temperature` / `top_p` / `top_k`** (Anthropic API `2026-10-21`). Spring AI 2.1 already drops them, and logs that it did.
- **The current time goes in the user message, not the system prompt.** The model needs it to turn "the last 15 minutes" into a window, and a system prompt that changes every second can't be cached.
- **Fills chunk 8's gap.** The MCP server's audit log only says `POST /mcp`. Our client knows the tool names, so Grafana's new "SRE assistant" row shows **tool calls by tool and model**, question durations and tokens.

## Claude vs Qwen on the same incident

We ran `make chaos C=kill M=server-2`, healed it, then `make chaos C=pause M=server-1` and healed that. Then we asked both models, word for word: *"What happened to the GemFire cluster in the last 15 minutes? Give me a timeline in UTC: what kind of failure each incident was, which member, and how you can tell. Then say what the current state is."*

Ground truth (`data/chaos.log`):
```
21:12:28  kill   server-2      healed 21:13:08
21:13:50  pause  server-1      unpaused 21:14:20 (GemFire reconnected it ~60s later)
```

| | Claude (`claude-opus-5-5`) | Qwen (`qwen3:14b`, local) |
|---|---|---|
| Time | **42 s** | 3 min 40 s |
| Tool calls | 9: `get_membership_timeline`, `assess_cluster_health`, `collect_member_departure_evidence` ×2, `get_partition_region_health`, `search_logs` ×3, `query_stat` | 2: `get_membership_timeline`, `assess_cluster_health` |
| Tokens | 131,616 in / 4,225 out (≈ $0.61) | 16,826 in / 1,507 out (free: your Mac) |
| Timeline (when, who) | ✅ to the second, 14 rows, plus redundancy drop/restore times | ✅ 6 events, straight from `get_membership_timeline` |
| **What kind** of failure | ✅ server-2: "abrupt process death… fits `docker kill` / SIGKILL"; server-1: "the whole process frozen from outside, such as `docker pause` or SIGSTOP", evidence `JVM pause with a wakeup delay of 29789 ms`, `GC collection time=0 ms` | ❌ never read the logs; guessed server-1's disconnect "likely due to a critical threshold violation or network issue", and said "no JVM pauses detected" |
| Current state | ✅ WARNING only because of the forced disconnect in the 15-minute window; all members and redundancy OK | ✅ all members online, full redundancy, the forced-disconnect warning |
| Honesty about limits | "I can't confirm which: I have no access to Docker or the host logs", and suggests `docker inspect` / `docker events` | "No direct evidence (logs not checked here)" |

**What the comparison shows:**
- **Both models use the same 11 tools.** The difference is how far each goes with them. Claude kept going (departure evidence, logs, stats) until it could explain *why*. Qwen stopped after the two tools that answer *what*, then filled the gap with a plausible but wrong guess.
- Claude even explained an apparent contradiction: the stats show no JVM pause because "the sampler wasn't running during the stall", so it trusted the log line written right after the stall.
- **Small local models are fine for "what's the state?"** For root cause they need more help: a narrower question ("check server-1's logs around 21:14"), a bigger model (`OLLAMA_MODEL=qwen3.8:27b`), or a system prompt telling them to check logs before naming a cause.
- **Cost vs. privacy vs. speed:** Claude was ~5× faster here and much more thorough, for about 60 cents. Qwen cost nothing and never left your laptop, but it shares the Mac with the whole Docker lab, so it was slow.

The Grafana "SRE assistant" row shows the same story: tool calls by tool and model (in this run Claude used 6 different tools, Qwen 2), and tokens by model.

## Ask the AI

Sample questions are on the page. Good ones after `make chaos`:
- "What happened to the GemFire cluster in the last 15 minutes? Give me a timeline."
- "Is the cluster healthy right now? If not, why?"
- "Has anything unusual happened to heap in the last 15 minutes?" (after `make load P=heap-hog`)

Then compare with `cat data/chaos.log`.
