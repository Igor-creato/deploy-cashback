# Установка стэка cashback с нуля

Этот файл — пошаговый runbook для разворачивания production-стека
`Igor-creato/deploy-cashback` на чистом Linux-сервере. Для краткой
справки по sparse-checkout и быстрому restore-from-backup см. `README.md`.

## Что устанавливается

Два независимых docker-compose стека:

1. **`service/`** — WordPress + MariaDB + Redis + nginx (с fastcgi_cache) +
   Traefik (HTTPS) + ModSecurity + msmtp + мониторинг (Grafana, VictoriaMetrics,
   node-exporter, cAdvisor, mysqld-exporter).
2. **`postback/`** — webhook-receiver (FastAPI) для приёма постбэков от
   Admitad/EPN, admin-панель (через SSH-туннель), worker для отложенных
   задач. Шарит сети `proxy` и `db-shared` со стеком service.

После запуска обоих стеков плагин cashback (`Igor-creato/cash-back`)
устанавливается через wp-admin или WP-CLI и активируется — на активации
он сам создаёт ~50 таблиц `wp_cashback_*` в существующей БД WordPress.

## Prerequisites

Ubuntu 22.04+ / Debian 12+ (или совместимый дистрибутив с systemd):

| Требование | Версия | Проверка |
|---|---|---|
| `docker` | 24+ | `docker version` |
| `docker compose` (v2) | 2.20+ | `docker compose version` |
| `git` | 2.34+ | `git --version` |
| `openssl` | 3.0+ | `openssl version` |
| `acl` | — | `which setfacl` (ставится install.sh, если нет) |
| `gettext-base` | — | `which envsubst` (ставится install.sh, если нет) |
| Открытые порты | 80, 443 | DNS A-запись на сервер, firewall разрешает входящие |

Если `docker` не установлен — `install.sh` поставит его автоматически
через `curl -fsSL https://get.docker.com | sh` и добавит вызывающего
пользователя в группу `docker`.

DNS обоих доменов (основной WP-домен и WEBHOOK_DOMAIN) должны быть
проставлены **до** запуска `install-all.sh` — Traefik сразу попытается
выпустить Let's Encrypt сертификаты через HTTP-01 challenge. Без DNS
acme.json останется пустым и `docker logs traefik` начнёт писать
"unable to obtain certificate".

## Последовательность установки

### 0. Подготовка пользователя и каталога

Не запускайте `install-all.sh` под `root` напрямую от своего рабочего
аккаунта. Создайте сервисного пользователя (по соглашению — `igor`)
с sudo-правами:

```bash
sudo adduser igor
sudo usermod -aG sudo igor
su - igor
```

Сервер ожидает каталог развёртывания в `/home/igor/cash-back/deploy-cashback`
(другое расположение тоже работает, но `cashback.env` и backup-скрипты
рассчитаны на относительные пути, поэтому проще не менять).

### 1. Клонирование репо со sparse-checkout (без папок tests/)

```bash
mkdir -p /home/igor/cash-back
cd /home/igor/cash-back
git clone https://github.com/Igor-creato/deploy-cashback.git
cd deploy-cashback
git sparse-checkout init --no-cone
git sparse-checkout set '/*' '!/tests/' '!/postback/tests/'
git read-tree -mu HEAD
```

Проверьте:

```bash
ls tests          # No such file or directory
ls postback/tests # No such file or directory
```

### 2. Ревью `cashback.env`

Файл `cashback.env` в корне — источник дефолтов для `install-all.sh` и
backup-скриптов. Обычно ничего менять не нужно, но проверьте:

```bash
cat cashback.env
```

Ключевые поля:
- `STACK_DIR=service`, `WEBHOOK_DIR=postback` — относительно корня репо
- `BACKUP_ROOT=/home/igor/backup` — куда складывать архивы (нужен write-доступ)
- `DEPLOY_USER=deployer` — пользователь GitHub Actions для `git pull` плагина (можно удалить, если CI/CD не используется)

Hardening-флаги (закомментированы по умолчанию):
- `WP_DEBUG_ENABLE=1` — plugin'овые `error_log()` пишутся в `wp-content/debug.log` (для длительных E2E прогонов на staging)
- `MODSEC_RULE_ENGINE=On` — реальная блокировка XSS/SQLi (по умолчанию `DetectionOnly`)

### 3. Запуск install-all.sh

```bash
sudo bash install-all.sh
```

Скрипт по очереди:

1. Проверяет `docker` и `docker compose v2`
2. Создаёт сети `proxy` и `db-shared` (идемпотентно)
3. Запрашивает (с авто-детектом):
   - папку stack — обычно `service`
   - папку webhook — обычно `postback`
4. Вызывает `service/install.sh` — он спрашивает:
   - **DOMAIN** — основной домен WP (например `cashback.example.com`)
   - **ACME_EMAIL** — email для Let's Encrypt уведомлений
   - **SMTP_HOST**, **SMTP_PORT**, **SMTP_USER**, **SMTP_PASSWORD**,
     **SMTP_SECURE** (`tls`/`ssl`/`none`), **SMTP_FROM**
   - **ALERT_EMAIL** — куда Grafana шлёт алерты
5. Скрипт сам генерирует пароли (root MariaDB, MariaDB user, exporter,
   Grafana admin) через `openssl rand -base64`, кладёт в `service/secrets/*.txt`
   с `chmod 600`
6. Билдит образ wordpress (PHP 8.4 + msmtp + PhpRedis + WP-CLI), стартует
   все 13 сервисов через `docker compose up -d`, ждёт healthy MariaDB+Redis
7. Поднимает webhook-receiver:
   - **WEBHOOK_DOMAIN** — например `webhook.example.com`
   - DB-параметры (host=`mariadb`, port=`3306`, user/pass из `service/secrets/`)
   - SMTP_ENV_FILE/SMTP_PASSWORD_FILE_HOST уже preset из service
8. Генерирует `ADMIN_SECRET` для админки postback и печатает его на
   экран — **сохраните, повторно не покажется**

После успешного завершения вы увидите:

```
[✓] оба стека установлены и запущены
```

### 4. Прохождение мастера WordPress

Откройте `https://${DOMAIN}/wp-admin/install.php` в браузере и пройдите
стандартный 5-минутный мастер WP (Site Title, Username, Email, Password).
Он создаст таблицы `wp_users`, `wp_options`, `wp_posts` и т.д.

### 5. Финализация WordPress (Redis Object Cache)

Выполните на сервере:

```bash
sudo bash /home/igor/cash-back/deploy-cashback/service/scripts/finalize-wordpress.sh
```

Скрипт:
1. Проверяет, что PhpRedis загружен в PHP
2. Ставит и активирует плагин `redis-cache`
3. Создаёт `wp-content/object-cache.php` drop-in
4. Подтверждает, что выбран нативный клиент PhpRedis (×5 быстрее Predis)

### 6. Установка плагина cashback

Залейте код плагина в `service/volumes/wordpress/wp-content/plugins/cash-back/`
(вручную или через GitHub Actions с `DEPLOY_USER`).

Активируйте через wp-admin `Plugins` → `Cashback Plugin` → Activate
**ИЛИ** через WP-CLI:

```bash
docker exec -u www-data wordpress wp plugin activate cash-back --allow-root
```

На активации плагин:
- Создаст ~50 таблиц `wp_cashback_*` (idempotent через `IF NOT EXISTS`)
- Запустит миграции 1→13 (`cashback_db_version` → 13)
- Сгенерирует `wp-content/.cashback-encryption-key.php` (`chmod 0600`)
- Зарегистрирует 7 WP-Cron задач + 3 Action Scheduler задачи
- Установит default options для master-switch'ей (`cashback_social_enabled=0`,
  `cashback_fraud_enabled=1`, `cashback_bot_protection_enabled=1`, и т.д.)

### 7. Smoke-проверка

```bash
# DB-version
docker exec -u www-data wordpress wp option get cashback_db_version --allow-root
# → 13

# Количество таблиц cashback_*
docker exec mariadb mariadb -uroot -p"$(cat service/secrets/db_root_password.txt)" \
  cashback_db -e "SHOW TABLES LIKE 'wp_cashback_%'" 2>/dev/null | wc -l
# → ≥ 50

# Encryption key
ls -la service/volumes/wordpress/wp-content/.cashback-encryption-key.php
# → -rw------- (mode 600), owner www-data

# WP-Cron события
docker exec -u www-data wordpress wp cron event list --allow-root | grep cashback_
# → 7+ строк

# REST endpoint
curl -o /dev/null -w "%{http_code}\n" "https://${DOMAIN}/wp-json/cashback/v1/stores"
# → 200

# Все сервисы healthy
docker compose -f service/docker-compose.yml ps
docker compose -f postback/docker-compose.yml ps
```

### 8. Cron на хосте (опционально)

```bash
sudo bash service/scripts/setup-cron.sh
```

Создаёт:
- `/etc/logrotate.d/cashback-wp-cron`
- crontab для текущего пользователя (запускает WP Action Scheduler и
  `backup-all.sh` каждые 6 часов)

### 9. Доступ к admin-панели webhook-receiver

Через SSH-туннель (admin-панель слушает только `127.0.0.1:8098`):

```bash
ssh -L 8098:localhost:8098 igor@your-server
# В другом терминале на локальной машине:
open http://localhost:8098
# Логин: пароль из ADMIN_SECRET (печатался в конце install.sh)
```

### 10. Доступ к Grafana

Через SSH-туннель (Grafana слушает `127.0.0.1:3000`):

```bash
ssh -L 3000:localhost:3000 igor@your-server
# Логин: admin / пароль из service/secrets/grafana_admin_password.txt
```

## Что хранится где

| Файл / каталог | Содержимое | Backup |
|---|---|---|
| `service/.env` | DOMAIN, ACME_EMAIL, MYSQL_DATABASE, SMTP_HOST/PORT/USER/SECURE/FROM, ALERT_EMAIL | `stack-configs.tar.gz` |
| `service/secrets/db_root_password.txt` | Пароль root MariaDB | `stack-configs.tar.gz` |
| `service/secrets/db_password.txt` | Пароль cashback_user | `stack-configs.tar.gz` |
| `service/secrets/grafana_admin_password.txt` | Пароль admin Grafana | `stack-configs.tar.gz` |
| `service/secrets/smtp_password.txt` | Пароль SMTP (тот же mount у postback worker'а) | `stack-configs.tar.gz` |
| `service/secrets/mysql_exporter.cnf` | `[client]` для prometheus mysqld_exporter | `stack-configs.tar.gz` |
| `service/volumes/traefik/acme.json` | Let's Encrypt cert + private key | `acme.json` отдельно |
| `service/volumes/wordpress/` | Bind-mount всего WP root | `wordpress-files.tar.gz` |
| `service/volumes/wordpress/wp-content/.cashback-encryption-key.php` | **Master encryption key** для платёжных реквизитов | внутри `wordpress-files.tar.gz` ✓ |
| `service/volumes/mariadb/` | MariaDB datadir | dump в `db.sql.gz` |
| `service/volumes/grafana/` | Provisioning + dashboards | `grafana-data.tar.gz` |
| `postback/.env` | ADMIN_SECRET, WEBHOOK_DOMAIN, SMTP_*FILE | `webhook-configs.tar.gz` |
| volume `postback_app_data` | `config.json` с DB credentials webhook'а | `webhook-app_data.tar.gz` |

**Backup**: `scripts/backup-all.sh` запускается через cron каждые 6 часов
(если выполнен `setup-cron.sh`). Архив timestamped в `${BACKUP_ROOT}`,
ротация — последние `BACKUP_RETENTION_COUNT` (по умолчанию 3).

**Restore**: `restore-all.sh` или `deploy-from-backup.sh <BACKUP_DIR>` —
см. `README.md`.

## Что делать при ошибках

### `install.sh` упал на середине

Папка `secrets/` уже частично создана. Заново запускать `install-all.sh`
**безопасно** — он спросит подтверждение перезаписи `.env` и переиспользует
существующие пароли:
- `mysql_exporter.cnf` НЕ перезаписывается (`install.sh:236` идемпотентен)
- Остальные файлы `secrets/*.txt` будут перегенерированы с новыми паролями
- Если БД уже инициализирована со старым паролем — нужно вручную обновить
  его через `mariadb -u root -p` ИЛИ удалить volume `mariadb` (потеря данных)

### Traefik не выдаёт сертификат

```bash
docker logs traefik 2>&1 | grep -i acme
```

Типичные причины:
- DNS ещё не пропагандирован (подождите 5-10 мин и `docker restart traefik`)
- Firewall блокирует :80 (Let's Encrypt HTTP-01 challenge ходит на :80)
- Превышен rate limit Let's Encrypt — пробуйте через час

Сброс ACME-state:
```bash
sudo rm service/volumes/traefik/acme.json
sudo touch service/volumes/traefik/acme.json
sudo chown 0:0 service/volumes/traefik/acme.json
sudo chmod 600 service/volumes/traefik/acme.json
docker restart traefik
```

### Плагин `cash-back` не активируется

Откройте `wp-content/debug.log` (если `WP_DEBUG_LOG=1` в `.env`):

```bash
docker exec -u www-data wordpress tail -100 /var/www/html/wp-content/debug.log
```

Типичные блокеры:
- `bcmath` extension не загружено (`docker exec wordpress php -m | grep bcmath`) — нужно пересобрать образ
- `wp-content/` не writable для www-data — `bash service/scripts/fix-wp-perms.sh`
- WooCommerce не активирован — активируйте `wp plugin activate woocommerce` ПЕРЕД cashback
- `cashback_db_version` зафиксировался на промежуточном (например 7) — проверьте, что миграция не упала; повторная активация безопасна

### Encryption key потерян

Если `wp-content/.cashback-encryption-key.php` удалён — выплаты и платёжные
реквизиты дешифровать **невозможно**. Восстановите из backup'а
(`wordpress-files.tar.gz`) или используйте flow `Cashback_Encryption_Recovery`
(admin → "Восстановление шифрования").

**Поэтому первое действие после успешной активации плагина:**

```bash
sudo cp service/volumes/wordpress/wp-content/.cashback-encryption-key.php \
        /home/igor/cashback-encryption-key.bak.$(date +%Y%m%d)
```

И храните копию вне сервера (зашифрованный пароль-менеджер, S3 KMS).

### CrowdSec / WAF включить

CrowdSec в `docker-compose.yml` закомментирован (строки 616-642). Чтобы
активировать (требует отдельного `crowdsec-traefik-bouncer` контейнера):
1. Раскомментируйте секцию crowdsec и `crowdsec_config`/`crowdsec_data` в volumes
2. Создайте `volumes/crowdsec/acquis.yaml` (см. CrowdSec docs)
3. Поднимите bouncer
4. `docker compose up -d`

## Дальнейшие шаги

- Импорт магазинов из Admitad/EPN: настройки в wp-admin → Партнёры →
  Параметры API. См. `obsidian/knowledge/integrations/shop-importer.md`.
- Настройка legal-документов (152-ФЗ): wp-admin → Правовые документы.
- Подключение Yandex ID / VK ID: wp-admin → Социальная авторизация
  (по умолчанию выключена).
- Antifraud thresholds: wp-admin → Антифрод.

## Ссылки

- README.md — sparse-checkout, restore-from-backup
- service/.env.example — справка по hardening-флагам
- postback/.env.example — справка по env webhook-receiver
- obsidian/atlas/деплой и инфраструктура.md — детальная архитектура
