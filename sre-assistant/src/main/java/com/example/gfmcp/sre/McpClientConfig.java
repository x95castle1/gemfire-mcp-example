package com.example.gfmcp.sre;

import io.modelcontextprotocol.client.transport.customizer.McpSyncHttpClientRequestCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * The MCP connection itself is configured in application.yml (spring.ai.mcp.client.*). This adds
 * the two things properties can't: the Authorization header the GemFire MCP server requires (Basic,
 * or with security on a bearer token: see McpTokens), and a copy of every outgoing JSON-RPC message
 * for the trace panel.
 *
 * A request customizer is called for each HTTP request of the Streamable HTTP transport: POST
 * /mcp with a JSON-RPC body (initialize, notifications/initialized, tools/list, tools/call), and
 * DELETE /mcp when a session ends.
 */
@Configuration
class McpClientConfig {

    @Bean
    McpSyncHttpClientRequestCustomizer authAndTrace(McpTokens tokens, TraceHub trace) {
        return (builder, method, endpoint, body, context) -> {
            // Chunk 10b: during a question, the MCP token minted for the person who asked it;
            // otherwise (startup handshake, tools/list) the app's own credentials.
            TraceHub.Investigation inv = trace.current();
            builder.header("Authorization", inv != null && inv.mcpToken != null
                    ? inv.mcpToken.authorization()
                    : tokens.appAuthorization());
            trace.jsonRpcOut(method, body);
        };
    }
}
