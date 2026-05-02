// Конфиг из ENV. Все скрипты читают только отсюда.
// k6 имеет глобальный __ENV (не process.env).

const required = (name) => {
  const v = __ENV[name];
  if (!v) throw new Error(`ENV ${name} is required`);
  return v;
};

const optional = (name, def) => __ENV[name] ?? def;

export const cfg = {
  baseUrl: required('BASE_URL').replace(/\/+$/, ''),
  webhookUrl: required('WEBHOOK_URL').replace(/\/+$/, ''),
  loadtestPass: required('LOADTEST_PASS'),

  // webhook-only (требуются только в webhook-сценариях)
  networkSlug: optional('NETWORK_SLUG', ''),
  webhookSecretPath: optional('WEBHOOK_SECRET_PATH', ''),
  hmacSecret: optional('HMAC_SECRET', ''),
  webhookMethod: optional('WEBHOOK_METHOD', 'POST').toUpperCase(),

  // имена пользователей/товаров для рандомного выбора
  userCount: parseInt(optional('LOADTEST_USER_COUNT', '200'), 10),
  productCount: parseInt(optional('LOADTEST_PRODUCT_COUNT', '50'), 10),

  // настройки HTTP
  timeout: '60s',
  userAgent: 'k6/loadtest cashback-stand',
};
