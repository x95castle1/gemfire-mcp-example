package com.example.gfmcp.workload;

import java.time.Duration;
import java.util.Map;

import org.springframework.boot.convert.DurationStyle;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * Control the workload while it runs (make load wraps these):
 *   GET  /status            what it's doing right now
 *   GET  /scenarios         the scenarios and what each one does
 *   POST /scenario/{name}   switch scenario (?duration=2m: for a while, then back to the previous one)
 */
@RestController
public class ControlController {

    private final LoadGenerator load;

    ControlController(LoadGenerator load) {
        this.load = load;
    }

    @GetMapping("/status")
    Map<String, Object> status() {
        return load.status();
    }

    @GetMapping("/scenarios")
    Map<String, String> scenarios() {
        return LoadGenerator.scenarios();
    }

    /** ?duration=2m (or 30s, 1h...): run it for that long, then go back to the previous scenario. */
    @PostMapping("/scenario/{name}")
    ResponseEntity<?> switchTo(@PathVariable String name, @RequestParam(required = false) String duration) {
        LoadGenerator.Scenario s = LoadGenerator.Scenario.of(name);
        if (s == null) {
            return ResponseEntity.badRequest().body(Map.of(
                    "error", "unknown scenario '" + name + "'",
                    "scenarios", LoadGenerator.scenarios().keySet()));
        }
        if (duration == null || duration.isBlank()) {
            load.switchTo(s);
        } else {
            Duration d;
            try {
                d = DurationStyle.detectAndParse(duration);   // "2m", "30s", or ISO-8601 "PT2M"
            } catch (IllegalArgumentException e) {
                return ResponseEntity.badRequest().body(Map.of("error", "bad duration '" + duration + "': use e.g. 30s, 2m, 1h"));
            }
            if (d.isNegative() || d.isZero()) {
                return ResponseEntity.badRequest().body(Map.of("error", "duration must be positive"));
            }
            load.switchTo(s, d);
        }
        return ResponseEntity.ok(load.status());
    }
}
