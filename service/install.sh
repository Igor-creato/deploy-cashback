#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════
#  Cashback Stack — Installation Script
#  Ubuntu 22.04 / 24.04
# ═══════════════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

# ─── Проверка root ────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  err "Запуск только от root:  sudo bash install.sh"
  exit 1
fi

# ─── Определяем реального пользователя (кто вызвал sudo) ──
REAL_USER="${SUDO_USER:-root}"
REAL_GROUP="$(id -gn "$REAL_USER" 2>/dev/null || echo "root")"

# ─── cashback.env (источник BACKUP_ROOT) ──────────────────
# Лежит на уровень выше service/, если стек развёрнут из umbrella-репо.
# Если файла нет — берём fallback. Если запущено через install-all.sh,
# переменная уже экспортирована, source просто перепишет тем же.
PARENT_DIR="$(cd "${INSTALL_DIR}/.." && pwd)"
if [[ -f "${PARENT_DIR}/cashback.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${PARENT_DIR}/cashback.env"
  set +a
fi
BACKUP_ROOT="${BACKUP_ROOT:-/home/${REAL_USER}/backup}"

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"
echo -e "${CYAN}   Cashback Stack — Production Installer${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"
echo ""

# ─── Ввод домена ──────────────────────────────────────────
read -rp "$(echo -e "${CYAN}Введите домен сайта (например: cashback.example.com): ${NC}")" DOMAIN
if [[ -z "$DOMAIN" ]]; then
  err "Домен не может быть пустым"
  exit 1
fi

# Валидация домена
if ! echo "$DOMAIN" | grep -qP '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$'; then
  err "Невалидный формат домена: $DOMAIN"
  exit 1
fi

read -rp "$(echo -e "${CYAN}Email для Let's Encrypt SSL: ${NC}")" ACME_EMAIL
if [[ -z "$ACME_EMAIL" ]]; then
  err "Email обязателен для получения SSL-сертификатов"
  exit 1
fi

# nginx server_name: install-time only, рендерится в default.conf через envsubst.
# Дефолт — точное совпадение с DOMAIN. Для multi-subdomain wildcard
# (".example.com localhost 127.0.0.1 nginx") задать env-переменной до запуска:
#   NGINX_SERVER_NAMES=".example.com localhost 127.0.0.1 nginx" sudo bash install.sh
NGINX_SERVER_NAMES="${NGINX_SERVER_NAMES:-${DOMAIN} localhost 127.0.0.1 nginx}"

# ─── SMTP настройки ─────────────────────────────────────
echo ""
info "Настройка отправки email (SMTP)"
read -rp "$(echo -e "${CYAN}SMTP хост (например: smtp.gmail.com): ${NC}")" SMTP_HOST
read -rp "$(echo -e "${CYAN}SMTP порт [587]: ${NC}")" SMTP_PORT
SMTP_PORT="${SMTP_PORT:-587}"
read -rp "$(echo -e "${CYAN}SMTP пользователь (email): ${NC}")" SMTP_USER
read -rsp "$(echo -e "${CYAN}SMTP пароль: ${NC}")" SMTP_PASSWORD
echo ""
read -rp "$(echo -e "${CYAN}SMTP шифрование (tls/ssl) [tls]: ${NC}")" SMTP_SECURE
SMTP_SECURE="${SMTP_SECURE:-tls}"
read -rp "$(echo -e "${CYAN}Email отправителя (From) [${SMTP_USER}]: ${NC}")" SMTP_FROM
SMTP_FROM="${SMTP_FROM:-$SMTP_USER}"

read -rp "$(echo -e "${CYAN}Email для получения алертов Grafana (можно через запятую) [${SMTP_USER}]: ${NC}")" ALERT_EMAIL
ALERT_EMAIL="${ALERT_EMAIL:-$SMTP_USER}"

# ─── MariaDB host port ───────────────────────────────────
# Порт на хосте (127.0.0.1), который пробрасывается на 3306 в контейнере.
# Меняй, если на сервере уже занят 33306 (например, другая инсталляция).
echo ""
info "Порт MariaDB на хосте (bind на 127.0.0.1, контейнерный порт всегда 3306)"
read -rp "$(echo -e "${CYAN}MariaDB host port [33306]: ${NC}")" MARIADB_HOST_PORT
MARIADB_HOST_PORT="${MARIADB_HOST_PORT:-33306}"
if ! [[ "$MARIADB_HOST_PORT" =~ ^[0-9]+$ ]] || (( MARIADB_HOST_PORT < 1 || MARIADB_HOST_PORT > 65535 )); then
  err "MariaDB host port должен быть числом 1-65535 (получено: ${MARIADB_HOST_PORT})"
  exit 1
fi

echo ""
info "Домен:  $DOMAIN"
info "Email:  $ACME_EMAIL"
info "SMTP:   $SMTP_HOST:$SMTP_PORT ($SMTP_SECURE)"
info "Алерты: $ALERT_EMAIL"
info "MariaDB host port: 127.0.0.1:${MARIADB_HOST_PORT}"
echo ""
read -rp "$(echo -e "${YELLOW}Продолжить? (y/n): ${NC}")" CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Отмена."
  exit 0
fi

# ─── Генерация паролей ────────────────────────────────────
generate_password() {
  openssl rand -base64 32 | tr -d '/+=' | head -c "$1"
}

MYSQL_ROOT_PASSWORD="$(generate_password 32)"
MYSQL_PASSWORD="$(generate_password 28)"
MYSQL_EXPORTER_PASSWORD="$(generate_password 28)"
MYSQL_DATABASE="cashback_db"
MYSQL_USER="cashback_user"

# Grafana admin
GRAFANA_PASSWORD="$(generate_password 24)"

# WP-соли генерируются образом WordPress на старте, поэтому здесь не дублируем.

log "Пароли сгенерированы"

# ─── Установка Docker (если нет) ─────────────────────────
if ! command -v docker &>/dev/null; then
  info "Docker не найден, устанавливаю..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
  systemctl start docker
  log "Docker установлен"
else
  log "Docker уже установлен: $(docker --version)"
fi

if ! docker compose version &>/dev/null; then
  err "Docker Compose V2 не найден. Обновите Docker."
  exit 1
fi
log "Docker Compose V2: $(docker compose version --short)"

# Добавить пользователя в группу docker (если ещё не состоит)
if [[ "$REAL_USER" != "root" ]] && ! id -nG "$REAL_USER" | grep -qw docker; then
  usermod -aG docker "$REAL_USER"
  log "Пользователь ${REAL_USER} добавлен в группу docker"
  warn "Для применения группы docker без перезагрузки выполните:  newgrp docker"
fi

# ─── Создание директорий ──────────────────────────────────
info "Создание структуры директорий..."

dirs=(
  "$INSTALL_DIR/volumes/traefik"
  "$INSTALL_DIR/volumes/nginx"
  "$INSTALL_DIR/volumes/nginx-logs"
  "$INSTALL_DIR/volumes/modsec-logs"
  "$INSTALL_DIR/volumes/crowdsec"
  "$INSTALL_DIR/volumes/php-config"
  "$INSTALL_DIR/volumes/mariadb/conf.d"
  "$INSTALL_DIR/volumes/wordpress"
  "$INSTALL_DIR/secrets"
  "$INSTALL_DIR/scripts"
  "$INSTALL_DIR/volumes/modsecurity/local-rules"
  "$INSTALL_DIR/volumes/vector"
  "$BACKUP_ROOT"
  "/var/lib/node_exporter/textfile_collector"
)

for d in "${dirs[@]}"; do
  mkdir -p "$d"
done

# ─── Права для backup-каталога и textfile collector ──────
# Cron-задача backup-all.sh запускается под REAL_USER — ему нужен write-доступ.
# Дублирует логику setup-cron.sh для случая, когда install.sh выполняется
# отдельно (без последующего setup-cron.sh).
if [[ "$REAL_USER" != "root" ]]; then
  chown "${REAL_USER}:${REAL_GROUP}" "$BACKUP_ROOT"
  chmod 750 "$BACKUP_ROOT"

  # textfile collector: setgid (2775) + group=REAL_GROUP, чтобы скрипт
  # бэкапа писал .prom-файл, а node-exporter (root) читал.
  chown "root:${REAL_GROUP}" /var/lib/node_exporter/textfile_collector
  chmod 2775 /var/lib/node_exporter/textfile_collector
fi

log "Директории созданы (backup: ${BACKUP_ROOT})"

# ─── Создание .env ────────────────────────────────────────
cat > "$INSTALL_DIR/.env" <<EOF
# ═══════════════════════════════════════════
# Автоматически сгенерировано install.sh
# $(date '+%Y-%m-%d %H:%M:%S')
# ═══════════════════════════════════════════

DOMAIN=${DOMAIN}
ACME_EMAIL=${ACME_EMAIL}

# MariaDB
MYSQL_DATABASE=${MYSQL_DATABASE}
MYSQL_USER=${MYSQL_USER}
# Порт MariaDB на хосте (контейнерный порт всегда 3306).
# Меняется через install.sh; docker-compose.yml читает как \${MARIADB_HOST_PORT:-33306}.
MARIADB_HOST_PORT=${MARIADB_HOST_PORT}
# MYSQL_ROOT_PASSWORD и MYSQL_PASSWORD хранятся в secrets/, не в .env,
# чтобы не светиться через `docker inspect` mariadb-контейнера.

# SMTP (логин — в env, пароль — в secrets/smtp_password.txt)
SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_USER=${SMTP_USER}
SMTP_SECURE=${SMTP_SECURE}
SMTP_FROM=${SMTP_FROM}

# Email для алертов Grafana
ALERT_EMAIL=${ALERT_EMAIL}

# nginx server_name (install-time only, не читается docker compose).
# Используется install.sh'ом для envsubst-рендера default.conf.tpl → default.conf.
NGINX_SERVER_NAMES=${NGINX_SERVER_NAMES}

# mysqld-exporter пароль больше НЕ хранится в .env — он лежит в
# secrets/mysql_exporter.cnf (Docker secret) и оттуда читается как самим
# exporter'ом (--config.my-cnf), так и setup-mariadb-users.sh при ротации.
EOF

chmod 600 "$INSTALL_DIR/.env"
log ".env создан (chmod 600)"

# ─── Docker secrets ───────────────────────────────────────
# Compose без Swarm bind-mount'ит файлы секретов с правами хоста.
# Контейнерные процессы (www-data uid 33, mysql uid 999, etc.) должны
# мочь читать файлы. Делаем секреты 0644, а саму директорию 0700,
# чтобы доступ извне (не из контейнеров) был только у владельца.
#
# Пароли держим в secrets/, а не в .env — чтобы они не были видны через
# `docker inspect <container>` (env-переменные контейнера видны любому
# процессу с доступом к Docker API, в т.ч. cAdvisor, докер-сокет-прокси).
printf '%s' "$MYSQL_ROOT_PASSWORD" > "$INSTALL_DIR/secrets/db_root_password.txt"
printf '%s' "$MYSQL_PASSWORD"      > "$INSTALL_DIR/secrets/db_password.txt"
printf '%s' "$SMTP_PASSWORD"       > "$INSTALL_DIR/secrets/smtp_password.txt"
printf '%s' "$GRAFANA_PASSWORD"    > "$INSTALL_DIR/secrets/grafana_admin_password.txt"

# my.cnf для mysqld-exporter: пароль не светится в `docker inspect`.
# Формат [client] — стандартный, читается флагом --config.my-cnf.
# Если файл уже существует (re-run install.sh на работающем сервере),
# НЕ перезаписываем — иначе exporter получит новый пароль, а в MariaDB
# останется старый, и до запуска setup-mariadb-users.sh exporter не сможет
# подключиться. setup-mariadb-users.sh прочитает существующий файл и сделает
# ALTER USER идемпотентно.
if [[ ! -f "$INSTALL_DIR/secrets/mysql_exporter.cnf" ]]; then
  cat > "$INSTALL_DIR/secrets/mysql_exporter.cnf" <<EOF
[client]
user=exporter
password=${MYSQL_EXPORTER_PASSWORD}
EOF
  log "secrets/mysql_exporter.cnf создан"
else
  info "secrets/mysql_exporter.cnf уже существует — оставлен без изменений"
fi

chmod 700 "$INSTALL_DIR/secrets"
# Compose v2 (без Swarm) bind-mount'ит файлы секретов в /run/secrets/<name>
# с теми же mode и ownership, что у файла на хосте.
#
# Многие контейнеры запускают service от непривилегированного пользователя:
#   - wordpress (php-fpm worker) → www-data (uid 33), читает wp-config.php
#     с file_get_contents('/run/secrets/db_password') в каждом запросе
#   - mysqld-exporter → nobody, читает /run/secrets/mysql_exporter_my_cnf
#   - grafana → grafana, GF_SECURITY_ADMIN_PASSWORD__FILE
#   - postback receiver/admin/worker → root (но потенциально могут drop)
#
# Поэтому ставим 644 (world-readable in container). Защита от других
# пользователей хоста — через mode 700 на саму директорию secrets/ (никто
# кроме owner'а не зайдёт внутрь, имя файла не помогает обойти).
chmod 644 "$INSTALL_DIR/secrets/"*.txt
chmod 644 "$INSTALL_DIR/secrets/mysql_exporter.cnf"
log "Docker secrets созданы (dir 0700, files 0644 — защита через директорию)"

# ─── Traefik acme.json ────────────────────────────────────
touch "$INSTALL_DIR/volumes/traefik/acme.json"
chmod 600 "$INSTALL_DIR/volumes/traefik/acme.json"
log "acme.json создан (chmod 600)"

# ─── traefik.yml рендерится из .tpl ниже (вместе с nginx/grafana) ───
# Раньше здесь был `sed -i __ACME_EMAIL__` ПО tracked traefik.yml —
# из-за этого рабочее дерево на сервере вечно было «грязным» (M).
# Теперь .tpl + envsubst, как у nginx/grafana; generated traefik.yml
# в .gitignore. Рендер — после блока установки envsubst (ниже).

# ─── Рендеринг шаблонов Grafana provisioning ─────────────
# Grafana 12.4 не разворачивает env-vars в contactPoints[].settings.addresses,
# поэтому contact-points.yml генерится из шаблона .tpl через envsubst.
if ! command -v envsubst &>/dev/null; then
  info "Установка gettext-base (даёт envsubst)..."
  apt-get update -qq && apt-get install -y --no-install-recommends gettext-base >/dev/null
  log "gettext-base установлен"
fi

CP_TPL="$INSTALL_DIR/volumes/grafana/provisioning/alerting/contact-points.yml.tpl"
CP_OUT="$INSTALL_DIR/volumes/grafana/provisioning/alerting/contact-points.yml"
if [[ -f "$CP_TPL" ]]; then
  ALERT_EMAIL="$ALERT_EMAIL" envsubst '${ALERT_EMAIL}' < "$CP_TPL" > "$CP_OUT"
  chmod 644 "$CP_OUT"
  log "contact-points.yml сгенерирован (ALERT_EMAIL=${ALERT_EMAIL})"
fi

# ─── Рендеринг nginx default.conf ────────────────────────
# server_name домена не должен быть hardcoded в default.conf (audit 2026-05-10).
# default_server блок (return 444 на чужой Host:) остаётся без изменений —
# это defense-in-depth, не зависит от домена.
NGINX_TPL="$INSTALL_DIR/volumes/nginx/default.conf.tpl"
NGINX_OUT="$INSTALL_DIR/volumes/nginx/default.conf"
if [[ -f "$NGINX_TPL" ]]; then
  NGINX_SERVER_NAMES="$NGINX_SERVER_NAMES" envsubst '${NGINX_SERVER_NAMES}' < "$NGINX_TPL" > "$NGINX_OUT"
  chmod 644 "$NGINX_OUT"
  log "default.conf сгенерирован (server_name: ${NGINX_SERVER_NAMES})"
else
  warn "default.conf.tpl не найден — пропуск рендера nginx-конфига"
fi

# ─── Рендеринг traefik.yml ───────────────────────────────
# email Let's Encrypt не hardcode'им в tracked-файл (раньше sed -i по
# traefik.yml оставлял рабочее дерево грязным на сервере). Тот же .tpl +
# envsubst паттерн, что у nginx/grafana; generated traefik.yml в .gitignore.
TRAEFIK_TPL="$INSTALL_DIR/volumes/traefik/traefik.yml.tpl"
TRAEFIK_OUT="$INSTALL_DIR/volumes/traefik/traefik.yml"
if [[ -f "$TRAEFIK_TPL" ]]; then
  ACME_EMAIL="$ACME_EMAIL" envsubst '${ACME_EMAIL}' < "$TRAEFIK_TPL" > "$TRAEFIK_OUT"
  chmod 644 "$TRAEFIK_OUT"
  log "traefik.yml сгенерирован (ACME_EMAIL=${ACME_EMAIL})"
else
  warn "traefik.yml.tpl не найден — пропуск рендера traefik-конфига"
fi

# ─── Создание Docker-сетей ────────────────────────────────
if ! docker network inspect proxy &>/dev/null 2>&1; then
  docker network create proxy
  log "Docker network 'proxy' создана"
else
  log "Docker network 'proxy' уже существует"
fi

if ! docker network inspect db-shared &>/dev/null 2>&1; then
  docker network create db-shared
  log "Docker network 'db-shared' создана"
else
  log "Docker network 'db-shared' уже существует"
fi

# ─── Права на volumes ─────────────────────────────────────
# nginx: uid=101/gid=101 в alpine
# wordpress/php-fpm: uid=33/gid=33 (www-data) — настраивается в fix-wp-perms.sh
# mariadb: uid=999/gid=999
chown -R 999:999 "$INSTALL_DIR/volumes/mariadb"
chown -R 101:101 "$INSTALL_DIR/volumes/nginx-logs"
chown -R 101:101 "$INSTALL_DIR/volumes/modsec-logs"
chmod 755 "$INSTALL_DIR/volumes/mariadb"
chmod 755 "$INSTALL_DIR/volumes/nginx-logs"
chmod 755 "$INSTALL_DIR/volumes/modsec-logs"

# Права на wordpress + ACL для REAL_USER (см. service/scripts/fix-wp-perms.sh).
# Скрипт оставляет владельца www-data:www-data и через POSIX ACL даёт REAL_USER
# rwx на wp-content/ — так администратор хоста может писать туда без sudo,
# не ломая работу контейнера. Соответствует WordPress Hardening Guide.
#
# DEPLOY_USER (опционально) подхватывается из cashback.env при наличии файла —
# fix-wp-perms.sh выдаст ему такие же ACL. Без файла блок пропускается.
chmod +x "$INSTALL_DIR/scripts/fix-wp-perms.sh" 2>/dev/null || true
CASHBACK_ENV_FILE="$(cd "$INSTALL_DIR/.." && pwd)/cashback.env"
if [[ -f "$CASHBACK_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$CASHBACK_ENV_FILE"; set +a
fi
bash "$INSTALL_DIR/scripts/fix-wp-perms.sh" "$INSTALL_DIR/volumes/wordpress"

log "Права на volumes установлены"

# ─── Владелец проекта = реальный пользователь ─────────────
# Чтобы docker compose работал без sudo
if [[ "$REAL_USER" != "root" ]]; then
  chown "${REAL_USER}:${REAL_GROUP}" "$INSTALL_DIR/.env"
  chown "${REAL_USER}:${REAL_GROUP}" "$INSTALL_DIR/secrets/"*.txt
  chown "${REAL_USER}:${REAL_GROUP}" "$INSTALL_DIR/secrets"
  chown "${REAL_USER}:${REAL_GROUP}" "$INSTALL_DIR/volumes/traefik/acme.json"
  chown -R "${REAL_USER}:${REAL_GROUP}" "$INSTALL_DIR/volumes/nginx"
  chown -R "${REAL_USER}:${REAL_GROUP}" "$INSTALL_DIR/volumes/php-config"
  chown -R "${REAL_USER}:${REAL_GROUP}" "$INSTALL_DIR/volumes/traefik"
  chown -R "${REAL_USER}:${REAL_GROUP}" "$INSTALL_DIR/volumes/crowdsec"
  # volumes/grafana/{provisioning,dashboards} монтируются в контейнер как :ro,
  # поэтому Grafana не меняет owner. Но если установка случайно прошла под
  # другим user'ом, future `git pull` ломается на unlink при обновлении
  # provisioning/alerting/rules.yml. Явный chown страхует от этого
  # (идемпотентно, не вредит уже корректным установкам).
  chown -R "${REAL_USER}:${REAL_GROUP}" "$INSTALL_DIR/volumes/grafana"
  chown "${REAL_USER}:${REAL_GROUP}" "$INSTALL_DIR/docker-compose.yml" 2>/dev/null || true
  chown "${REAL_USER}:${REAL_GROUP}" "$INSTALL_DIR/scripts/backup.sh" 2>/dev/null || true
  log "Владелец файлов: ${REAL_USER}:${REAL_GROUP}"
fi

# ─── Backup скрипт ────────────────────────────────────────
chmod +x "$INSTALL_DIR/scripts/backup.sh" 2>/dev/null || true
chmod +x "$INSTALL_DIR/scripts/setup-cron.sh" 2>/dev/null || true
chmod +x "$INSTALL_DIR/scripts/setup-mariadb-users.sh" 2>/dev/null || true
chmod +x "$INSTALL_DIR/scripts/install-dashboards.sh" 2>/dev/null || true
chmod +x "$INSTALL_DIR/scripts/fix-wp-perms.sh" 2>/dev/null || true
chmod +x "$INSTALL_DIR/scripts/cleanup-webhooks.sh" 2>/dev/null || true
log "backup.sh, setup-cron.sh, setup-mariadb-users.sh, install-dashboards.sh, fix-wp-perms.sh, cleanup-webhooks.sh готовы"

# ─── Системные лимиты ────────────────────────────────────
info "Настройка системных лимитов..."

# fs.file-max
if ! grep -q 'fs.file-max = 100000' /etc/sysctl.conf 2>/dev/null; then
  cat >> /etc/sysctl.conf <<'SYSCTL'

# ── Cashback Stack Tuning ──
fs.file-max = 100000
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 1024 65535
vm.swappiness = 10
vm.overcommit_memory = 1
SYSCTL
  sysctl -p > /dev/null 2>&1
  log "Sysctl параметры применены"
fi

# ─── Сборка образов и запуск стека ───────────────────────
info "Сборка custom-образа WordPress (это может занять 1-2 минуты при первом запуске)..."
cd "$INSTALL_DIR"
docker compose build
log "Образы собраны"

info "Запуск стека (docker compose up -d)..."
docker compose up -d
log "Контейнеры запущены"

# ─── Ожидание готовности MariaDB ─────────────────────────
info "Ожидаю готовности MariaDB (до 90 секунд)..."
MARIADB_READY=0
for i in {1..45}; do
  if docker exec mariadb healthcheck.sh --connect --innodb_initialized &>/dev/null; then
    MARIADB_READY=1
    break
  fi
  sleep 2
done

if [[ "$MARIADB_READY" -ne 1 ]]; then
  warn "MariaDB не стала healthy за 90с. Проверь: docker logs mariadb"
  warn "После решения запусти вручную: bash scripts/setup-mariadb-users.sh"
else
  log "MariaDB готова"

  # ─── Установка пароля для mysqld-exporter ──────────────
  info "Установка пароля для mysqld-exporter..."
  bash "${INSTALL_DIR}/scripts/setup-mariadb-users.sh"
fi

# ─── Cron для Action Scheduler + WP-Cron + backup ────────
# Запускается ПОСЛЕ старта стека, чтобы WP-CLI проверка прошла без warning
info "Настройка cron (через setup-cron.sh)..."
bash "${INSTALL_DIR}/scripts/setup-cron.sh"

# ─── Сброс пароля Grafana (идемпотентно) ─────────────────
# GF_SECURITY_ADMIN_PASSWORD действует только при первой инициализации grafana.db.
# Если volume уже существует от прошлого запуска — env-var игнорируется и пароль
# в SQLite остаётся старым. grafana-cli reset-admin-password синхронизирует его
# с .env при каждом install.sh — безопасно для повторных запусков.
info "Ожидаю готовности Grafana (до 60 секунд)..."
GRAFANA_READY=0
for i in {1..30}; do
  if docker exec grafana wget -q --spider http://127.0.0.1:3000/api/health &>/dev/null; then
    GRAFANA_READY=1
    break
  fi
  sleep 2
done

if [[ "$GRAFANA_READY" -eq 1 ]]; then
  info "Синхронизация пароля admin'а Grafana..."
  # Читаем пароль из docker secret внутри контейнера, чтобы он не появлялся
  # в argv `docker exec` на хосте (виден в `ps -ef` host'а).
  if docker exec grafana sh -c 'grafana-cli admin reset-admin-password "$(cat /run/secrets/grafana_admin_password)"' >/dev/null 2>&1; then
    log "Пароль Grafana установлен (admin / см. secrets/grafana_admin_password.txt)"
  else
    warn "Не удалось сбросить пароль Grafana — выполни вручную:"
    warn "  docker exec grafana sh -c 'grafana-cli admin reset-admin-password \"\$(cat /run/secrets/grafana_admin_password)\"'"
  fi
else
  warn "Grafana не стала healthy за 60с. После старта выполни вручную:"
  warn "  docker exec grafana sh -c 'grafana-cli admin reset-admin-password \"\$(cat /run/secrets/grafana_admin_password)\"'"
fi

# ─── Установка дашбордов Grafana (provisioning из файлов) ──
info "Установка дашбордов (Node Exporter, cAdvisor, MySQL, Redis)..."
if bash "${INSTALL_DIR}/scripts/install-dashboards.sh"; then
  log "Дашборды установлены"
  # Если Grafana уже была запущена ДО bind-mount директории dashboards —
  # её нужно пересоздать чтобы провижининг подхватил новый mount.
  docker compose -f "${INSTALL_DIR}/docker-compose.yml" up -d --no-deps grafana >/dev/null 2>&1 || true
else
  warn "Не удалось установить дашборды. Запусти вручную:"
  warn "  bash scripts/install-dashboards.sh"
fi

# ─── Итог ─────────────────────────────────────────────────
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}   Установка завершена!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
info "Структура файлов:"
echo "    $INSTALL_DIR/"
echo "    ├── docker-compose.yml"
echo "    ├── .env                   (chmod 600)"
echo "    ├── secrets/"
echo "    │   ├── db_root_password.txt"
echo "    │   ├── db_password.txt"
echo "    │   ├── smtp_password.txt"
echo "    │   └── grafana_admin_password.txt"
echo "    ├── volumes/"
echo "    │   ├── traefik/"
echo "    │   ├── nginx/"
echo "    │   ├── php-config/"
echo "    │   ├── mariadb/conf.d/"
echo "    │   └── wordpress/"
echo "    └── scripts/"
echo "        └── backup.sh"
echo ""
info "Конфигурация:"
echo "    DB name:       $MYSQL_DATABASE"
echo "    DB user:       $MYSQL_USER"
echo "    SMTP host:     $SMTP_HOST:$SMTP_PORT ($SMTP_SECURE)"
echo "    SMTP user:     $SMTP_USER"
echo "    SMTP from:     $SMTP_FROM"
echo ""
warn "Пароли сохранены в .env (chmod 600) и secrets/ (dir 0700)."
warn "Прочитать вручную:  sudo cat ${INSTALL_DIR}/.env"
warn "Не выводи .env в логи и не коммить в git."
echo ""
info "Стек уже запущен. Проверь статус:"
echo ""
echo -e "    ${CYAN}cd $INSTALL_DIR${NC}"
echo -e "    ${CYAN}docker compose ps${NC}"
echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}   СЛЕДУЮЩИЙ ШАГ — установка WordPress${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
echo ""
info "1. Открой в браузере https://${DOMAIN} и пройди мастер установки WordPress"
echo "    (Site Title, Username, Password, Email админа)."
echo ""
info "2. ПОСЛЕ того как WordPress установлен — запусти финализацию:"
echo ""
echo -e "    ${CYAN}bash ${INSTALL_DIR}/scripts/finalize-wordpress.sh${NC}"
echo ""
echo "    Скрипт идемпотентен: ставит и активирует Redis Object Cache,"
echo "    включает drop-in и проверяет, что клиент = PhpRedis (нативный)."
echo ""
warn "Без этого шага WordPress будет работать, но не использовать Redis-кэш"
warn "(падает производительность на 30-60%)."
echo ""
info "Тест что email-алерты ходят (~2 минуты до письма):"
echo -e "    ${CYAN}docker stop nginx; sleep 150; docker start nginx${NC}"
echo ""
info "CrowdSec работает в режиме обучения (без bouncer)."
echo "    Через 1-2 недели проверь алерты и whitelist'ы:"
echo -e "    ${CYAN}docker exec crowdsec cscli alerts list${NC}"
echo -e "    ${CYAN}docker exec crowdsec cscli decisions list${NC}"
echo -e "    ${CYAN}docker exec crowdsec cscli metrics${NC}"
echo "    Подключение к CrowdSec Console (опционально):"
echo -e "    ${CYAN}docker exec crowdsec cscli console enroll <KEY_FROM_app.crowdsec.net>${NC}"
echo ""
info "Webhook-receiver стек (если используется) поднимается отдельно:"
echo -e "    ${CYAN}cd ../webhook-receiver && docker compose build && docker compose up -d${NC}"
echo ""
info "Сайт будет доступен: https://${DOMAIN}"
echo ""
