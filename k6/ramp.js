// @title  RAMP
// @risk   safe
// @what   0 -> 1000 req/s over 1 min, hold 2 min, down to 0 over 30 s
// @expect GemFire's puts and gets climb steadily with the request rate
// @expect latency stays flat if the cluster has headroom
// @watch  Grafana: k6 requests/s next to GemFire's puts+gets/s
import { mixedOp, commonThresholds } from './lib.js';

export const options = {
  scenarios: {
    ramp: {
      executor: 'ramping-arrival-rate',
      startRate: 0,
      timeUnit: '1s',
      preAllocatedVUs: 20,
      maxVUs: 300,
      stages: [
        { duration: '1m', target: 1000 },
        { duration: '2m', target: 1000 },
        { duration: '30s', target: 0 },
      ],
    },
  },
  thresholds: commonThresholds,
};

export default function () {
  mixedOp();
}
