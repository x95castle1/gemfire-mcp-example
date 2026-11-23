# GemFire MCP Server: Broadcom ships an executable Spring Boot JAR, not an image, so we wrap it.
# Build context is the repo root (see compose.yaml); the JAR comes from ./vendor (gitignored).
FROM eclipse-temurin:21-jre

ARG GF_MCP_VERSION=1.0.0

# Run as a non-root user. The server only READS the telemetry store, so it needs no write access there.
RUN useradd --system --uid 10001 --home-dir /app gfmcp
WORKDIR /app
COPY --chown=gfmcp vendor/gemfire-mcp-server-${GF_MCP_VERSION}.jar /app/gemfire-mcp-server.jar
USER gfmcp

# Streamable HTTP MCP endpoint: POST /mcp
EXPOSE 8085
ENTRYPOINT ["java", "-jar", "/app/gemfire-mcp-server.jar"]
