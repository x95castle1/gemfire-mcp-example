// @title  BREAKPOINT
// @risk   warn
// @what   climbs from 500 to TARGET req/s (default 20000) over DURATION (default 10m), until latency or errors cross the line
// @what   push it: make select-load-test T=breakpoint TARGET=60000 DURATION=15m
// @expect k6 stops itself when p95 > 200 ms or more than 1% of requests fail (abortOnFail)
// @expect the rate it reached is this setup's capacity (one workload app, 3 servers, your laptop)
// @expect first run here: no break at 20000/s (p95 1.5 ms, p99 8.6 ms at the top); k6 itself started dropping iterations
// @watch  the k6 summary: http_reqs rate at the abort; Grafana: which member saturates first
import { mixedOp } from './lib.js';

export const options = {
  scenarios: {
    breakpoint: {
      executor: 'ramping-arrival-rate',
      startRate: 500,
      timeUnit: '1s',
      preAllocatedVUs: 100,
      maxVUs: 2000,
      stages: [{ duration: __ENV.DURATION || '10m', target: Number(__ENV.TARGET || 20000) }],
    },
  },
  thresholds: {
    // delayAbortEval: give the run a moment before judging, so the first slow requests don't stop it
    http_req_duration: [{ threshold: 'p(95)<200', abortOnFail: true, delayAbortEval: '20s' }],
    http_req_failed: [{ threshold: 'rate<0.01', abortOnFail: true, delayAbortEval: '20s' }],
  },
};

export default function () {
  mixedOp();
}
