package com.example.gfmcp.sre;

import java.nio.charset.StandardCharsets;
import java.util.Base64;

import io.modelcontextprotocol.client.transport.customizer.McpSyncHttpClientRequestCustomizer;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * The MCP connection itself is configured in application.yml (spring.ai.mcp.client.*). This adds
 * the two things properties can't: the Basic auth header the GemFire MCP server requires, and a
 * copy of every outgoing JSON-RPC message for the trace panel.
 *
 * A request customizer is called for each HTTP request of the Streamable HTTP transport: POST
 * /mcp with a JSON-RPC body (initialize, notifications/initialized, tools/list, tools/call), and
 * DELETE /mcp when a session ends.
 */
@Configuration
class McpClientConfig {

    @Bean
    McpSyncHttpClientRequestCustomizer basicAuthAndTrace(
            @Value("${GF_MCP_AUTH_BASIC_USERNAME:admin}") String user,
            @Value("${GF_MCP_AUTH_BASIC_PASSWORD:admin}") String password,
            TraceHub trace) {
        String header = "Basic " + Base64.getEncoder()
                .encodeToString((user + ":" + password).getBytes(StandardCharsets.UTF_8));
        return (builder, method, endpoint, body, context) -> {
            builder.header("Authorization", header);
            trace.jsonRpcOut(method, body);
        };
    }
}
