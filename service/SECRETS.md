# Docker secrets — модель прав

## TL;DR

**Файлы в `service/secrets/` имеют права `0644`, директория — `0700`.** Это by design, не security gap. Изменение файлов на `0600` СЛОМАЕТ `grafana` и `mysqld-exporter` (см. ниже).

## Контекст

Compose v2 без Swarm bind-mount'ит файлы из `secrets/` в `/run/secrets/<name>` внутри контейнера, **сохраняя mode и ownership с хоста**. Файлы owned by host UID 1000 (`igor`).

Контейнеры запускают сервисы под разными UID:

| Контейнер | UID процесса | Какой секрет читает |
|---|---|---|
| `wordpress` (PHP-FPM workers) | `33` (www-data) | `db_password`, `smtp_password` |
| `mariadb` | `0` (root) | `db_root_password`, `db_password` |
| `redis` | `0` (root) | — |
| `grafana` | **`472` (grafana)** | `grafana_admin_password`, `smtp_password` |
| `mysqld-exporter` | **`65534` (nobody)** | `mysql_exporter.cnf` |
| `traefik` | `0` (root) | — |
| `webhook-receiver` / `worker` / `admin` | `0` (root) | — |

При `chmod 0600` файла, owned UID 1000:
- Root-процессы (mariadb, wordpress) **прочитают** (root читает что угодно).
- `grafana` (UID 472) — **не прочитает** → контейнер не сможет авторизоваться.
- `mysqld-exporter` (UID 65534) — **не прочитает** → метрики БД не идут в VictoriaMetrics.

## Почему 644 безопасно

Защита периметра — **директория `secrets/` имеет `0700`**. Никто кроме owner (`igor`) и root не может зайти в директорию, а значит и прочитать файлы по имени. Mode 644 на файлах нужен только для самого Docker bind-mount'a.

Атака через содержимое директории: невозможна без UID 1000 или root на хосте. На VPS shell имеют только `igor` и `root` — значит файлы de facto доступны тем же двум сущностям, что и при 600.

## Что ставит install.sh

[`service/install.sh:247-263`](install.sh):

```bash
chmod 700 "$INSTALL_DIR/secrets"
chmod 644 "$INSTALL_DIR/secrets/"*.txt
chmod 644 "$INSTALL_DIR/secrets/mysql_exporter.cnf"
```

## Проверка состояния

```bash
ssh igor@stand 'ls -ld ~/cash-back/deploy-cashback/service/secrets/ \
                ; ls -la ~/cash-back/deploy-cashback/service/secrets/'
```

Ожидаемый вывод:
```
drwx------ 2 igor igor  …  secrets/
-rw-r--r-- 1 igor igor  …  db_password.txt
-rw-r--r-- 1 igor igor  …  ...
```

Если **директория `drwxr-xr-x` (0755)** — это регрессия (например, после backup-restore или ручного `chmod`). Восстановить:

```bash
chmod 700 ~/cash-back/deploy-cashback/service/secrets/
```

## Когда менять модель

Если когда-нибудь добавится отдельный admin-пользователь (`bob`) с shell-доступом, у которого не должно быть прав на секреты — текущая модель `0700/0644` достаточна (bob не сможет зайти в директорию). Менять права самих файлов в этом случае не требуется.

Альтернатива при сложных multi-tenant сценариях — **Docker Swarm secrets** (in-memory, never on disk). Это другой режим работы Docker; миграция требует перевода стека в swarm-mode.

## Связанные комментарии в коде

- [`service/install.sh:215-263`](install.sh) — основной комментарий + chmod.
- [`service/scripts/setup-cron.sh:270-277`](scripts/setup-cron.sh) — устаревший комментарий "mode 600 root" (исторически было 600, потом сменили). Не править вместе с моделью.
