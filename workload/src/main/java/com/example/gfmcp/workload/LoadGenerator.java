package com.example.gfmcp.workload;

import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.Semaphore;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

import io.micrometer.core.instrument.FunctionCounter;
import io.micrometer.core.instrument.Gauge;
import io.micrometer.core.instrument.MeterRegistry;
import jakarta.annotation.PreDestroy;
import org.apache.geode.cache.LowMemoryException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;

/**
 * Generates GemFire traffic for the current scenario.
 *
 * Every 100 ms the scheduler starts (target ops/s / 10) operations on virtual threads. At most
 * MAX_IN_FLIGHT run at once; if the cluster is too slow to keep up, extra operations are counted as
 * "dropped" instead of piling up. The cap must be well above one tick's worth of operations (300
 * at higher rates), because a tick starts all of its operations before any of them has finished.
 */
@Component
public class LoadGenerator {

    private static final Logger log = LoggerFactory.getLogger(LoadGenerator.class);

    public enum Scenario {
        STEADY("steady", 200, "about 200 ops/s, 70% gets / 30% puts, 1 KB values over 10k keys in Customers + Orders"),
        HEAP_HOG("heap-hog", 40, "new 512 KB values into Sessions (no redundancy) until servers hit critical heap"),
        RELEASE_HEAP("release-heap", 0, "remove everything from Sessions, then go back to steady"),
        STOP("stop", 0, "no traffic");

        final String id;
        final int opsPerSecond;
        final String description;

        Scenario(String id, int opsPerSecond, String description) {
            this.id = id;
            this.opsPerSecond = opsPerSecond;
            this.description = description;
        }

        public static Scenario of(String id) {
            for (Scenario s : values()) {
                if (s.id.equals(id)) {
                    return s;
                }
            }
            return null;
        }
    }

    private static final int KEYSPACE = 10_000;
    private static final int MAX_IN_FLIGHT = 1000;
    private static final byte[] VALUE_1KB = new byte[1024];
    private static final byte[] VALUE_512KB = new byte[512 * 1024];   // one shared array: the client stays small

    private final Regions regions;
    private final AtomicReference<Scenario> scenario = new AtomicReference<>(Scenario.STOP);
    private final ScheduledExecutorService ticker = Executors.newSingleThreadScheduledExecutor();
    private final ExecutorService workers = Executors.newVirtualThreadPerTaskExecutor();
    private final Semaphore inFlight = new Semaphore(MAX_IN_FLIGHT);

    private final AtomicLong puts = new AtomicLong();
    private final AtomicLong gets = new AtomicLong();
    private final AtomicLong errors = new AtomicLong();
    private final AtomicLong rejectedLowMemory = new AtomicLong();
    private final AtomicLong dropped = new AtomicLong();
    private final AtomicLong sessionKeys = new AtomicLong();
    private final AtomicReference<String> lastError = new AtomicReference<>("");
    private volatile double actualOpsPerSecond;
    private volatile String note = "";

    private final String initialScenario;

    private final OpTimers timers;
    private ScheduledFuture<?> revert;      // pending switch back after a timed scenario (guarded by this)
    private volatile Instant revertsAt;
    private volatile Scenario revertTo;

    public LoadGenerator(Regions regions, @Value("${workload.scenario:steady}") String initialScenario, MeterRegistry meters,
                         OpTimers timers) {
        this.regions = regions;
        this.timers = timers;
        this.initialScenario = initialScenario;
        registerMetrics(meters);
    }

    /**
     * Chunk 8: the same counters as /status, as Prometheus metrics on /actuator/prometheus. Function
     * counters/gauges read the existing AtomicLongs when scraped; nothing extra happens per operation.
     */
    private void registerMetrics(MeterRegistry meters) {
        FunctionCounter.builder("workload.operations", puts, AtomicLong::get)
                .tag("op", "put").description("puts sent to GemFire").register(meters);
        FunctionCounter.builder("workload.operations", gets, AtomicLong::get)
                .tag("op", "get").description("gets sent to GemFire").register(meters);
        FunctionCounter.builder("workload.errors", rejectedLowMemory, AtomicLong::get)
                .tag("kind", "rejected_low_memory").description("puts refused by a server at critical heap").register(meters);
        FunctionCounter.builder("workload.errors", errors, AtomicLong::get)
                .tag("kind", "other").register(meters);
        FunctionCounter.builder("workload.dropped", dropped, AtomicLong::get)
                .description("operations skipped because too many were in flight").register(meters);
        Gauge.builder("workload.target.ops.per.second", scenario, s -> s.get().opsPerSecond).register(meters);
        for (Scenario s : Scenario.values()) {   // 1 for the active scenario, 0 for the rest
            Gauge.builder("workload.scenario", scenario, cur -> cur.get() == s ? 1 : 0).tag("scenario", s.id).register(meters);
        }
    }

    @EventListener(ApplicationReadyEvent.class)
    void start() {
        seedProducts();
        ticker.scheduleAtFixedRate(this::tick, 0, 100, TimeUnit.MILLISECONDS);
        ticker.scheduleAtFixedRate(this::measure, 1, 1, TimeUnit.SECONDS);
        Scenario first = Scenario.of(initialScenario);
        switchTo(first != null ? first : Scenario.STEADY);
    }

    /** Products is a small REPLICATE region of reference data that gets read in steady mode. */
    private void seedProducts() {
        Map<String, byte[]> batch = new LinkedHashMap<>();
        for (int i = 0; i < 100; i++) {
            batch.put("product-" + i, new byte[200]);
        }
        regions.products.putAll(batch);
        log.info("Seeded 100 entries into /Products");
    }

    /**
     * Switch for a while, then go back to what was running before (make load P=stop D=2m).
     * The two "Scenario: a -> b" log lines (start and revert) are what Grafana shows as annotations.
     */
    public synchronized void switchTo(Scenario next, Duration duration) {
        Scenario previous = scenario.get();
        if (previous == Scenario.RELEASE_HEAP) {
            previous = Scenario.STEADY;   // release-heap ends in steady anyway
        }
        switchTo(next);
        Scenario back = previous;
        revertTo = back;
        revertsAt = Instant.now().plus(duration);
        log.info("Scenario {} runs for {}, then back to {}", next.id,
                org.springframework.boot.convert.DurationStyle.SIMPLE.print(duration, java.time.temporal.ChronoUnit.SECONDS), back.id);
        revert = ticker.schedule(() -> {
            synchronized (this) {
                revert = null;
                revertsAt = null;
                revertTo = null;
                switchTo(back);
            }
        }, duration.toMillis(), TimeUnit.MILLISECONDS);
    }

    public synchronized void switchTo(Scenario next) {
        if (revert != null) {          // a new switch replaces a pending timed one
            revert.cancel(false);
            revert = null;
            revertsAt = null;
            revertTo = null;
        }
        log.info("Scenario: {} -> {} ({})", scenario.get().id, next.id, next.description);
        note = "";
        if (next == Scenario.RELEASE_HEAP) {
            scenario.set(Scenario.RELEASE_HEAP);
            workers.submit(this::releaseHeap);
            return;
        }
        scenario.set(next);
    }

    private void tick() {
        Scenario s = scenario.get();
        int opsThisTick = s.opsPerSecond / 10;
        for (int i = 0; i < opsThisTick; i++) {
            if (!inFlight.tryAcquire()) {
                dropped.incrementAndGet();
                continue;
            }
            workers.submit(() -> {
                try {
                    operation(s);
                } catch (Exception e) {
                    recordError(e);
                } finally {
                    inFlight.release();
                }
            });
        }
    }

    private void operation(Scenario s) {
        ThreadLocalRandom r = ThreadLocalRandom.current();
        switch (s) {
            case STEADY -> {
                var region = r.nextBoolean() ? regions.customers : regions.orders;
                String key = "key-" + r.nextInt(KEYSPACE);
                if (r.nextInt(10) < 7) {
                    timers.time("get", region, "background", () -> region.get(key));
                    if (r.nextInt(10) == 0) {
                        String product = "product-" + r.nextInt(100);
                        timers.time("get", regions.products, "background", () -> regions.products.get(product));
                    }
                    gets.incrementAndGet();
                } else {
                    timers.time("put", region, "background", () -> region.put(key, VALUE_1KB));
                    puts.incrementAndGet();
                }
            }
            case HEAP_HOG -> {
                String session = "session-" + sessionKeys.incrementAndGet();
                timers.time("put", regions.sessions, "background", () -> regions.sessions.put(session, VALUE_512KB));
                puts.incrementAndGet();
            }
            default -> { }
        }
    }

    /** removeAll in batches of the keys the servers hold in Sessions, then back to steady. */
    private void releaseHeap() {
        try {
            Set<String> keys = regions.sessions.keySetOnServer();
            note = "releasing " + keys.size() + " Sessions entries";
            log.info("release-heap: removing {} entries from /Sessions", keys.size());
            List<String> batch = new ArrayList<>(500);
            for (String k : keys) {
                batch.add(k);
                if (batch.size() == 500) {
                    regions.sessions.removeAll(batch);
                    batch.clear();
                }
            }
            if (!batch.isEmpty()) {
                regions.sessions.removeAll(batch);
            }
            log.info("release-heap: done");
        } catch (Exception e) {
            recordError(e);
        }
        switchTo(Scenario.STEADY);
    }

    private void recordError(Exception e) {
        if (isLowMemory(e)) {
            // The server refused the put: it is above its critical-heap threshold (90% here).
            if (rejectedLowMemory.incrementAndGet() % 50 == 1) {
                log.warn("Put rejected by a server at critical heap ({} so far): {}", rejectedLowMemory.get(), rootMessage(e));
            }
        } else {
            errors.incrementAndGet();
        }
        lastError.set(e.getClass().getSimpleName() + ": " + rootMessage(e));
    }

    static boolean isLowMemory(Throwable e) {
        for (Throwable t = e; t != null; t = t.getCause()) {
            if (t instanceof LowMemoryException) {
                return true;
            }
        }
        return String.valueOf(e.getMessage()).contains("LowMemoryException");
    }

    private static String rootMessage(Throwable e) {
        Throwable t = e;
        while (t.getCause() != null && t.getCause() != t) {
            t = t.getCause();
        }
        return t.getClass().getSimpleName() + ": " + t.getMessage();
    }

    private long lastTotal;

    private void measure() {
        long total = puts.get() + gets.get();
        actualOpsPerSecond = total - lastTotal;
        lastTotal = total;
    }

    public Map<String, Object> status() {
        Scenario s = scenario.get();
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("scenario", s.id);
        Instant until = revertsAt;
        Scenario back = revertTo;
        if (until != null && back != null) {
            m.put("revertsAt", until.toString());
            m.put("revertsTo", back.id);
        }
        m.put("description", s.description);
        m.put("targetOpsPerSecond", s.opsPerSecond);
        m.put("actualOpsPerSecond", actualOpsPerSecond);
        m.put("puts", puts.get());
        m.put("gets", gets.get());
        m.put("rejectedAtCriticalHeap", rejectedLowMemory.get());
        m.put("otherErrors", errors.get());
        m.put("droppedTicks", dropped.get());
        m.put("sessionsWritten", sessionKeys.get());
        m.put("lastError", lastError.get());
        if (!note.isEmpty()) {
            m.put("note", note);
        }
        return m;
    }

    public static Map<String, String> scenarios() {
        Map<String, String> m = new LinkedHashMap<>();
        for (Scenario s : Scenario.values()) {
            m.put(s.id, s.description);
        }
        return m;
    }

    @PreDestroy
    void shutdown() {
        ticker.shutdownNow();
        workers.shutdownNow();
    }
}
