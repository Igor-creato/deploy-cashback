#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════
# Unified Backup — stack (WP + MariaDB + Traefik) + webhook-receiver
# Запуск: вручную или через cron каждые 6 часов
#   bash /opt/cashback/scripts/backup-all.sh
# ═══════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Конфигурация (переопределяется в ${ROOT_DIR}/cashback.env или через env-var):
#   STACK_DIR / WEBHOOK_DIR — пути к стекам
#   STACK_PROJECT / WEBHOOK_PROJECT — docker compose project names
#   WEBHOOK_VOL — имя volume с config.json (по умолчанию ${WEBHOOK_PROJECT}_app_data)
#   BACKUP_ROOT — куда складывать архивы
if [[ -f "${ROOT_DIR}/cashback.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/cashback.env"
  set +a
fi

STACK_DIR="${STACK_DIR:-${ROOT_DIR}/service}"
WEBHOOK_DIR="${WEBHOOK_DIR:-${ROOT_DIR}/postback}"

# Относительные имена (например "service" из cashback.env) резолвим
# относительно ROOT_DIR, абсолютные пути оставляем как есть.
[[ "$STACK_DIR"   != /* ]] && STACK_DIR="${ROOT_DIR}/${STACK_DIR}"
[[ "$WEBHOOK_DIR" != /* ]] && WEBHOOK_DIR="${ROOT_DIR}/${WEBHOOK_DIR}"

STACK_PROJECT="${STACK_PROJECT:-$(basename "$STACK_DIR")}"
WEBHOOK_PROJECT="${WEBHOOK_PROJECT:-$(basename "$WEBHOOK_DIR")}"
WEBHOOK_VOL="${WEBHOOK_VOL:-${WEBHOOK_PROJECT}_app_data}"
GRAFANA_VOL="${GRAFANA_VOL:-${STACK_PROJECT}_grafana_data}"
BACKUP_ROOT="${BACKUP_ROOT:-/opt/backups}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
RETENTION_COUNT="${BACKUP_RETENTION_COUNT:-14}"

TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

if [[ ! -d "$STACK_DIR" ]]; then
  echo "[ERROR] $(ts): не найден ${STACK_DIR}" >&2
  exit 1
fi

# ─── Загрузка stack/.env ────────────────────────────────────
if [[ -f "${STACK_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${STACK_DIR}/.env"
  set +a
fi

# ─── Пароль root MariaDB ────────────────────────────────────
DB_ROOT_PASS=""
if [[ -f "${STACK_DIR}/secrets/db_root_password.txt" ]]; then
  DB_ROOT_PASS="$(cat "${STACK_DIR}/secrets/db_root_password.txt")"
fi
if [[ -z "$DB_ROOT_PASS" && -n "${MYSQL_ROOT_PASSWORD:-}" ]]; then
  DB_ROOT_PASS="$MYSQL_ROOT_PASSWORD"
fi
if [[ -z "$DB_ROOT_PASS" ]]; then
  echo "[ERROR] $(ts): не удалось получить пароль MariaDB" >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"   # внутри лежат secrets и acme.json — не для чужих глаз
echo "[INFO] $(ts): начало backup → ${BACKUP_DIR}"

DB_OK=0
WP_OK=0
WEBHOOK_DATA_OK=0
GRAFANA_OK=0

# ─── 1. MariaDB dump ────────────────────────────────────────
echo "[INFO] $(ts): дамп MariaDB..."
if docker exec -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb-dump \
  -u root \
  --single-transaction \
  --routines \
  --triggers \
  --events \
  --quick \
  --lock-tables=false \
  "${MYSQL_DATABASE:-cashback_db}" 2>/dev/null | gzip > "${BACKUP_DIR}/db.sql.gz"; then
  echo "[OK] $(ts): MariaDB dump: $(du -sh "${BACKUP_DIR}/db.sql.gz" | cut -f1)"
  DB_OK=1
else
  echo "[ERROR] $(ts): MariaDB dump failed" >&2
fi

# ─── 2. wp-content (bind mount) ─────────────────────────────
# tar exit 1 = "файл изменился при чтении" — частая норма для живого WP
# (сессии, error_log, ai1wm). Не считаем это фатальным.
# При ошибке выводим первые строки stderr для диагностики.
safe_tar() {
  local label="$1"; shift
  local ec=0
  local err_log; err_log="$(mktemp)"
  tar "$@" 2>"$err_log" || ec=$?
  case "$ec" in
    0)
      rm -f "$err_log"
      return 0
      ;;
    1)
      echo "[WARN] $(ts): ${label}: tar exit 1 (файлы менялись во время чтения) — продолжаю"
      if [[ -s "$err_log" ]]; then
        echo "[WARN] $(ts): ${label}: первые строки stderr:"
        head -5 "$err_log" | sed 's/^/    /'
      fi
      rm -f "$err_log"
      return 0
      ;;
    *)
      echo "[ERROR] $(ts): ${label}: tar exit ${ec}" >&2
      if [[ -s "$err_log" ]]; then
        echo "[ERROR] $(ts): ${label}: stderr (первые 20 строк):" >&2
        head -20 "$err_log" | sed 's/^/    /' >&2
      fi
      rm -f "$err_log"
      return "$ec"
      ;;
  esac
}

WP_ROOT="${STACK_DIR}/volumes/wordpress"
if [[ -d "$WP_ROOT" ]]; then
  echo "[INFO] $(ts): архивация всего каталога wordpress..."
  # Архивируем ВЕСЬ /var/www/html (ядро WP + wp-content), иначе при restore
  # официальный entrypoint образа докладывает недостающее из /usr/src/wordpress/
  # — в т.ч. возвращает удалённые Hello Dolly / Akismet и default-темы.
  if safe_tar "wordpress-files" czf "${BACKUP_DIR}/wordpress-files.tar.gz" \
      --exclude='./wp-content/cache' \
      --exclude='./wp-content/upgrade' \
      --exclude='./wp-content/ai1wm-backups' \
      -C "${WP_ROOT}" .; then
    echo "[OK] $(ts): wordpress-files: $(du -sh "${BACKUP_DIR}/wordpress-files.tar.gz" | cut -f1)"
    WP_OK=1
  fi
else
  echo "[WARN] $(ts): не найден ${WP_ROOT}, пропускаю wordpress-files"
fi

# ─── 3. Traefik certs ───────────────────────────────────────
if [[ -f "${STACK_DIR}/volumes/traefik/acme.json" ]]; then
  cp "${STACK_DIR}/volumes/traefik/acme.json" "${BACKUP_DIR}/acme.json"
  echo "[OK] $(ts): acme.json скопирован"
fi

# ─── 4. stack configs (включая secrets — нужны для restore на новом хосте) ──
# Базовый набор: всегда обязательные файлы. Затем условно добавляем
# директории, которые могут отсутствовать в dev-окружениях.
STACK_CONFIG_PATHS=(docker-compose.yml .env)
for d in \
    volumes/traefik \
    volumes/nginx \
    volumes/php-config \
    volumes/mariadb/conf.d \
    volumes/mariadb/initdb.d \
    volumes/grafana/provisioning \
    volumes/grafana/dashboards \
    volumes/vector \
    volumes/modsecurity/local-rules \
    volumes/crowdsec \
    volumes/victoriametrics \
    secrets; do
  [[ -d "${STACK_DIR}/${d}" ]] && STACK_CONFIG_PATHS+=("${d}/")
done
if safe_tar "stack-configs" czf "${BACKUP_DIR}/stack-configs.tar.gz" \
    -C "${STACK_DIR}" \
    "${STACK_CONFIG_PATHS[@]}"; then
  chmod 600 "${BACKUP_DIR}/stack-configs.tar.gz"
  echo "[OK] $(ts): stack-configs заархивированы ($(du -sh "${BACKUP_DIR}/stack-configs.tar.gz" | cut -f1))"
else
  echo "[ERROR] $(ts): stack-configs архивация провалилась" >&2
  exit 1
fi

# ─── 5. webhook-receiver app_data (named volume) ────────────
if [[ -d "$WEBHOOK_DIR" ]]; then
  if docker volume inspect "$WEBHOOK_VOL" >/dev/null 2>&1; then
    echo "[INFO] $(ts): архивация ${WEBHOOK_VOL}..."
    if docker run --rm \
      -v "${WEBHOOK_VOL}:/data:ro" \
      -v "${BACKUP_DIR}:/backup" \
      alpine:3.20 \
      sh -c "tar czf /backup/webhook-app_data.tar.gz -C /data ." 2>/dev/null; then
      echo "[OK] $(ts): webhook-app_data: $(du -sh "${BACKUP_DIR}/webhook-app_data.tar.gz" | cut -f1)"
      WEBHOOK_DATA_OK=1
    else
      echo "[ERROR] $(ts): архивация webhook-app_data failed" >&2
    fi
  else
    echo "[WARN] $(ts): volume ${WEBHOOK_VOL} не найден, пропускаю"
  fi

  # ─── 6. webhook-receiver configs ──────────────────────────
  if [[ -f "${WEBHOOK_DIR}/docker-compose.yml" ]]; then
    WEBHOOK_FILES=(docker-compose.yml)
    [[ -f "${WEBHOOK_DIR}/.env" ]] && WEBHOOK_FILES+=(.env)
    if safe_tar "webhook-configs" czf "${BACKUP_DIR}/webhook-configs.tar.gz" \
        -C "${WEBHOOK_DIR}" "${WEBHOOK_FILES[@]}"; then
      echo "[OK] $(ts): webhook-configs заархивированы"
    fi
  fi
else
  echo "[WARN] $(ts): не найден ${WEBHOOK_DIR}, пропускаю webhook-блок"
fi

# ─── 7. Grafana data (named volume) ─────────────────────────
# Дашборды, история алертов, аннотации, пользователи. Provisioning-yaml
# уже в stack-configs, но runtime-состояние Grafana только в этом volume.
if docker volume inspect "$GRAFANA_VOL" >/dev/null 2>&1; then
  echo "[INFO] $(ts): архивация ${GRAFANA_VOL}..."
  if docker run --rm \
    -v "${GRAFANA_VOL}:/data:ro" \
    -v "${BACKUP_DIR}:/backup" \
    alpine:3.20 \
    sh -c "tar czf /backup/grafana-data.tar.gz -C /data ." 2>/dev/null; then
    echo "[OK] $(ts): grafana-data: $(du -sh "${BACKUP_DIR}/grafana-data.tar.gz" | cut -f1)"
    GRAFANA_OK=1
  else
    echo "[ERROR] $(ts): архивация grafana-data failed" >&2
  fi
else
  echo "[WARN] $(ts): volume ${GRAFANA_VOL} не найден, пропускаю grafana-data"
fi

# ─── 7. Ротация ─────────────────────────────────────────────
# Оставляем только RETENTION_COUNT самых свежих timestamped-каталогов
# (имя = YYYYMMDD_HHMMSS, сортируется лексикографически = хронологически).
# Случайные файлы/папки иного формата (lost+found, ручные дампы) не трогаем.
DELETED=0
while IFS= read -r old; do
  rm -rf "${BACKUP_ROOT:?}/${old}" && DELETED=$((DELETED + 1))
done < <(
  find "${BACKUP_ROOT}" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null \
    | grep -E '^[0-9]{8}_[0-9]{6}$' \
    | sort -r \
    | tail -n +$((RETENTION_COUNT + 1))
)
if [[ "$DELETED" -gt 0 ]]; then
  echo "[INFO] $(ts): удалено старых бэкапов: ${DELETED} (оставлено ${RETENTION_COUNT})"
fi

TOTAL_SIZE="$(du -sh "${BACKUP_DIR}" | cut -f1)"
echo "[DONE] $(ts): backup завершён. Размер: ${TOTAL_SIZE}. Путь: ${BACKUP_DIR}"

# ─── 8. Textfile-метрика для node-exporter ──────────────────
# Считаем backup успешным, если БД дампнулась (главный артефакт).
if [[ -d "${TEXTFILE_DIR}" && "$DB_OK" -eq 1 ]]; then
  TMP="$(mktemp "${TEXTFILE_DIR}/cashback_backup.prom.XXXXXX")"
  cat > "${TMP}" <<EOF
# HELP cashback_backup_last_success_timestamp_seconds Unix ts последнего успешного бэкапа
# TYPE cashback_backup_last_success_timestamp_seconds gauge
cashback_backup_last_success_timestamp_seconds $(date +%s)
# HELP cashback_backup_size_bytes Размер последнего бэкапа в байтах
# TYPE cashback_backup_size_bytes gauge
cashback_backup_size_bytes $(du -sb "${BACKUP_DIR}" | cut -f1)
# HELP cashback_backup_component_ok Статус компонентов бэкапа (1=ok, 0=skipped/failed)
# TYPE cashback_backup_component_ok gauge
cashback_backup_component_ok{component="db"} ${DB_OK}
cashback_backup_component_ok{component="wp_content"} ${WP_OK}
cashback_backup_component_ok{component="webhook_data"} ${WEBHOOK_DATA_OK}
cashback_backup_component_ok{component="grafana_data"} ${GRAFANA_OK}
EOF
  mv "${TMP}" "${TEXTFILE_DIR}/cashback_backup.prom"
  chmod 644 "${TEXTFILE_DIR}/cashback_backup.prom"
fi
