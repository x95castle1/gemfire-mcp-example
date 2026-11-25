package com.example.gfmcp.workload;

import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.Supplier;

import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.Timer;
import org.apache.geode.cache.Region;
import org.springframework.stereotype.Component;

/**
 * Chunk 11: times every GemFire call as the CLIENT sees it (network + server), for the background
 * scenarios and for k6's HTTP requests alike. Prometheus gets a histogram:
 *   workload_op_seconds_bucket{op="get|put", region="customers|...", source="background|k6"}
 * so Grafana can compute p95/p99 and put them next to k6's own numbers (which add HTTP on top) and
 * GemFire's server-side putTime (which leaves the network out).
 */
@Component
public class OpTimers {

    private final MeterRegistry meters;
    private final Map<String, Timer> timers = new ConcurrentHashMap<>();

    OpTimers(MeterRegistry meters) {
        this.meters = meters;
    }

    public <T> T time(String op, Region<?, ?> region, String source, Supplier<T> call) {
        return timer(op, region, source).record(call);   // records even when the call throws
    }

    public void time(String op, Region<?, ?> region, String source, Runnable call) {
        timer(op, region, source).record(call);
    }

    private Timer timer(String op, Region<?, ?> region, String source) {
        String name = region.getName().toLowerCase(Locale.ROOT);
        return timers.computeIfAbsent(op + "|" + name + "|" + source, k -> Timer.builder("workload.op")
                .description("One GemFire operation, timed by the client")
                .tag("op", op).tag("region", name).tag("source", source)
                .publishPercentileHistogram()
                .register(meters));
    }
}
