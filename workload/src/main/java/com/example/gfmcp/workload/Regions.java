package com.example.gfmcp.workload;

import org.apache.geode.cache.Region;
import org.apache.geode.cache.client.ClientCache;
import org.apache.geode.cache.client.ClientRegionShortcut;
import org.springframework.stereotype.Component;

/**
 * Client-side handles to the four regions created by gemfire/init-cluster.gfsh.
 *
 * PROXY = the client keeps no local copy; every get/put goes to the servers. That way every
 * operation shows up in the SERVERS' statistics, which is what the MCP server reads.
 * Plain GemFire API on purpose (no Spring Data templates), so you can see exactly what's called.
 */
@Component
public class Regions {

    final Region<String, byte[]> customers;   // PARTITION_REDUNDANT
    final Region<String, byte[]> orders;      // PARTITION_REDUNDANT_PERSISTENT
    final Region<String, byte[]> sessions;    // PARTITION, no redundancy: the heap-hog target
    final Region<String, byte[]> products;    // REPLICATE

    Regions(ClientCache cache) {
        this.customers = proxy(cache, "Customers");
        this.orders = proxy(cache, "Orders");
        this.sessions = proxy(cache, "Sessions");
        this.products = proxy(cache, "Products");
    }

    private static Region<String, byte[]> proxy(ClientCache cache, String name) {
        Region<String, byte[]> existing = cache.getRegion(name);
        if (existing != null) {
            return existing;
        }
        return cache.<String, byte[]>createClientRegionFactory(ClientRegionShortcut.PROXY).create(name);
    }
}
