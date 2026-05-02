// Soak — длительный прогон. По умолчанию 4 часа на 15 VU.
// Цель: ловить утечки памяти, рост размера БД, накопление в slow.log,
// рост `wp_options` autoload, рост median latency со временем.
//
// Override: K6_SOAK_DURATION=8h ./run.sh soak
import { sleep } from 'k6';
import { anonymousFlow, authedFlow, activateFlow } from './lib/flows.js';
import { baseThresholds } from './thresholds.js';

const duration = __ENV.K6_SOAK_DURATION || '4h';

export const options = {
  scenarios: {
    soak: {
      executor: 'constant-vus',
      vus: parseInt(__ENV.K6_SOAK_VUS || '15', 10),
      duration: duration,
      tags: { scenario: 'soak' },
    },
  },
  thresholds: {
    ...baseThresholds,
    // На soak дополнительно — проверка что error rate не растёт со временем.
    // (k6 нативно не умеет «slope thresholds», поэтому здесь просто строгий http_req_failed.)
    http_req_failed: ['rate<0.005'],
  },
};

export default function () {
  const r = Math.random();
  if (r < 0.60) {
    anonymousFlow();
  } else if (r < 0.80) {
    authedFlow();
  } else if (r < 0.97) {
    anonymousFlow();
  } else {
    activateFlow();
  }
  sleep(2 + Math.random() * 4);
}
