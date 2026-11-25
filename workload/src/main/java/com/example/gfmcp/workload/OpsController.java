package com.example.gfmcp.workload;

import java.util.Map;

import org.apache.geode.cache.Region;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * Chunk 11: one real GemFire operation per HTTP request, for k6 to drive.
 *   GET /ops/get?region=customers&key=key-42            -> 200 {"found": true|false}
 *   PUT /ops/put?region=customers&key=key-42&size=1024  -> 200 {"bytes": 1024}
 *   400 unknown region / bad size; 503 when a server is at critical heap (LowMemoryException),
 *   so k6 counts it as a failed request.
 * The calls go through the same client pool as the background scenarios (single-hop to the
 * bucket's primary), and are timed as workload_op_seconds{source="k6"}. Same pattern as
 * gemfire-runner's apps behind k6 (/hello?key=...).
 */
@RestController
class OpsController {

    private static final int MAX_SIZE = 1024 * 1024;

    private final Map<String, Region<String, byte[]>> regions;
    private final OpTimers timers;

    OpsController(Regions r, OpTimers timers) {
        this.regions = Map.of("customers", r.customers, "orders", r.orders, "sessions", r.sessions, "products", r.products);
        this.timers = timers;
    }

    @GetMapping("/ops/get")
    ResponseEntity<?> get(@RequestParam String region, @RequestParam String key) {
        Region<String, byte[]> reg = regions.get(region);
        if (reg == null) {
            return unknownRegion(region);
        }
        try {
            byte[] value = timers.time("get", reg, "k6", () -> reg.get(key));
            return ResponseEntity.ok(Map.of("found", value != null));
        } catch (RuntimeException e) {
            return failure(e);
        }
    }

    @PutMapping("/ops/put")
    ResponseEntity<?> put(@RequestParam String region, @RequestParam String key,
                          @RequestParam(defaultValue = "1024") int size) {
        Region<String, byte[]> reg = regions.get(region);
        if (reg == null) {
            return unknownRegion(region);
        }
        if (size < 0 || size > MAX_SIZE) {
            return ResponseEntity.badRequest().body(Map.of("error", "size must be 0.." + MAX_SIZE));
        }
        byte[] value = new byte[size];
        try {
            timers.time("put", reg, "k6", () -> reg.put(key, value));
            return ResponseEntity.ok(Map.of("bytes", size));
        } catch (RuntimeException e) {
            return failure(e);
        }
    }

    private static ResponseEntity<?> unknownRegion(String region) {
        return ResponseEntity.badRequest().body(Map.of("error", "unknown region '" + region + "'",
                "regions", "customers, orders, sessions, products"));
    }

    private static ResponseEntity<?> failure(RuntimeException e) {
        HttpStatus status = LoadGenerator.isLowMemory(e) ? HttpStatus.SERVICE_UNAVAILABLE : HttpStatus.INTERNAL_SERVER_ERROR;
        return ResponseEntity.status(status).body(Map.of("error", e.getClass().getSimpleName() + ": " + e.getMessage()));
    }
}
