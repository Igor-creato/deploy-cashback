// Spike — внезапный всплеск (рассылка, попадание в популярный канал).
// 0 → 200 VU за 30 сек, держим 1 мин, спад. Должно не быть 5xx (graceful 503/cache OK).
import { sleep } from 'k6';
import { anonymousFlow, authedFlow } from './lib/flows.js';

export const options = {
  scenarios: {
    spike: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '30s', target: 200 },
        { duration: '1m',  target: 200 },
        { duration: '30s', target: 0 },
        { duration: '2m',  target: 0 },   // recovery window — следим как падает latency
      ],
      gracefulRampDown: '30s',
      tags: { scenario: 'spike' },
    },
  },
  thresholds: {
    // Под спайком разрешаем повышенный error rate, но 5xx не должны быть >5%.
    http_req_failed: ['rate<0.05'],
    checks: ['rate>0.90'],
    'http_req_duration{name:cached}': ['p(95)<5000'],
  },
};

export default function () {
  // 80% анонимных (cache spam-friendly), 20% авторизованных (бьём по FPM/MySQL).
  if (Math.random() < 0.8) {
    anonymousFlow();
  } else {
    authedFlow();
  }
  sleep(0.2 + Math.random() * 0.8);
}
