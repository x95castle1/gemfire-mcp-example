// @title  HOT-KEY
// @risk   safe
// @what   500 puts/s on just 5 keys (hot-0..hot-4) in Customers for 2 min
// @expect each key lives in one bucket with one primary: 1-2 servers do all the work
// @watch  MCP: query_stat put_rate per server is lopsided
// @watch  Grafana: uneven lines in "Puts / s per member"
import { put, commonThresholds } from './lib.js';

export const options = {
  scenarios: {
    hotkey: {
      executor: 'constant-arrival-rate',
      rate: 500,
      timeUnit: '1s',
      duration: '2m',
      preAllocatedVUs: 20,
      maxVUs: 200,
    },
  },
  thresholds: commonThresholds,
};

export default function () {
  put('customers', `hot-${Math.floor(Math.random() * 5)}`);
}
