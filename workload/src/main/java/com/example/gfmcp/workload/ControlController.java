package com.example.gfmcp.workload;

import java.util.Map;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Control the workload while it runs (make load wraps these):
 *   GET  /status            what it's doing right now
 *   GET  /scenarios         the scenarios and what each one does
 *   POST /scenario/{name}   switch scenario
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

    @PostMapping("/scenario/{name}")
    ResponseEntity<?> switchTo(@PathVariable String name) {
        LoadGenerator.Scenario s = LoadGenerator.Scenario.of(name);
        if (s == null) {
            return ResponseEntity.badRequest().body(Map.of(
                    "error", "unknown scenario '" + name + "'",
                    "scenarios", LoadGenerator.scenarios().keySet()));
        }
        load.switchTo(s);
        return ResponseEntity.ok(load.status());
    }
}
