package com.example.gfmcp.sre;

import java.time.Duration;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import org.springframework.ai.anthropic.AnthropicChatModel;
import org.springframework.ai.chat.client.ChatClient;
import org.springframework.ai.chat.metadata.Usage;
import org.springframework.ai.chat.model.ChatModel;
import org.springframework.ai.chat.model.ChatResponse;
import org.springframework.ai.ollama.OllamaChatModel;
import org.springframework.ai.tool.ToolCallback;
import org.springframework.ai.tool.ToolCallbackProvider;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClient;

/**
 * The assistant: one question in, an investigation out.
 *
 * The model is chosen per question. Both ChatModels exist side by side (both starters are on the
 * classpath and spring.ai.model.chat is unset), so the same question can go to Claude or to Qwen
 * with exactly the same system prompt and the same MCP tools.
 *
 * Spring AI runs the tool loop: it sends the question plus the tool definitions (from the MCP
 * server's tools/list), and each time the model answers with a tool call it runs the matching
 * ToolCallback (which does an MCP tools/call), feeds the result back, and repeats until the model
 * answers in plain text.
 */
@Service
public class AssistantService {

    static final String SYSTEM_PROMPT = """
            You are an SRE assistant for a small VMware Tanzu GemFire lab: one locator and three servers
            (server-1, server-2, server-3) running in Docker, with a workload generating traffic.
            Your tools come from the GemFire MCP server. They read live cluster state from the locator's
            Management REST API, and statistics and logs history from a telemetry store. All of them are
            read-only: you cannot change the cluster.

            Investigate with the tools before answering; don't guess. When you describe what happened,
            give a timeline in UTC and the evidence for each claim (a log line, a stat value, a health
            check). If the tools contradict each other, say so and explain which you trust and why.
            If you couldn't check something, say that. Keep the answer readable: a short summary first,
            then the details.
            """;

    private final AnthropicChatModel claude;
    private final OllamaChatModel qwen;
    private final List<ToolCallbackProvider> mcpTools;
    private final TraceHub trace;
    private final String claudeModel;
    private final String claudeApiKey;
    private final String ollamaBaseUrl;
    private final String ollamaModel;
    private final int maxToolCalls;
    private final MeterRegistry meters;

    AssistantService(AnthropicChatModel claude, OllamaChatModel qwen, List<ToolCallbackProvider> mcpTools, TraceHub trace,
                     @Value("${spring.ai.anthropic.chat.model}") String claudeModel,
                     @Value("${spring.ai.anthropic.api-key:}") String claudeApiKey,
                     @Value("${spring.ai.ollama.base-url}") String ollamaBaseUrl,
                     @Value("${spring.ai.ollama.chat.model}") String ollamaModel,
                     @Value("${sre.max-tool-calls:25}") int maxToolCalls,
                     MeterRegistry meters) {
        this.claude = claude;
        this.qwen = qwen;
        this.mcpTools = mcpTools;
        this.trace = trace;
        this.claudeModel = claudeModel;
        this.claudeApiKey = claudeApiKey;
        this.ollamaBaseUrl = ollamaBaseUrl;
        this.ollamaModel = ollamaModel;
        this.maxToolCalls = maxToolCalls;
        this.meters = meters;
    }

    /** Which models can be used right now, and if not, what to do about it. */
    public Map<String, Object> models() {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("claude", claudeStatus());
        m.put("qwen", qwenStatus());
        return m;
    }

    private Map<String, Object> claudeStatus() {
        return Map.of(
                "model", claudeModel,
                "available", !claudeApiKey.isBlank(),
                "hint", claudeApiKey.isBlank() ? "Set ANTHROPIC_API_KEY in .env, then: make sre" : "");
    }

    private Map<String, Object> qwenStatus() {
        String hint;
        boolean available = false;
        try {
            SimpleClientHttpRequestFactory rf = new SimpleClientHttpRequestFactory();
            rf.setConnectTimeout(Duration.ofSeconds(2));
            rf.setReadTimeout(Duration.ofSeconds(3));
            String tags = RestClient.builder().requestFactory(rf).build()
                    .get().uri(ollamaBaseUrl + "/api/tags").retrieve().body(String.class);
            available = tags != null && tags.contains("\"" + ollamaModel + "\"");
            hint = available ? "" : "Ollama is running but the model isn't pulled: ollama pull " + ollamaModel;
        } catch (Exception e) {
            hint = "Ollama isn't reachable at " + ollamaBaseUrl + ". On your Mac: brew install ollama, start it, then: ollama pull " + ollamaModel;
        }
        return Map.of("model", ollamaModel, "available", available, "hint", hint);
    }

    /** The MCP tools exactly as the model is given them: name, description, JSON schema of the input. */
    public List<Map<String, Object>> toolDefinitions() {
        List<Map<String, Object>> defs = new ArrayList<>();
        for (ToolCallbackProvider provider : mcpTools) {
            for (ToolCallback tool : provider.getToolCallbacks()) {
                Map<String, Object> d = new LinkedHashMap<>();
                d.put("name", tool.getToolDefinition().name());
                d.put("description", tool.getToolDefinition().description());
                d.put("inputSchema", tool.getToolDefinition().inputSchema());
                defs.add(d);
            }
        }
        return defs;
    }

    /** Runs one investigation, reporting every step to the trace. Blocks until done. */
    public void investigate(TraceHub.Investigation inv, String question, String modelKey) {
        boolean useClaude = !"qwen".equals(modelKey);
        String modelName = useClaude ? "claude" : "qwen";
        trace.send(inv, "question", Map.of("question", question, "model", modelName,
                "modelId", useClaude ? claudeModel : ollamaModel));

        Map<String, Object> status = useClaude ? claudeStatus() : qwenStatus();
        if (!Boolean.TRUE.equals(status.get("available"))) {
            trace.send(inv, "error", Map.of("message", modelName + " is not available. " + status.get("hint")));
            return;
        }

        // The MCP tools, each wrapped so its calls show up in the trace (and in the sre.tool log)
        List<ToolCallback> tools = new ArrayList<>();
        for (ToolCallbackProvider provider : mcpTools) {
            for (ToolCallback tool : provider.getToolCallbacks()) {
                tools.add(new TracingToolCallback(tool, modelName, trace, inv, maxToolCalls, meters));
            }
        }
        trace.send(inv, "tools", Map.of("count", tools.size(),
                "names", tools.stream().map(t -> t.getToolDefinition().name()).toList()));

        ChatModel chatModel = useClaude ? claude : qwen;
        String outcome = "error";
        try {
            ChatResponse response = ChatClient.create(chatModel).prompt()
                    .system(SYSTEM_PROMPT)
                    // The current time goes in the user turn, not the system prompt: the model needs it
                    // to turn "the last 15 minutes" into a time window, and keeping it out of the system
                    // prompt keeps that part identical (cacheable) across questions.
                    .user("Current time (UTC): " + Instant.now().truncatedTo(ChronoUnit.SECONDS) + "\n\n" + question)
                    .toolCallbacks(tools)
                    .call()
                    .chatResponse();

            String answer = response == null || response.getResult() == null ? ""
                    : response.getResult().getOutput().getText();
            String finish = response == null || response.getResult() == null ? null
                    : response.getResult().getMetadata().getFinishReason();
            if ("refusal".equalsIgnoreCase(String.valueOf(finish))) {
                trace.send(inv, "error", Map.of("message", "The model declined to answer (stop reason: refusal). Try rephrasing the question."));
            }
            trace.send(inv, "answer", Map.of("text", answer == null ? "" : answer));

            Map<String, Object> usage = new LinkedHashMap<>();
            usage.put("model", modelName);
            usage.put("modelId", response != null && response.getMetadata() != null ? response.getMetadata().getModel() : "");
            Usage u = response == null || response.getMetadata() == null ? null : response.getMetadata().getUsage();
            if (u != null) {
                usage.put("promptTokens", u.getPromptTokens());
                usage.put("completionTokens", u.getCompletionTokens());
                usage.put("totalTokens", u.getTotalTokens());
            }
            usage.put("toolCalls", inv.toolCalls);
            usage.put("finishReason", finish);
            trace.send(inv, "usage", usage);
            outcome = "answered";
        } catch (Exception e) {
            Throwable root = e;
            while (root.getCause() != null && root.getCause() != root) {
                root = root.getCause();
            }
            trace.send(inv, "error", Map.of("message", e.getClass().getSimpleName() + ": " + e.getMessage()
                    + (root != e ? "\nCause: " + root.getClass().getSimpleName() + ": " + root.getMessage() : "")));
        } finally {
            // Prometheus: sre_questions_seconds_{count,sum}{model,outcome}: how many, and how long they took
            Timer.builder("sre.questions").description("Questions answered by the assistant")
                    .tag("model", modelName).tag("outcome", outcome)
                    .register(meters).record(java.time.Duration.ofMillis(inv.elapsedMs()));
        }
    }
}
