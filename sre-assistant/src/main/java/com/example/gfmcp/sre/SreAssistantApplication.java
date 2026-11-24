package com.example.gfmcp.sre;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Chunk 9: our own MCP client. Connects to the GemFire MCP server, hands its tools to a model
 * (Claude or Qwen, picked per question), runs the tool-calling loop and streams every step to the
 * browser. Open http://localhost:18080.
 */
@SpringBootApplication
public class SreAssistantApplication {
    public static void main(String[] args) {
        SpringApplication.run(SreAssistantApplication.class, args);
    }
}
