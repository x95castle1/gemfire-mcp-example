package com.example.gfmcp.workload;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * A GemFire client that generates switchable traffic, so the GemFire MCP server has something to
 * find in the stats and logs.
 *
 * Spring Boot for GemFire auto-configures a ClientCache (no annotation needed) that connects through
 * spring.data.gemfire.pool.locators (see application.yml). Note: no @EnableStatistics here, on purpose.
 * A client .gfs in ./data/gemfire would be shipped by the forwarder like a member's, and the MCP
 * server's members_present health check would flag "a member recorded stats but isn't in the cluster".
 */
@SpringBootApplication
public class WorkloadApplication {

    public static void main(String[] args) {
        SpringApplication.run(WorkloadApplication.class, args);
    }
}
