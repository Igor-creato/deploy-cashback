# Webhook Receiver — Tests

Стандартная библиотека `unittest` (без внешних test-runner'ов).

## Запуск

Из директории `postback/`:

```bash
python -m unittest discover -s tests -v
```

Требуется Python 3.13+ с установленными `redis` + `prometheus_client` (см. `Dockerfile`).

## Покрытие

- `test_processor_validation.py` — sanity-валидация `unix_timestamp`-полей webhook payload'а
  (защита от silent-fail F-S3-04, см. `plans/sparkling-yawning-lamport.md` §P0.2).
