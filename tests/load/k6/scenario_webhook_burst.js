// Webhook burst — стресс на постбэк-приёмник.
// 0 → 100 RPS за 1 мин, держим 5 мин, импульс 200 RPS на 30с, ramp down.
// Каждый запрос — валидный payload + правильный HMAC, уникальный uniq_id.
// Цель: receiver стабильно отвечает 200 OK; webhook:queue LLEN <= 50 устойчиво.
import { buildValidPayload, sendWebhook, expectStatus } from './lib/webhook.js';
import { webhookThresholds } from './thresholds.js';

export const options = {
  scenarios: {
    burst: {
      executor: 'ramping-arrival-rate',
      startRate: 0,
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: 200,
      stages: [
        { duration: '1m',  target: 100 },   // ramp up
        { duration: '5m',  target: 100 },   // sustained
        { duration: '30s', target: 200 },   // burst
        { duration: '1m',  target: 100 },   // recover
        { duration: '1m',  target: 0 },     // ramp down
      ],
      tags: { scenario: 'webhook_burst' },
    },
  },
  thresholds: webhookThresholds,
};

export default function () {
  const r = sendWebhook(buildValidPayload());
  expectStatus(r, 200, 'webhook_valid');
}
