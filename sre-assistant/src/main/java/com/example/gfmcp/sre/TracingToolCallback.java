package com.example.gfmcp.sre;

import java.util.LinkedHashMap;
import java.util.Map;

import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.chat.model.ToolContext;
import org.springframework.ai.tool.ToolCallback;
import org.springframework.ai.tool.definition.ToolDefinition;
import org.springframework.ai.tool.metadata.ToolMetadata;

/**
 * Wraps one MCP tool (a Spring AI ToolCallback that does tools/call underneath) so that every call
 * the model makes is reported: to the trace panel, and as one log line on the "sre.tool" logger.
 * That line is the piece the GemFire MCP server's own audit log lacks: WHICH tool was called
 * (chunk 8 charts it in Grafana).
 *
 * It also enforces a per-question budget of tool calls, so a model that loops gets told to stop and
 * answer instead of running forever.
 */
class TracingToolCallback implements ToolCallback {

    private static final Logger toolLog = LoggerFactory.getLogger("sre.tool");
    private static final int SHOWN_RESULT_CHARS = 4000;

    private final ToolCallback delegate;
    private final String model;
    private final TraceHub trace;
    private final TraceHub.Investigation investigation;
    private final int maxToolCalls;
    private final MeterRegistry meters;

    TracingToolCallback(ToolCallback delegate, String model, TraceHub trace, TraceHub.Investigation investigation,
                        int maxToolCalls, MeterRegistry meters) {
        this.delegate = delegate;
        this.model = model;
        this.trace = trace;
        this.investigation = investigation;
        this.maxToolCalls = maxToolCalls;
        this.meters = meters;
    }

    @Override
    public ToolDefinition getToolDefinition() {
        return delegate.getToolDefinition();
    }

    @Override
    public ToolMetadata getToolMetadata() {
        return delegate.getToolMetadata();
    }

    @Override
    public String call(String toolInput) {
        return call(toolInput, null);
    }

    @Override
    public String call(String toolInput, ToolContext toolContext) {
        String name = delegate.getToolDefinition().name();
        int seq;
        synchronized (investigation) {
            seq = ++investigation.toolCalls;
        }
        Map<String, Object> callEvent = new LinkedHashMap<>();
        callEvent.put("seq", seq);
        callEvent.put("tool", name);
        callEvent.put("arguments", toolInput);
        trace.send(investigation, "tool_call", callEvent);

        if (seq > maxToolCalls) {
            String refusal = "Tool budget exhausted: this question already used " + maxToolCalls
                    + " tool calls. Do not call more tools; answer now with what you have, and say what you could not check.";
            report(seq, name, 0, false, refusal);
            return refusal;
        }

        long start = System.nanoTime();
        String result;
        boolean ok = true;
        try {
            result = toolContext == null ? delegate.call(toolInput) : delegate.call(toolInput, toolContext);
        } catch (RuntimeException e) {
            // Hand the failure to the model as the tool result (it can retry or work around it),
            // rather than aborting the whole investigation.
            ok = false;
            result = "Tool call failed: " + e.getMessage();
        }
        long ms = (System.nanoTime() - start) / 1_000_000;
        report(seq, name, ms, ok, result);
        return result;
    }

    private void report(int seq, String name, long ms, boolean ok, String result) {
        toolLog.info("sre.tool model={} tool={} ms={} ok={} resultChars={}", model, name, ms, ok,
                result == null ? 0 : result.length());
        // Prometheus: sre_tool_calls_seconds_count{model,tool,ok} (a count and a duration per tool)
        Timer.builder("sre.tool.calls").description("MCP tool calls made by the assistant")
                .tag("model", model).tag("tool", name).tag("ok", String.valueOf(ok))
                .register(meters).record(java.time.Duration.ofMillis(ms));
        Map<String, Object> resultEvent = new LinkedHashMap<>();
        resultEvent.put("seq", seq);
        resultEvent.put("tool", name);
        resultEvent.put("toolMs", ms);
        resultEvent.put("ok", ok);
        resultEvent.put("chars", result == null ? 0 : result.length());
        resultEvent.put("result", result == null ? "" :
                result.length() > SHOWN_RESULT_CHARS ? result.substring(0, SHOWN_RESULT_CHARS) + "\n… (truncated for display; the model got all of it)" : result);
        trace.send(investigation, "tool_result", resultEvent);
    }
}
