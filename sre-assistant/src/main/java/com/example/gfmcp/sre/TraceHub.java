package com.example.gfmcp.sre;

import java.io.IOException;
import java.util.ArrayDeque;
import java.util.Deque;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

import org.springframework.stereotype.Component;
import org.springframework.web.servlet.mvc.method.annotation.SseEmitter;

/**
 * Where every step of an investigation is reported: the JSON-RPC we send, the tool calls the model
 * makes, the answer. Events go live to the browser (Server-Sent Events).
 *
 * One investigation runs at a time (it's a lab, and the MCP request customizer runs on the MCP
 * client's own threads, so a single "active" investigation is the simple way to know where its
 * JSON-RPC belongs). JSON-RPC sent while no investigation is active (the client's startup:
 * initialize, tools/list) is kept in a small session log, shown at GET /api/session.
 */
@Component
public class TraceHub {

    public static final class Investigation {
        final SseEmitter emitter;
        final long startNanos = System.nanoTime();
        volatile int toolCalls;

        Investigation(SseEmitter emitter) {
            this.emitter = emitter;
        }

        long elapsedMs() {
            return (System.nanoTime() - startNanos) / 1_000_000;
        }
    }

    private final AtomicReference<Investigation> active = new AtomicReference<>();
    private final Deque<Map<String, Object>> sessionLog = new ArrayDeque<>();

    /** Starts an investigation, or returns null if one is already running. */
    public Investigation begin(SseEmitter emitter) {
        Investigation inv = new Investigation(emitter);
        return active.compareAndSet(null, inv) ? inv : null;
    }

    public void end(Investigation inv) {
        active.compareAndSet(inv, null);
    }

    public Investigation current() {
        return active.get();
    }

    /** Sends one event to the browser watching the active investigation (if any). */
    public void emit(String type, Map<String, Object> data) {
        Investigation inv = active.get();
        if (inv != null) {
            send(inv, type, data);
        }
    }

    public void send(Investigation inv, String type, Map<String, Object> data) {
        Map<String, Object> event = new LinkedHashMap<>();
        event.put("type", type);
        event.put("ms", inv.elapsedMs());
        event.putAll(data);
        try {
            inv.emitter.send(SseEmitter.event().name(type).data(event));
        } catch (IOException | IllegalStateException e) {
            // the browser went away: keep investigating, just stop streaming
        }
    }

    /** Called for every HTTP request the MCP client sends (from McpClientConfig). */
    public void jsonRpcOut(String httpMethod, String body) {
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("httpMethod", httpMethod);
        data.put("body", body == null ? "" : body);
        Investigation inv = active.get();
        if (inv != null) {
            send(inv, "jsonrpc_out", data);
        } else {
            synchronized (sessionLog) {
                data.put("at", java.time.Instant.now().toString());
                sessionLog.addLast(data);
                while (sessionLog.size() > 50) {
                    sessionLog.removeFirst();
                }
            }
        }
    }

    public List<Map<String, Object>> sessionLog() {
        synchronized (sessionLog) {
            return List.copyOf(sessionLog);
        }
    }
}
