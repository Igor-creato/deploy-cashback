// Baseline — нормальная нагрузка, ~5× реалистичного среднего.
// 20 VU, 15 мин. Микс 60/20/15/5 (anon/auth/rest-only/activate).
// Должно проходить «зелёным» при дефолтных конфигах.
import { sleep } from 'k6';
import { anonymousFlow, authedFlow, activateFlow } from './lib/flows.js';
import { baseThresholds } from './thresholds.js';

export const options = {
  scenarios: {
    web: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m',  target: 20 },
        { duration: '11m', target: 20 },
        { duration: '2m',  target: 0 },
      ],
      gracefulRampDown: '30s',
      tags: { scenario: 'baseline' },
    },
  },
  thresholds: baseThresholds,
};

export default function () {
  const r = Math.random();
  if (r < 0.60) {
    anonymousFlow();
  } else if (r < 0.80) {
    authedFlow();
  } else if (r < 0.95) {
    // только REST: GET /stores (общая нагрузка на public API)
    anonymousFlow(); // содержит /stores в конце
  } else {
    activateFlow();
  }
  sleep(1 + Math.random() * 3);
}
