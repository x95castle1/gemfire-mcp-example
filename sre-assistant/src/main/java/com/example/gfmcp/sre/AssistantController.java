package com.example.gfmcp.sre;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.http.MediaType;
import org.springframework.security.core.Authentication;
import org.springframework.security.oauth2.client.OAuth2AuthorizeRequest;
import org.springframework.security.oauth2.client.OAuth2AuthorizedClient;
import org.springframework.security.oauth2.client.OAuth2AuthorizedClientManager;
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
 *   GET  /api/me       who is logged in (chunk 10b; "security": false when it's off)
 * The page at / (static/index.html) uses these.
 */
@RestController
class AssistantController {

    record Ask(String question, String model) { }

    private final AssistantService assistant;
    private final TraceHub trace;
    private final McpTokens tokens;
    private final ObjectProvider<OAuth2AuthorizedClientManager> clients;

    AssistantController(AssistantService assistant, TraceHub trace, McpTokens tokens,
                        ObjectProvider<OAuth2AuthorizedClientManager> clients) {
        this.assistant = assistant;
        this.trace = trace;
        this.tokens = tokens;
        this.clients = clients;
    }

    @PostMapping(path = "/api/ask", produces = MediaType.TEXT_EVENT_STREAM_VALUE)
    SseEmitter ask(@RequestBody Ask ask, Authentication auth, HttpServletRequest request, HttpServletResponse response) {
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
        if (tokens.securityOn() && !onBehalfOf(inv, auth, request, response)) {
            trace.send(inv, "done", Map.of());
            trace.end(inv);
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

    /**
     * Chunk 10b: mint the MCP token for this question, in the asker's name. Done here, on the request
     * thread, because that's where the login (the HTTP session) is; the investigation thread only
     * reads the result from the Investigation.
     */
    private boolean onBehalfOf(TraceHub.Investigation inv, Authentication auth,
                               HttpServletRequest request, HttpServletResponse response) {
        try {
            OAuth2AuthorizedClient login = clients.getObject().authorize(
                    OAuth2AuthorizeRequest.withClientRegistrationId("keycloak").principal(auth)
                            .attribute(HttpServletRequest.class.getName(), request)
                            .attribute(HttpServletResponse.class.getName(), response)
                            .build());
            McpTokens.Exchanged mcp = tokens.exchange(login.getAccessToken().getTokenValue(), auth.getName());
            inv.user = auth.getName();
            inv.mcpToken = mcp;
            Map<String, Object> ev = new LinkedHashMap<>();
            ev.put("user", mcp.user());
            ev.put("audience", mcp.audience());
            ev.put("scope", mcp.scope());
            ev.put("expiresAt", mcp.expiresAt().toString());
            trace.send(inv, "token_exchange", ev);
            return true;
        } catch (Exception e) {
            trace.send(inv, "error", Map.of("message", "Couldn't get an MCP token for " + auth.getName()
                    + " (token exchange with Keycloak): " + e.getMessage()));
            return false;
        }
    }

    @GetMapping("/api/me")
    Map<String, Object> me(Authentication auth) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("security", tokens.securityOn());
        m.put("user", tokens.securityOn() && auth != null ? auth.getName() : null);
        return m;
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
