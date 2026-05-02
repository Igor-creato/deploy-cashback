// Smoke — sanity-check на 1 VU, ~2 минуты.
// Прогоняет полный путь: anonymous → authed → activate.
// Цель: убедиться что окружение здоровое и сценарии не падают на ошибках.
import { sleep } from 'k6';
import { anonymousFlow, authedFlow, activateFlow } from './lib/flows.js';

export const options = {
  vus: 1,
  duration: '2m',
  thresholds: {
    http_req_failed: ['rate<0.01'],
    checks: ['rate>0.99'],
  },
};

export default function () {
  anonymousFlow();
  sleep(2);
  authedFlow();
  sleep(2);
  activateFlow();
  sleep(3);
}
