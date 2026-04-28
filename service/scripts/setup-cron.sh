#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════
#  Cashback Stack — Server Cron Setup (Action Scheduler ready)
#
#  Устанавливает host-cron для Action Scheduler + остаточных
#  WP-Cron задач + бэкапа. Идемпотентен: повторный запуск
#  перезаписывает маркированный блок без дублей.
#
#  Использование:  sudo bash scripts/setup-cron.sh
# ═══════════════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

# ─── Маркер блока (по нему снимается старая версия) ──────
MARKER="# cashback-stack: managed by setup-cron.sh"
LEGACY_PATTERNS=(
  'wp-cron.php'
  'wp action-scheduler'
  'wp cron event'
  'cashback-as.lock'
  'cashback-wpcron.lock'
  'scripts/backup.sh'
  'scripts/backup-all.sh'
)

LOG_DIR="/var/log/wp-cron"
LOCK_DIR="/var/lock"
LOGROTATE_CONF="/etc/logrotate.d/cashback-wp-cron"

# ─── Проверка root ────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  err "Запуск только от root:  sudo bash scripts/setup-cron.sh"
  exit 1
fi

# ─── REAL_USER (кто вызвал sudo) и его группа ─────────────
REAL_USER="${SUDO_USER:-root}"
REAL_GROUP="$(id -gn "$REAL_USER" 2>/dev/null || echo "root")"
info "Crontab будет установлен для пользователя: ${REAL_USER} (${REAL_GROUP})"

# ─── INSTALL_DIR (корень стека, на уровень выше scripts/) ─
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
info "Корень стека: ${INSTALL_DIR}"

# ─── Зависимости ──────────────────────────────────────────
if ! command -v crontab &>/dev/null; then
  err "crontab не найден. Установите: apt-get install -y cron"
  exit 1
fi

FLOCK_BIN="$(command -v flock || true)"
if [[ -z "$FLOCK_BIN" ]]; then
  err "flock не найден. Установите: apt-get install -y util-linux"
  exit 1
fi
info "flock: ${FLOCK_BIN}"

if ! command -v logrotate &>/dev/null; then
  warn "logrotate не найден, устанавливаю..."
  apt-get update -qq && apt-get install -y -qq logrotate
fi

# ─── Каталог логов ───────────────────────────────────────
mkdir -p "$LOG_DIR"
chown "${REAL_USER}:${REAL_GROUP}" "$LOG_DIR"
chmod 755 "$LOG_DIR"
log "Каталог логов: ${LOG_DIR}"

# ─── Права для backup.sh ────────────────────────────────
# Идемпотентно: каталог бэкапов, лог и textfile collector
# должны быть доступны на запись пользователю REAL_USER (под которым cron).
BACKUP_ROOT="/home/${REAL_USER}/backup"
BACKUP_LOG="/var/log/backup.log"
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"

mkdir -p "$BACKUP_ROOT"
chown "${REAL_USER}:${REAL_GROUP}" "$BACKUP_ROOT"
chmod 750 "$BACKUP_ROOT"
log "Каталог бэкапов: ${BACKUP_ROOT}"

touch "$BACKUP_LOG"
chown "${REAL_USER}:${REAL_GROUP}" "$BACKUP_LOG"
chmod 644 "$BACKUP_LOG"
log "Лог бэкапов: ${BACKUP_LOG}"

# textfile collector: setgid + group=REAL_GROUP, чтобы скрипт писал,
# а node-exporter (root) читал. mode 2775 — setgid bit + rwxrwxr-x.
if [[ -d "$TEXTFILE_DIR" ]]; then
  chown "root:${REAL_GROUP}" "$TEXTFILE_DIR"
  chmod 2775 "$TEXTFILE_DIR"
  # уже существующие .prom-файлы — выровнять группу/права
  find "$TEXTFILE_DIR" -maxdepth 1 -name '*.prom' -exec chgrp "${REAL_GROUP}" {} \; -exec chmod 664 {} \; 2>/dev/null || true
  log "Textfile collector: ${TEXTFILE_DIR} (root:${REAL_GROUP}, 2775)"
else
  warn "Каталог ${TEXTFILE_DIR} не существует — node-exporter ещё не запущен?"
  warn "Метрика cashback_backup_last_success_timestamp_seconds будет недоступна"
fi

# ─── logrotate ──────────────────────────────────────────
cat > "$LOGROTATE_CONF" <<LOGROTATE
${LOG_DIR}/*.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su ${REAL_USER} ${REAL_GROUP}
}
LOGROTATE
chmod 644 "$LOGROTATE_CONF"
log "logrotate настроен: ${LOGROTATE_CONF}"

# ─── logrotate для bind-mount логов контейнеров ──────────
# ModSec audit (Serial), nginx access/error, php-fpm slowlog лежат в bind-mount'ах.
# Без этой секции файлы росли бы бесконечно: контейнеры на alpine не имеют logrotate,
# а ModSec пишет в один файл через MODSEC_AUDIT_LOG_TYPE=Serial.
# copytruncate — обязательно: процессы держат FD открытым; renameat() их не уведомит.
LOGROTATE_STACK="/etc/logrotate.d/cashback-stack"
cat > "$LOGROTATE_STACK" <<LOGROTATE
${INSTALL_DIR}/volumes/modsec-logs/*.log
${INSTALL_DIR}/volumes/nginx-logs/*.log
{
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    size 100M
    dateext
    dateformat -%Y%m%d
}
LOGROTATE
chmod 644 "$LOGROTATE_STACK"
log "logrotate bind-mount логов: ${LOGROTATE_STACK}"

# Проверка синтаксиса logrotate
if ! logrotate -d "$LOGROTATE_CONF" &>/dev/null; then
  warn "logrotate -d вернул ошибку — проверьте вручную: logrotate -d ${LOGROTATE_CONF}"
fi
if ! logrotate -d "$LOGROTATE_STACK" &>/dev/null; then
  warn "logrotate -d ${LOGROTATE_STACK} вернул ошибку — проверьте вручную"
fi

# ─── journald ограничения ───────────────────────────────
# По умолчанию systemd-journald заполняет до 10% диска. На небольшом VPS это
# становится крупнейшим потребителем места после modsec_audit. Жёстко ограничиваем.
JOURNALD_CONF_DIR="/etc/systemd/journald.conf.d"
JOURNALD_CONF="${JOURNALD_CONF_DIR}/cashback.conf"
mkdir -p "$JOURNALD_CONF_DIR"
if [[ ! -f "$JOURNALD_CONF" ]] || ! grep -q 'cashback-stack' "$JOURNALD_CONF" 2>/dev/null; then
  cat > "$JOURNALD_CONF" <<EOF
# cashback-stack: managed by setup-cron.sh
[Journal]
SystemMaxUse=500M
SystemKeepFree=1G
MaxRetentionSec=14day
EOF
  chmod 644 "$JOURNALD_CONF"
  if systemctl is-system-running &>/dev/null; then
    systemctl restart systemd-journald 2>/dev/null || true
  fi
  log "journald лимиты: SystemMaxUse=500M, MaxRetentionSec=14d"
else
  info "journald конфиг уже есть: ${JOURNALD_CONF}"
fi

# ─── WP-CLI sanity check (warning, не fatal) ─────────────
WP_CLI_OK=0
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^wordpress$'; then
  if docker exec -u www-data wordpress wp --info &>/dev/null; then
    WP_CLI_OK=1
    log "WP-CLI доступен в контейнере wordpress"
  fi
fi

if [[ "$WP_CLI_OK" -eq 0 ]]; then
  warn "WP-CLI пока недоступен через 'docker exec wordpress wp'."
  warn "Если контейнер ещё не запущен — это нормально. Иначе пересоберите образ:"
  warn "  docker compose build wordpress && docker compose up -d wordpress"
fi

# ─── Сборка нового crontab ───────────────────────────────
CRON_AS="* * * * * ${FLOCK_BIN} -n ${LOCK_DIR}/cashback-as.lock -c 'docker exec -u www-data wordpress wp action-scheduler run --batch-size=50 --batches=1 --group=cashback --quiet' >> ${LOG_DIR}/action-scheduler.log 2>&1"
CRON_WP="*/5 * * * * ${FLOCK_BIN} -n ${LOCK_DIR}/cashback-wpcron.lock -c 'docker exec -u www-data wordpress wp cron event run --due-now --quiet' >> ${LOG_DIR}/wp-cron.log 2>&1"
# Очистка отработавших actions: complete > 1 день, failed/canceled > 7 дней.
# Разнесены по минутам, чтобы не пересекаться по shared-lock; запускаются ночью,
# когда нагрузка минимальна. logrotate подхватит as-clean.log по glob *.log.
CRON_AS_CLEAN_COMPLETE="17 3 * * * ${FLOCK_BIN} -n ${LOCK_DIR}/cashback-as-clean.lock -c 'docker exec -u www-data wordpress wp action-scheduler clean --status=complete --before=\"1 day ago\" --batch-size=1000 --quiet' >> ${LOG_DIR}/as-clean.log 2>&1"
CRON_AS_CLEAN_FAILED="22 3 * * * ${FLOCK_BIN} -n ${LOCK_DIR}/cashback-as-clean.lock -c 'docker exec -u www-data wordpress wp action-scheduler clean --status=failed --before=\"7 days ago\" --batch-size=1000 --quiet' >> ${LOG_DIR}/as-clean.log 2>&1"
CRON_AS_CLEAN_CANCELED="27 3 * * * ${FLOCK_BIN} -n ${LOCK_DIR}/cashback-as-clean.lock -c 'docker exec -u www-data wordpress wp action-scheduler clean --status=canceled --before=\"7 days ago\" --batch-size=1000 --quiet' >> ${LOG_DIR}/as-clean.log 2>&1"
# Чистка таблицы cashback_webhooks через отдельный скрипт (cleanup-webhooks.sh).
# Скрипт делает batched DELETE с циклом — обрабатывает любой backlog без шанса
# отстать. failed/error-записи оставляем для форензики и ручного re-process'а.
# Запускается от root, чтобы читать secrets/db_password.txt напрямую.
CRON_WH_CLEAN="33 4 * * * ${FLOCK_BIN} -n ${LOCK_DIR}/cashback-wh-clean.lock -c '${INSTALL_DIR}/scripts/cleanup-webhooks.sh' >> ${LOG_DIR}/wh-clean.log 2>&1"
# Truncate Traefik access.log в named volume, если он перевалил 100 MB.
# Named volume не виден logrotate'у на хосте, поэтому очистка делается через
# `truncate` из контейнера (sidecar busybox запускается одной командой).
CRON_TRAEFIK_TRUNCATE="30 4 * * * docker run --rm -v service_traefik_logs:/logs busybox sh -c 'find /logs -name \"*.log\" -size +100M -exec truncate -s 0 {} +' 2>&1 | logger -t cashback-traefik-trunc"
# Бэкап-задача указывает на единый скрипт верхнего уровня (stack + webhook-receiver).
# Если umbrella ещё не развёрнут, fallback на старый stack-only backup.sh.
# Ротация (оставлять N последних бэкапов) — внутри backup-all.sh / backup.sh,
# управляется env-var BACKUP_RETENTION_COUNT (default 3).
ROOT_DIR="$(cd "${INSTALL_DIR}/.." && pwd)"
if [[ -f "${ROOT_DIR}/scripts/backup-all.sh" ]]; then
  CRON_BACKUP="0 */6 * * * bash ${ROOT_DIR}/scripts/backup-all.sh >> /var/log/backup.log 2>&1"
else
  CRON_BACKUP="0 */6 * * * bash ${INSTALL_DIR}/scripts/backup.sh >> /var/log/backup.log 2>&1"
fi

# ─── Helper: пересобрать crontab указанного пользователя ──
# Удаляет старый маркированный блок + legacy-строки и добавляет новые
# task-строки (через переменное число аргументов) под общим маркером.
# Использование: rebuild_crontab <user> <task1> [task2] ...
rebuild_crontab() {
  local user="$1"; shift
  local tmp; tmp="$(mktemp)"

  crontab -u "$user" -l 2>/dev/null > "$tmp" || true

  # 1. Удалить весь блок от маркера до пустой строки / EOF
  if grep -qF "$MARKER" "$tmp"; then
    awk -v marker="$MARKER" '
      BEGIN { skip=0 }
      index($0, marker) { skip=1; next }
      skip && /^$/ { skip=0; next }
      !skip { print }
    ' "$tmp" > "${tmp}.new" && mv "${tmp}.new" "$tmp"
  fi

  # 2. Удалить legacy-строки вне блока
  local pattern
  for pattern in "${LEGACY_PATTERNS[@]}"; do
    grep -vF -- "$pattern" "$tmp" > "${tmp}.new" || true
    mv "${tmp}.new" "$tmp"
  done

  # 3. Добавить новый блок (только если task'и переданы)
  if (( $# > 0 )); then
    {
      printf '\n%s\n' "$MARKER"
      printf '%s\n' "$@"
      printf '\n'
    } >> "$tmp"
  fi

  crontab -u "$user" "$tmp"
  rm -f "$tmp"
}

# ─── Установка crontab ────────────────────────────────────
# AS + WP-cron достаточно прав REAL_USER (только docker exec).
# backup-all.sh читает wp-content (owned by www-data uid 33) и
# secrets/ (mode 600 root) → должен идти из root crontab, иначе
# tar упадёт на permission denied и бэкап будет неполным.
rebuild_crontab "$REAL_USER" "$CRON_AS" "$CRON_WP" \
  "$CRON_AS_CLEAN_COMPLETE" "$CRON_AS_CLEAN_FAILED" "$CRON_AS_CLEAN_CANCELED"
log "Crontab ${REAL_USER}: AS run + AS clean + wp-cron"

# root: backup-all.sh + cashback_webhooks cleanup + truncate Traefik logs.
# wh-clean и traefik-truncate требуют чтения secrets/ (mode 600) и docker socket — оба под root.
rebuild_crontab "root" "$CRON_BACKUP" "$CRON_WH_CLEAN" "$CRON_TRAEFIK_TRUNCATE"
log "Crontab root: backup-all.sh + cashback_webhooks cleanup + traefik logs truncate"

# ─── Показать итог ───────────────────────────────────────
echo ""
info "Текущий crontab ${REAL_USER}:"
crontab -u "$REAL_USER" -l | sed 's/^/    /'
echo ""
info "Текущий crontab root:"
crontab -u root -l | sed 's/^/    /'

echo ""
log "Готово."
echo ""
info "Проверка:"
echo "    tail -f ${LOG_DIR}/action-scheduler.log"
echo "    tail -f ${LOG_DIR}/as-clean.log"
echo "    docker exec -u www-data wordpress wp action-scheduler list --status=pending --group=cashback"
echo "    logrotate -d ${LOGROTATE_CONF}"
