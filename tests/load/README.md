# Load Testing Suite — cash-back stack

Нагрузочное тестирование стенда (WordPress + WooCommerce + кэшбэк-плагин + Python postback) с целью калибровки конфига под прод-профиль **4 CPU / 8 ГБ RAM / 80 ГБ NVMe / 1 Гбит/с**.

📊 **Итоговый вердикт первого цикла (2026-05-02): см. [VERDICT.md](VERDICT.md).**
TL;DR: прод-цель 1000 UV/сутки + 1000 webhooks/сутки покрывается с **5× запасом** на финальном конфиге (`pm.max_children=16`, OPcache `validate_timestamps=0`).

Полный план — см. `C:\Users\User\.claude\plans\groovy-fluttering-dongarra.md`.

## TL;DR

```bash
# 1. На нагрузочной машине (отдельная VM или ноут с Docker):
cp .env.example .env && $EDITOR .env

# 2. Один раз — посеять тестовые данные на стенд:
./run.sh seed

# 3. Прогон сценариев в порядке от лёгкого к тяжёлому:
./run.sh smoke
./run.sh baseline
./run.sh webhook_chaos
./run.sh stress
./run.sh spike
./run.sh webhook_burst
./run.sh soak     # 4–8 часов, запускать в screen/tmux

# 4. После всех тестов — очистить тестовые данные:
./run.sh teardown
```

## Целевая нагрузка

| Профиль | Пользователи / сутки | Webhooks / сутки |
|---|---|---|
| **Целевая** | 500 | 500 |
| **Пик (по тех.заданию)** | 1000 | 1000 |
| **Стресс-цель (5× от пика)** | ~50 RPS HTTP | ~100 RPS webhooks |

## Пороги (SLO)

См. `k6/thresholds.js`. Сводно:

- HTTP 5xx < 0.1% (alert > 0.5%, fail > 1%)
- p95 cached pages < 500 мс (fail > 3 с)
- p95 dynamic (`/checkout`, `/my-account`) < 1.5 с (fail > 5 с)
- p95 REST `/wp-json/cashback/v1/*` < 800 мс (fail > 4 с)
- `webhook:queue` LLEN < 50 устойчиво (fail > 1000)
- `webhook:dlq` LLEN = 0 (исключение — `webhook_chaos`)
- PHP-FPM `listen queue` = 0 (fail > 5 устойчиво)

## Структура

```
deploy/tests/load/
├── README.md                  # этот файл
├── run.sh                     # main runner (на bash, для load-gen машины)
├── .env.example               # шаблон конфига
├── .gitignore
├── docker-compose.k6.yml      # запуск k6 в контейнере с remote_write в VM
├── k6/
│   ├── lib/
│   │   ├── config.js          # ENV, BASE_URL и пр.
│   │   ├── auth.js            # WP login flow
│   │   ├── hmac.js            # HMAC SHA256 для постбэков
│   │   ├── data.js            # рандомный выбор user/product
│   │   └── http.js            # обёртка с retry, custom tags
│   ├── thresholds.js          # общие SLO
│   ├── scenario_smoke.js      # 1 VU, 2 мин — sanity-check
│   ├── scenario_baseline.js   # 20 VU, 15 мин — норма
│   ├── scenario_stress.js     # 100 VU, 20 мин — поиск узкого места
│   ├── scenario_spike.js      # 0→200 VU за 30 с
│   ├── scenario_soak.js       # 15 VU, 4–8 ч — утечки
│   ├── scenario_webhook_burst.js   # 100 RPS webhooks
│   └── scenario_webhook_chaos.js   # битые payloads → DLQ
├── seed/
│   ├── seed.sh                # обёртка над wp-cli (через ssh)
│   ├── seed_users.php         # wp eval-file: создаёт loadtest_user_*
│   ├── seed_products.php      # WooCommerce external-товары + meta
│   ├── seed_clicks.php        # wp_cashback_click_log записи (UUID v7)
│   └── data/                  # манифесты, читаемые k6 (создаются seed.sh)
├── teardown/
│   └── teardown.sh            # удаляет всё loadtest_*
├── grafana/
│   └── load-test-dashboard.json
└── results/
    └── <YYYY-MM-DD-HHMM>/     # summary.json, metrics-snapshot.json, verdict.md
```

## Требования к нагрузочной машине

- Docker 20+ (для запуска `grafana/k6`).
- `bash`, `ssh`, `curl`, `jq`.
- SSH-доступ к стенду (для `docker exec wordpress wp ...`).
- Сеть до стенда: гигабит, низкий latency (RTT < 5 мс желательно).
- VictoriaMetrics стенда доступна по адресу `VM_REMOTE_WRITE` (см. `.env.example`).

## Подготовка

```bash
# на load-gen машине:
cd deploy/tests/load
chmod +x run.sh seed/seed.sh teardown/teardown.sh grafana/import.sh
cp .env.example .env
$EDITOR .env

# проверить SSH:
ssh -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "docker exec wordpress wp core version --allow-root"

# импортировать дашборд в Grafana стенда (один раз):
./grafana/import.sh
```

## Grafana дашборд

Все тестовые артефакты живут **только** в этой папке, чтобы не смешиваться
со стек-volumes (`deploy/service/`). Дашборд импортируется на стенд через
Grafana HTTP API:

```bash
# в .env: GRAFANA_URL и GRAFANA_API_TOKEN (Service account → Token)
./grafana/import.sh
```

Скрипт перезапишет существующий дашборд по uid `cashback-loadtest`. Альтернатива —
импорт через UI: Grafana → Dashboards → Import → upload `grafana/load-test-dashboard.json`.

## ⚠ Loadtest-mode guard в плагине (TODO)

`seed.sh` выставляет `loadtest_mode=on` в `wp_options`, но **сам плагин пока не
читает этот флаг** (см. отчёт исследования: F-S3-X). Это значит, что во время
теста по-прежнему будут отрабатывать тяжёлые хуки:

- email/notification queue (`cashback_notification_*`),
- push-уведомления,
- fraud detection cron,
- API sync statuses cron.

**Перед длительным soak** добавить guard в `notifications/class-cashback-notifications.php`
и в cron-регистрацию плагина:

```php
if ( get_option( 'loadtest_mode' ) === 'on' ) {
    return; // skip during load test
}
```

В короткий smoke/baseline/stress это не критично, но искажает p95.

## Iteration loop

1. `smoke` — окружение здоровое.
2. `baseline` — норма без правок (если не зелёный — это дефект).
3. `webhook_chaos` — корректность DLQ-классификации (F-S3-04).
4. `stress` — найти **первое** узкое место.
5. Поправить **только** этот параметр в стендовых конфигах:
   - `service/volumes/php-config/www.conf` — FPM pool;
   - `service/volumes/php-config/wordpress.ini` — OPcache;
   - `service/volumes/nginx/nginx.conf` — FastCGI cache;
   - `service/volumes/mariadb/conf.d/custom.cnf` — InnoDB / connections;
   - `postback/docker-compose.yml` — `WORKER_CONCURRENCY`.
6. Перезапустить контейнер (`docker compose -p service restart <svc>`), снова `stress`. Зафиксировать дельту в `results/<run>/verdict.md`.
7. Когда `stress` стабильно зелёный → `spike` → `webhook_burst` → `soak` (≥ 4 ч).
8. Закоммитить эталонный набор конфигов с указанием тестов в commit message.

## Отчёты

После каждого прогона в `results/<timestamp>/` сохраняется:
- `summary.json` — k6 thresholds + checks + метрики;
- `metrics-snapshot.json` — срез из VictoriaMetrics за интервал теста (PromQL);
- `config-diff.txt` — что меняли перед прогоном (`git diff --stat HEAD~1` от стенда);
- `verdict.md` — заполняется руками: PASS/FAIL + узкое место + что планируется править.

## Безопасность тестовых данных

- Все тестовые юзеры имеют префикс `loadtest_` — `teardown.sh` удаляет строго по этому префиксу.
- Пароль для всех тестовых юзеров в `.env` (`LOADTEST_PASS`); никогда не использовать прод-пароли.
- Webhook-секреты в `.env` (`HMAC_SECRET`, `NETWORK_SLUG`) должны соответствовать **тестовой** сети, заведённой через admin-панель постбэков (`http://localhost:8098`).
- Перед `teardown` обязательно проверить, что не запущен ни один сценарий.
