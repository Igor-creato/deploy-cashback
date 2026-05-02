// Источники тестовых данных. Манифесты создаются seed.sh и лежат в seed/data/.
// k6 имеет SharedArray для read-only датасетов между VU.
import { SharedArray } from 'k6/data';
import { cfg } from './config.js';

// Если файл недоступен (например, тест без seed) — возвращаем фолбэк-генератор.
function safeLoad(path, fallback) {
  try {
    // open() работает только в init-фазе.
    return JSON.parse(open(path));
  } catch (e) {
    return fallback;
  }
}

export const users = new SharedArray('users', () =>
  safeLoad(
    '/scripts/../seed/data/users.json',
    Array.from({ length: cfg.userCount }, (_, i) => ({
      id: 1000 + i,
      login: `loadtest_user_${String(i + 1).padStart(3, '0')}`,
    })),
  ),
);

export const products = new SharedArray('products', () =>
  safeLoad(
    '/scripts/../seed/data/products.json',
    Array.from({ length: cfg.productCount }, (_, i) => ({
      id: 2000 + i,
      slug: `loadtest-product-${String(i + 1).padStart(3, '0')}`,
      domain: 'aliexpress.com',
      network: 'admitad',
    })),
  ),
);

export const clicks = new SharedArray('clicks', () =>
  safeLoad('/scripts/../seed/data/clicks.json', []),
);

export function pickUser() {
  return users[Math.floor(Math.random() * users.length)];
}

export function pickProduct() {
  return products[Math.floor(Math.random() * products.length)];
}

export function pickClick() {
  if (!clicks.length) return null;
  return clicks[Math.floor(Math.random() * clicks.length)];
}
