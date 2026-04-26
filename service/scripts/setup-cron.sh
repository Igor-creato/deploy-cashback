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

# Проверка синтаксиса logrotate
if ! logrotate -d "$LOGROTATE_CONF" &>/dev/null; then
  warn "logrotate -d вернул ошибку — проверьте вручную: logrotate -d ${LOGROTATE_CONF}"
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
# Бэкап-задача указывает на единый скрипт верхнего уровня (stack + webhook-receiver).
# Если umbrella ещё не развёрнут, fallback на старый stack-only backup.sh.
ROOT_DIR="$(cd "${INSTALL_DIR}/.." && pwd)"
if [[ -f "${ROOT_DIR}/scripts/backup-all.sh" ]]; then
  CRON_BACKUP="0 */6 * * * bash ${ROOT_DIR}/scripts/backup-all.sh >> /var/log/backup.log 2>&1"
else
  CRON_BACKUP="0 */6 * * * bash ${INSTALL_DIR}/scripts/backup.sh >> /var/log/backup.log 2>&1"
fi

# ─── Снимаем старые маркированные блоки + legacy-строки ──
TMP_CRON="$(mktemp)"
trap 'rm -f "$TMP_CRON"' EXIT

# Экспортируем существующий crontab (без ошибки, если его нет)
crontab -u "$REAL_USER" -l 2>/dev/null > "$TMP_CRON" || true

# 1. Удалить весь блок от маркера до следующей пустой строки / EOF
if grep -qF "$MARKER" "$TMP_CRON"; then
  awk -v marker="$MARKER" '
    BEGIN { skip=0 }
    index($0, marker) { skip=1; next }
    skip && /^$/ { skip=0; next }
    !skip { print }
  ' "$TMP_CRON" > "${TMP_CRON}.new" && mv "${TMP_CRON}.new" "$TMP_CRON"
fi

# 2. Удалить отдельные legacy-строки (если остались вне блока)
for pattern in "${LEGACY_PATTERNS[@]}"; do
  grep -vF -- "$pattern" "$TMP_CRON" > "${TMP_CRON}.new" || true
  mv "${TMP_CRON}.new" "$TMP_CRON"
done

# 3. Добавить новый маркированный блок в конец (с гарантированным разделителем)
printf '\n%s\n%s\n%s\n%s\n\n' "$MARKER" "$CRON_AS" "$CRON_WP" "$CRON_BACKUP" >> "$TMP_CRON"

# ─── Записать crontab ────────────────────────────────────
crontab -u "$REAL_USER" "$TMP_CRON"
log "Crontab обновлён (3 задачи + маркер)"

# ─── Показать итог ───────────────────────────────────────
echo ""
info "Текущий crontab ${REAL_USER}:"
crontab -u "$REAL_USER" -l | sed 's/^/    /'

echo ""
log "Готово."
echo ""
info "Проверка:"
echo "    tail -f ${LOG_DIR}/action-scheduler.log"
echo "    docker exec -u www-data wordpress wp action-scheduler list --status=pending --group=cashback"
echo "    logrotate -d ${LOGROTATE_CONF}"
