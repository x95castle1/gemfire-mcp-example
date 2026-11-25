// @title  SOAK
// @risk   safe
// @what   a constant 300 req/s for DURATION (default 10m: make select-load-test T=soak DURATION=30m)
// @expect flat lines: no slow heap growth, no rising latency, no GC trouble over time
// @watch  Grafana: tenured heap and GC pause time per member; p99 latency
import { mixedOp, commonThresholds } from './lib.js';

export const options = {
  scenarios: {
    soak: {
      executor: 'constant-arrival-rate',
      rate: 300,
      timeUnit: '1s',
      duration: __ENV.DURATION || '10m',
      preAllocatedVUs: 20,
      maxVUs: 200,
    },
  },
  thresholds: commonThresholds,
};

export default function () {
  mixedOp();
}
