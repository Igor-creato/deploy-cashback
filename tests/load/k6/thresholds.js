// Общие SLO для всех сценариев.
// k6 Thresholds: https://grafana.com/docs/k6/latest/using-k6/thresholds/
//
// Метрики помечаются tags name=... через http.params.tags.

export const baseThresholds = {
  // Глобальные
  http_req_failed: ['rate<0.01'],            // < 1% сетевых/HTTP ошибок
  checks: ['rate>0.99'],                     // > 99% успешных check'ов

  // Cached страницы (главная, каталог, товар) — должно быть быстро.
  'http_req_duration{name:cached}': ['p(95)<1500', 'p(99)<3000'],

  // Динамические (checkout, my-account, корзина).
  'http_req_duration{name:dynamic}': ['p(95)<3000', 'p(99)<6000'],

  // REST API кэшбэка.
  'http_req_duration{name:rest}': ['p(95)<800', 'p(99)<2000'],

  // Login flow.
  'http_req_duration{name:auth_post_login}': ['p(95)<1500'],
};

export const stressThresholds = {
  ...baseThresholds,
  http_req_failed: ['rate<0.005'],           // ужесточённее: < 0.5% при стрессе
};

export const webhookThresholds = {
  http_req_failed: ['rate<0.001'],           // постбэк должен принимать всё валидное
  'http_req_duration{name:webhook}': ['p(95)<200', 'p(99)<500'],
  checks: ['rate>0.99'],
};

export const chaosThresholds = {
  // Хаос-сценарий — здесь специально 4xx, http_req_failed не должен быть условием.
  // Но check'и (мы проверяем правильные status code'ы) — должны быть >99%.
  checks: ['rate>0.99'],
  'http_req_duration{name:webhook}': ['p(95)<500'],
};
