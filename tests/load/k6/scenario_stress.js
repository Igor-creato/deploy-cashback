// Stress — поиск точки насыщения.
// 0 → 100 VU за 5 мин, держим 10 мин, ramp down. Тот же микс что baseline.
// Под мониторингом: phpfpm_listen_queue, mysql_threads_running, redis_evicted_keys,
// node_load1, iowait. Первое узкое место → правка конфига → ретест.
import { sleep } from 'k6';
import { anonymousFlow, authedFlow, activateFlow } from './lib/flows.js';
import { stressThresholds } from './thresholds.js';

export const options = {
  scenarios: {
    web: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '5m',  target: 100 },
        { duration: '10m', target: 100 },
        { duration: '5m',  target: 0 },
      ],
      gracefulRampDown: '1m',
      tags: { scenario: 'stress' },
    },
  },
  thresholds: stressThresholds,
};

export default function () {
  const r = Math.random();
  if (r < 0.60) {
    anonymousFlow();
  } else if (r < 0.80) {
    authedFlow();
  } else if (r < 0.95) {
    anonymousFlow();
  } else {
    activateFlow();
  }
  sleep(0.5 + Math.random() * 2);
}
