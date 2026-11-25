// @title  SPIKE
// @risk   warn
// @what   200 req/s for 1 min, then 3000 req/s for 30 s, then 200 req/s for 1 min
// @expect a clean 15x jump in GemFire's puts and gets, and back down
// @expect latency rises during the spike; thresholds should still pass
// @watch  MCP: find_stat_threshold_crossings on put_rate finds start and end
// @watch  Grafana: "Load tests (k6)" row; annotations mark the run
import { mixedOp, commonThresholds } from './lib.js';

export const options = {
  scenarios: {
    spike: {
      executor: 'ramping-arrival-rate',   // requests per second, whatever the latency
      startRate: 200,
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: 500,
      stages: [
        { duration: '1m', target: 200 },
        { duration: '5s', target: 3000 },   // the jump
        { duration: '30s', target: 3000 },
        { duration: '5s', target: 200 },
        { duration: '1m', target: 200 },
      ],
    },
  },
  thresholds: commonThresholds,
};

export default function () {
  mixedOp();
}
