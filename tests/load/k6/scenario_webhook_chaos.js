// Webhook chaos — преднамеренно битые запросы для проверки роутинга в DLQ.
// 5 минут, 10 RPS равномерно, по 5 классам ошибок:
//   1. неверный HMAC                       → 403
//   2. action_date = 0 (silent-fail F-S3-04) → 200, но в БД status=error и в DLQ
//   3. payload > 16 KiB                    → 413
//   4. неизвестный slug                    → 404
//   5. дубль payload (повторим тот же)     → 200 (дедупликация по SHA256)
//
// После прогона: проверить руками
//   docker exec service-redis-1 redis-cli -n 1 LLEN webhook:dlq  → > 0
//   docker exec wordpress wp db query "SELECT processing_status, COUNT(*) FROM wp_cashback_webhooks WHERE network_slug='admitad' AND received_at >= NOW() - INTERVAL 10 MINUTE GROUP BY 1;"
//
import { sleep } from 'k6';
import { cfg } from './lib/config.js';
import { buildValidPayload, sendWebhook, expectStatus } from './lib/webhook.js';
import { chaosThresholds } from './thresholds.js';

export const options = {
  scenarios: {
    chaos: {
      executor: 'constant-arrival-rate',
      rate: 10,
      timeUnit: '1s',
      duration: '5m',
      preAllocatedVUs: 20,
      maxVUs: 50,
      tags: { scenario: 'webhook_chaos' },
    },
  },
  thresholds: chaosThresholds,
};

// Состояние для дублей: один payload используется дважды подряд раз в N итераций.
let lastPayload = null;

export default function () {
  const cls = Math.floor(Math.random() * 5);

  if (cls === 0) {
    // 1. Bad HMAC
    const r = sendWebhook(buildValidPayload(), { badSignature: true, tag: 'bad_hmac' });
    expectStatus(r, 403, 'bad_hmac');
  } else if (cls === 1) {
    // 2. action_date = 0 (silent-fail)
    const r = sendWebhook(buildValidPayload({ action_date: 0 }), { tag: 'epoch_zero' });
    // Receiver должен принять (HMAC ок), worker запишет error + push DLQ.
    expectStatus(r, 200, 'epoch_zero');
  } else if (cls === 2) {
    // 3. Payload > 16 KiB
    const huge = 'x'.repeat(20 * 1024);
    const r = sendWebhook(buildValidPayload({ junk: huge }), { tag: 'too_big' });
    expectStatus(r, 413, 'too_big');
  } else if (cls === 3) {
    // 4. Unknown slug
    const url = `${cfg.webhookUrl}/nonexistent_${Math.random().toString(36).slice(2, 8)}/${cfg.webhookSecretPath}`;
    const r = sendWebhook(buildValidPayload(), { url, tag: 'bad_slug' });
    expectStatus(r, 404, 'bad_slug');
  } else {
    // 5. Дубль (тот же payload повторно)
    if (!lastPayload) {
      lastPayload = buildValidPayload();
      sendWebhook(lastPayload, { tag: 'first' });
      sleep(0.1);
    }
    const r = sendWebhook(lastPayload, { tag: 'duplicate' });
    expectStatus(r, 200, 'duplicate');
  }
}
