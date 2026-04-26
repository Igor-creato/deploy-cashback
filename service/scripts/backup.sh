#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════
# Backup Script — MariaDB + WordPress + Certs
# Запуск: через cron каждые 6 часов
# ═══════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STACK_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_ROOT="/home/igor/backup"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
RETENTION_DAYS=7

# Textfile collector для node-exporter — алерт backup-stale смотрит сюда
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"

# Загрузить переменные
if [[ -f "${STACK_DIR}/.env" ]]; then
  set -a
  source "${STACK_DIR}/.env"
  set +a
fi

# Пароль из secrets
DB_ROOT_PASS=""
if [[ -f "${STACK_DIR}/secrets/db_root_password.txt" ]]; then
  DB_ROOT_PASS="$(cat "${STACK_DIR}/secrets/db_root_password.txt")"
fi

if [[ -z "$DB_ROOT_PASS" && -n "${MYSQL_ROOT_PASSWORD:-}" ]]; then
  DB_ROOT_PASS="$MYSQL_ROOT_PASSWORD"
fi

if [[ -z "$DB_ROOT_PASS" ]]; then
  echo "[ERROR] $(date): Не удалось получить пароль MariaDB"
  exit 1
fi

# ── Precondition: проверка прав (без авто-фикса) ──
# Если что-то не так — печатаем подсказку и падаем. Чинит setup-cron.sh.
PRECONDITION_OK=1
if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
  echo "[ERROR] $(date): нет прав на ${BACKUP_ROOT}. Запусти: sudo bash $(dirname "$0")/setup-cron.sh"
  PRECONDITION_OK=0
fi
if [[ -d "$TEXTFILE_DIR" ]] && [[ ! -w "$TEXTFILE_DIR" ]]; then
  echo "[WARN] $(date): нет прав на ${TEXTFILE_DIR} — метрика для алерта backup-stale не обновится."
  echo "[WARN] $(date): Запусти: sudo bash $(dirname "$0")/setup-cron.sh"
fi
if [[ "$PRECONDITION_OK" -ne 1 ]]; then
  exit 2
fi

echo "[INFO] $(date): Начало backup в ${BACKUP_DIR}"

# ── MariaDB dump ──
# MYSQL_PWD через env — пароль НЕ попадает в `ps`/cmdline (в отличие от -p<pw>).
echo "[INFO] $(date): Дамп MariaDB..."
if docker exec -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb-dump \
  -u root \
  --single-transaction \
  --routines \
  --triggers \
  --events \
  --quick \
  --lock-tables=false \
  "${MYSQL_DATABASE:-cashback_db}" 2>/dev/null | gzip > "${BACKUP_DIR}/db.sql.gz"; then
  echo "[OK] $(date): MariaDB dump: $(du -sh "${BACKUP_DIR}/db.sql.gz" | cut -f1)"
else
  echo "[ERROR] $(date): MariaDB dump failed"
fi

# ── WordPress wp-content ──
# В стеке используется bind mount ./volumes/wordpress:/var/www/html,
# а не named volume — берём путь напрямую.
echo "[INFO] $(date): Архивация wp-content..."
WP_PATH="${STACK_DIR}/volumes/wordpress"

if [[ -d "${WP_PATH}/wp-content" ]]; then
  # tar может вернуть код 1 на "file changed as we read it" — не критично,
  # архив остаётся валидным. Поэтому ловим вывод и не валим скрипт.
  WP_TAR_ERR="$(mktemp)"
  TAR_RC=0
  # GNU tar: --exclude / --warning должны идти ДО позиционного wp-content/,
  # иначе tar печатает "no effect" и выходит с кодом 2.
  tar czf "${BACKUP_DIR}/wp-content.tar.gz" \
    --exclude='wp-content/cache' \
    --exclude='wp-content/upgrade' \
    --exclude='wp-content/ai1wm-backups' \
    --warning=no-file-changed \
    --warning=no-file-removed \
    -C "${WP_PATH}" wp-content/ 2>"${WP_TAR_ERR}" || TAR_RC=$?
  if [[ "$TAR_RC" -eq 0 ]] && [[ -s "${BACKUP_DIR}/wp-content.tar.gz" ]] && gzip -t "${BACKUP_DIR}/wp-content.tar.gz" 2>/dev/null; then
    echo "[OK] $(date): wp-content: $(du -sh "${BACKUP_DIR}/wp-content.tar.gz" | cut -f1)"
  elif [[ -s "${BACKUP_DIR}/wp-content.tar.gz" ]] && gzip -t "${BACKUP_DIR}/wp-content.tar.gz" 2>/dev/null; then
    echo "[OK] $(date): wp-content (tar rc=${TAR_RC}, архив валиден): $(du -sh "${BACKUP_DIR}/wp-content.tar.gz" | cut -f1)"
  else
    echo "[ERROR] $(date): wp-content архив битый (tar rc=${TAR_RC}):"
    head -5 "${WP_TAR_ERR}" >&2 || true
  fi
  rm -f "${WP_TAR_ERR}"
else
  echo "[WARN] $(date): ${WP_PATH}/wp-content не найден, пропускаю wp-content"
fi

# ── Traefik certificates ──
if [[ -f "${STACK_DIR}/volumes/traefik/acme.json" ]]; then
  cp "${STACK_DIR}/volumes/traefik/acme.json" "${BACKUP_DIR}/acme.json"
  echo "[OK] $(date): acme.json скопирован"
fi

# ── Конфигурации ──
tar czf "${BACKUP_DIR}/configs.tar.gz" \
  -C "${STACK_DIR}" \
  docker-compose.yml \
  .env \
  volumes/traefik/ \
  volumes/nginx/ \
  volumes/php-config/ \
  volumes/mariadb/conf.d/ 2>/dev/null
echo "[OK] $(date): Конфигурации заархивированы"

# ── Ротация старых бэкапов ──
DELETED=$(find "${BACKUP_ROOT}" -maxdepth 1 -mindepth 1 -type d -mtime +${RETENTION_DAYS} -exec rm -rf {} \; -print | wc -l)
if [[ "$DELETED" -gt 0 ]]; then
  echo "[INFO] $(date): Удалено старых бэкапов: ${DELETED}"
fi

# ── Итог ──
TOTAL_SIZE="$(du -sh "${BACKUP_DIR}" | cut -f1)"
echo "[DONE] $(date): Backup завершён. Размер: ${TOTAL_SIZE}. Путь: ${BACKUP_DIR}"

# ── Textfile collector — записываем таймстамп успеха ──
# node-exporter монтирует /var/lib/node_exporter/textfile_collector → /host/textfile_collector
# и выставляет --collector.textfile.directory на эту директорию
if [[ -d "${TEXTFILE_DIR}" ]] && [[ -s "${BACKUP_DIR}/db.sql.gz" ]]; then
  TMP="$(mktemp "${TEXTFILE_DIR}/cashback_backup.prom.XXXXXX")"
  cat > "${TMP}" <<EOF
# HELP cashback_backup_last_success_timestamp_seconds Unix ts последнего успешного бэкапа MariaDB
# TYPE cashback_backup_last_success_timestamp_seconds gauge
cashback_backup_last_success_timestamp_seconds $(date +%s)
# HELP cashback_backup_size_bytes Размер последнего бэкапа в байтах
# TYPE cashback_backup_size_bytes gauge
cashback_backup_size_bytes $(du -sb "${BACKUP_DIR}" | cut -f1)
EOF
  mv "${TMP}" "${TEXTFILE_DIR}/cashback_backup.prom"
  chmod 644 "${TEXTFILE_DIR}/cashback_backup.prom"
fi
