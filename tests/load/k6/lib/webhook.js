// Webhook helpers — собрать payload, подписать, отправить.
// Контракт см. в receiver.py / processor.py / config.py:
//   • path = /{slug}/{secret_path}
//   • body — JSON с полями mapping (click_id, user_id, uniq_id, order_number, action_date, ...)
//   • HMAC source=body, format=hex, header=X-Signature (SHA256)
//   • action_date — unix seconds, > 1577836800 (F-S3-04 валидация)
import http from 'k6/http';
import { check } from 'k6';
import { cfg } from './config.js';
import { signBody, signQueryRaw, uniqId } from './hmac.js';
import { pickClick } from './data.js';

const URL_BASE = () => `${cfg.webhookUrl}/${cfg.networkSlug}/${cfg.webhookSecretPath}`;

/**
 * Собрать корректный payload, подвязанный к существующему click_id из manifest.
 */
export function buildValidPayload(overrides = {}) {
  const click = pickClick();
  if (!click) {
    throw new Error('No clicks in manifest — run ./run.sh seed first');
  }
  const now = Math.floor(Date.now() / 1000);
  return {
    click_id: click.click_id,
    user_id: click.user_id,
    uniq_id: uniqId(),
    order_number: 'lt-' + uniqId(),
    offer_id: '777',
    offer_name: 'LoadTest Offer',
    order_status: 'completed',
    sum_order: '1000.00',
    comission: '50.00',
    currency: 'RUB',
    action_date: now,
    click_time: now - 60,
    website_id: '1',
    action_type: 'sale',
    ...overrides,
  };
}

/**
 * Отправить webhook. Метод (GET/POST) — из cfg.webhookMethod.
 * GET: query string; POST: JSON body. HMAC подпись добавляется если cfg.hmacSecret задан.
 */
export function sendWebhook(payload, opts = {}) {
  const url = opts.url || URL_BASE();
  const method = (opts.method || cfg.webhookMethod || 'POST').toUpperCase();
  const headers = { 'User-Agent': cfg.userAgent };
  const tags = { name: 'webhook', endpoint: opts.tag || 'valid' };

  if (method === 'GET') {
    const qs = Object.entries(payload)
      .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
      .join('&');
    if (cfg.hmacSecret) {
      headers['X-Signature'] = opts.badSignature
        ? signQueryRaw(cfg.hmacSecret + 'wrong', qs)
        : signQueryRaw(cfg.hmacSecret, qs);
    }
    return http.get(`${url}?${qs}`, { headers, tags });
  }

  // POST
  const body = JSON.stringify(payload);
  headers['Content-Type'] = 'application/json';
  if (cfg.hmacSecret) {
    headers['X-Signature'] = opts.badSignature
      ? signBody(cfg.hmacSecret + 'wrong', body)
      : signBody(cfg.hmacSecret, body);
  }
  return http.post(url, body, { headers, tags });
}

export function expectStatus(r, expected, label) {
  return check(r, {
    [`${label} status=${expected}`]: (x) => x.status === expected,
  });
}
