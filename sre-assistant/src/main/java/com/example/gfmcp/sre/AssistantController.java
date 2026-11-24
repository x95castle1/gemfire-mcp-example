package com.example.gfmcp.sre;

import java.util.List;
import java.util.Map;

import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.servlet.mvc.method.annotation.SseEmitter;

/**
 *   POST /api/ask      {question, model: "claude"|"qwen"} -> a stream of events (text/event-stream)
 *   GET  /api/models   which models are usable right now
 *   GET  /api/session  the JSON-RPC sent outside questions (startup: initialize, tools/list)
 *   GET  /api/tools    the MCP tools exactly as the model is given them
 * The page at / (static/index.html) uses these.
 */
@RestController
class AssistantController {

    record Ask(String question, String model) { }

    private final AssistantService assistant;
    private final TraceHub trace;

    AssistantController(AssistantService assistant, TraceHub trace) {
        this.assistant = assistant;
        this.trace = trace;
    }

    @PostMapping(path = "/api/ask", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
    SseEmitter ask(@RequestBody Ask ask) {
        SseEmitter emitter = new SseEmitter(15 * 60 * 1000L);   // investigations can take minutes
        TraceHub.Investigation inv = trace.begin(emitter);
        if (inv == null) {
            try {
                emitter.send(SseEmitter.event().name("error").data(Map.of("type", "error",
                        "message", "Another investigation is still running; wait for it to finish.")));
            } catch (Exception ignored) {
            }
            emitter.complete();
            return emitter;
        }
        Thread.ofVirtual().name("investigation").start(() -> {
            try {
                assistant.investigate(inv, ask.question() == null ? "" : ask.question().trim(), ask.model());
            } finally {
                trace.send(inv, "done", Map.of());
                trace.end(inv);
                emitter.complete();
            }
        });
        return emitter;
    }

    @GetMapping("/api/models")
    Map<String, Object> models() {
        return assistant.models();
    }

    @GetMapping("/api/tools")
    List<Map<String, Object>> tools() {
        return assistant.toolDefinitions();
    }

    @GetMapping("/api/session")
    List<Map<String, Object>> session() {
        return trace.sessionLog();
    }
}
