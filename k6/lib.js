// Shared helpers for the k6 scripts in this folder (not a test itself).
//
// Every request goes to the workload app (chunk 5), which does ONE real GemFire operation per
// request through its client pool: k6 -> HTTP -> workload -> GemFire, like gemfire-runner's apps.
//   GET /ops/get?region=customers&key=key-42
//   PUT /ops/put?region=customers&key=key-42&size=1024
import http from 'k6/http';
import { check } from 'k6';

export const BASE_URL = __ENV.BASE_URL || 'http://workload:8090';
const KEYSPACE = 10000;

// Requests are tagged name=get|put. Without it, k6 would label each request with its full URL
// (one per key) and send thousands of time series to Prometheus.
export function get(region, key) {
  const res = http.get(`${BASE_URL}/ops/get?region=${region}&key=${key}`, { tags: { name: 'get' } });
  check(res, { 'get is 200': (r) => r.status === 200 });
  return res;
}

export function put(region, key, size = 1024) {
  const res = http.put(`${BASE_URL}/ops/put?region=${region}&key=${key}&size=${size}`, null, { tags: { name: 'put' } });
  check(res, { 'put is 200': (r) => r.status === 200 });
  return res;
}

// The same mix as the workload's steady scenario: 70% gets / 30% puts, 1 KB values,
// 10k keys spread over Customers and Orders.
export function mixedOp() {
  const region = Math.random() < 0.5 ? 'customers' : 'orders';
  const key = `key-${Math.floor(Math.random() * KEYSPACE)}`;
  return Math.random() < 0.7 ? get(region, key) : put(region, key);
}

// Thresholds every test shares: k6 exits with code 99 (and make select-load-test reports "failed") when one is crossed.
export const commonThresholds = {
  http_req_failed: ['rate<0.01'],          // fewer than 1% of requests may fail
  http_req_duration: ['p(95)<50'],         // 95% of requests under 50 ms (k6's view: HTTP + workload + GemFire)
};
