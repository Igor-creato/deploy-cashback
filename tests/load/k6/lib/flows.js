// Реалистичные user flows. Используются и в smoke, и в baseline/stress/spike/soak.
import http from 'k6/http';
import { check, sleep } from 'k6';
import { cfg } from './config.js';
import { login, restHeaders } from './auth.js';
import { pickProduct, pickUser } from './data.js';

// ── Анонимный посетитель ────────────────────────────────────────────────
export function anonymousFlow() {
  // 1. Главная
  let r = http.get(`${cfg.baseUrl}/`, {
    tags: { name: 'cached', endpoint: 'home' },
  });
  check(r, { 'home 2xx': (x) => x.status >= 200 && x.status < 400 });
  sleep(rand(1, 3));

  // 2. Каталог
  r = http.get(`${cfg.baseUrl}/shop/`, {
    tags: { name: 'cached', endpoint: 'shop' },
  });
  check(r, { 'shop 2xx': (x) => x.status >= 200 && x.status < 400 });
  sleep(rand(1, 3));

  // 3. Карточка товара
  const p = pickProduct();
  r = http.get(`${cfg.baseUrl}/product/${p.slug}/`, {
    tags: { name: 'cached', endpoint: 'product' },
  });
  check(r, { 'product 2xx/3xx': (x) => x.status >= 200 && x.status < 400 });
  sleep(rand(2, 5));

  // 4. Public REST: список магазинов
  r = http.get(`${cfg.baseUrl}/wp-json/cashback/v1/stores`, {
    tags: { name: 'rest', endpoint: 'stores' },
  });
  check(r, { 'stores 200': (x) => x.status === 200 });
}

// ── Авторизованный пользователь ────────────────────────────────────────
export function authedFlow() {
  const user = pickUser();
  const { isLogged } = login(user);
  if (!isLogged) {
    return; // login упал — ошибка уже в check'ах auth.js
  }
  sleep(rand(1, 2));

  // my-account
  let r = http.get(`${cfg.baseUrl}/my-account/`, {
    tags: { name: 'dynamic', endpoint: 'my_account' },
  });
  check(r, { 'my-account 200': (x) => x.status === 200 });
  sleep(rand(1, 3));

  // GET /me
  r = http.get(`${cfg.baseUrl}/wp-json/cashback/v1/me`, {
    headers: restHeaders(),
    tags: { name: 'rest', endpoint: 'me' },
  });
  check(r, { 'me 200': (x) => x.status === 200 });
  sleep(rand(1, 2));

  // GET /me/transactions
  r = http.get(`${cfg.baseUrl}/wp-json/cashback/v1/me/transactions?page=1&per_page=10`, {
    headers: restHeaders(),
    tags: { name: 'rest', endpoint: 'me_transactions' },
  });
  check(r, { 'tx 200': (x) => x.status === 200 });
}

// ── Активация кэшбэка (rate-limited 3/product, 10/IP) ──────────────────
export function activateFlow() {
  const user = pickUser();
  const { isLogged } = login(user);
  if (!isLogged) return;

  const p = pickProduct();
  const r = http.post(
    `${cfg.baseUrl}/wp-json/cashback/v1/activate`,
    JSON.stringify({ product_id: p.id }),
    {
      headers: restHeaders(),
      tags: { name: 'rest', endpoint: 'activate' },
    },
  );
  // 200 — ok, 429 — ожидаемый rate-limit под стрессом, не считаем дефектом.
  check(r, {
    'activate 200 or 429': (x) => x.status === 200 || x.status === 429,
  });
}

function rand(min, max) {
  return Math.random() * (max - min) + min;
}
