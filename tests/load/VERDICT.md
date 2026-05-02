# Load Testing — итоговый вердикт

Дата: 2026-05-02
Стенд: `5.35.124.64` (4 CPU / 8 ГБ RAM / 80 ГБ NVMe), профиль идентичен прод-серверу.
Цель: 500 UV/сутки + 500 webhooks/сутки штатно, пик 1000 + 1000.

## Финальный конфиг

- `service/volumes/php-config/www.conf`: `pm.max_children = 16`, `pm.start_servers = 4`, `pm.min_spare_servers = 3`, `pm.max_spare_servers = 8`, `pm.max_requests = 500`.
- `service/volumes/php-config/wordpress.ini`: `opcache.validate_timestamps = 0`, `opcache.revalidate_freq = 60`. **После деплоя плагина** обязательно `wp eval 'opcache_reset();'` или `docker compose -p service restart wordpress`.
- Остальное (MariaDB, Redis, Nginx FastCGI cache, ModSec, Traefik) **не трогалось** — текущие настройки достаточны.

## Сводная таблица прогонов

| Сценарий | RPS | cached p95 | dynamic p95 | rest p95 | failed | Verdict |
|---|---|---|---|---|---|---|
| smoke (1 VU × 2м) | 0.5 | 506 мс | — | — | 0% | ✓ sanity |
| **baseline (20 VU × 15м)** | 7.3 | 235 мс | 549 мс | 419 мс | 0% | ✓ **прод-цель зелёная** |
| webhook_burst (97 RPS) | 97 | n/a | n/a | webhook 35 мс | 83%* | rate-limit per network |
| stress1 (100 VU, max_children=8) | 16.9 | 206 мс | 60 с | 60 с | 3.77% | ✗ FPM bottleneck |
| stress2 (100 VU, max_children=20) | 19.9 | 581 мс | 2.45 с | 60 с | 2.21% | ⚠ CPU saturated |
| stress3 (100 VU, max_children=16+OPcache) | 20.8 | 220 мс | 1.7 с | 60 с | 2.23% | ⚠ CPU потолок |
| spike (0→200 VU, max_children=8) | 21.2 | 225 мс | timeout | timeout | 5.89% | ⚠ старый конфиг |

\* webhook_burst: 83% «failed» = `429 Too Many Requests` от **намеренного** rate-limit `1000/min` per-network в `postback/app/data/config.json`. Не дефект.

## Что выдержало

1. **FastCGI cache** — главная страница, каталог, карточка товара, public REST `/stores`: p95 ≤ 220 мс при 100 VU.
2. **Postback receiver + worker**: 97 RPS, p95 = 35 мс, очередь не растёт, DLQ не растёт. Worker дедуплицирует по `(uniq_id, partner)`.
3. **MariaDB**: при 100 VU `Threads_running` max = 3, `slow_queries = 0`, slow.log пуст. БД не узкое место.
4. **Redis**: object cache активен (3093 ключа в db0, плагин `redis-cache`), webhook queue/dlq в db1.

## Узкое место (стресс)

При 100 VU физический потолок CPU 4-ядер. Распределение под нагрузкой:
- `wordpress` (PHP-FPM): **328% CPU** = 3.3 ядра из 4
- `modsecurity`: ~12% CPU
- `mariadb`: ~18% CPU
- `nginx + traefik`: ~12% CPU
- Суммарно ~370-385% из 400% доступных
- `node_load1` плато: ~10.5

Все запросы через FPM (login, REST, my-account) ждут CPU scheduler. 5% самых длинных уходят в k6-таймаут 60 с.

## Прод-вердикт

| Нагрузка | Запас от пика | Статус |
|---|---|---|
| **Целевая** (500 UV/сутки) | ~10× | ✓ |
| **Заявленный пик** (1000 UV/сутки) | ~5× | ✓ baseline зелёный |
| **5× от пика** (stress 100 VU) | предел | ⚠ rest деградирует |
| **10× от пика** (spike 200 VU) | за пределом | ⚠ |

**На прод-сервере 4×3.3 ГГц / 8 ГБ / NVMe / 1 Гбит финальный конфиг даёт 5× запас от заявленного пика.** Цель достигнута.

## Если в будущем понадобится больше

В порядке возрастающей сложности:

1. **Вертикальное масштабирование** — апгрейд до 6 или 8 CPU. Самый дешёвый способ снять CPU-потолок без правки кода.
2. **Кэширование REST `/me` на 30–60 с** в Redis — большая часть `/me/transactions`, `/me` — это «свежий баланс», который не меняется чаще раза в минуту. Patch в плагине `class-cashback-rest-api.php` около строки 380 (`get_transient`/`set_transient`). Ожидаемый эффект: rest p95 60с → < 300 мс при тех же 100 VU.
3. **Объединить `cashback_user_balance` + `cashback_user_profile`** в один SELECT/JOIN в `get_me` — минус 1 SQL-roundtrip на каждый вызов.
4. **Поднять `rate_limit` per-network** в `postback/app/data/config.json` с 1000/мин до 5000/мин — чтобы переживать burst-postback'и от партнёров после их даунтайма (без потери webhooks из-за 429).

Эти оптимизации **уже за пределами нагрузочного теста** — это работа по плагину/коду.

## Артефакты

```
deploy/tests/load/
├── README.md               — инструкции по запуску
├── VERDICT.md              — этот файл
├── run.sh                  — runner с pre-flight
├── seed/, teardown/        — wp-cli + scp pattern
├── k6/scenario_*.js        — 7 сценариев
├── grafana/load-test-dashboard.json   — дашборд (импорт через grafana/import.sh)
└── results/<run>/          — ↓ summary.json + stdout.log + (для stress3) profile-samples.log
    ├── baseline/
    ├── webhook_burst/
    ├── stress/   (max_children=8)
    ├── stress2/  (max_children=20)
    ├── stress3/  (max_children=16 + OPcache vt=0)  ← финальный конфиг
    └── spike/    (на старом конфиге)
```

## Запуск повторного цикла

Если когда-то понадобится перепроверить (после релиза новой версии плагина или после апгрейда железа):

```bash
cd deploy/tests/load
./run.sh seed         # один раз посеять данные
./run.sh smoke        # ~2 мин
./run.sh baseline     # ~15 мин
./run.sh stress       # ~20 мин
./run.sh spike        # ~5 мин
./run.sh teardown     # очистить
```

`results/<run>/` сохранит summary с k6-метриками для сравнения с этим вердиктом.
