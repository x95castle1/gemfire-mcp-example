# GemFire telemetry forwarder: Broadcom ships a TAR (bin/ + lib/), not an image, so we wrap it.
# It scans the members' folders for .gfs (stats) and .log files and copies them into the telemetry store.
FROM eclipse-temurin:21-jre

ARG GF_MCP_VERSION=1.0.0

# ADD with a local .tar unpacks it: /opt/gemfire-telemetry-forwarder-<version>/{bin,lib}
ADD vendor/gemfire-telemetry-forwarder-${GF_MCP_VERSION}.tar /opt/
RUN ln -s /opt/gemfire-telemetry-forwarder-${GF_MCP_VERSION} /opt/forwarder \
 && useradd --system --uid 10001 --home-dir /opt/forwarder gfmcp
USER gfmcp

# Configured entirely by environment variables (GF_TELEMETRY_*, GF_S3_*); see compose.yaml
ENTRYPOINT ["/opt/forwarder/bin/gemfire-telemetry-forwarder"]
