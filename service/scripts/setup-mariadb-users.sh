#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════
#  Идемпотентная установка пароля для пользователя 'exporter'
#  после первого старта стека. Запустить ОДИН раз вручную:
#     bash scripts/setup-mariadb-users.sh
#  Безопасно перезапускать — ALTER USER идемпотентен.
# ═══════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STACK_DIR="$(dirname "$SCRIPT_DIR")"

# Точечное чтение compose-.env без `source` (regex/() в значениях ронят bash).
read_env() {
  local file="$1" key="$2" line val
  [[ -f "$file" ]] || return 0
  line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -1 || true)"
  [[ -z "$line" ]] && return 0
  val="${line#"${key}="}"
  if [[ "$val" =~ ^\"(.*)\"$ ]]; then
    val="${BASH_REMATCH[1]}"
  elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
    val="${BASH_REMATCH[1]}"
  fi
  printf '%s' "$val"
}

DB_ROOT_PASS="$(cat "${STACK_DIR}/secrets/db_root_password.txt")"
EXPORTER_CNF="${STACK_DIR}/secrets/mysql_exporter.cnf"

# Backwards compat: старые бэкапы (до перехода exporter'а на Docker secret)
# не содержат secrets/mysql_exporter.cnf, но содержат MYSQL_EXPORTER_PASSWORD
# в .env. Генерируем .cnf из .env для совместимости. После первого install.sh
# переменная из .env удаляется, но .cnf остаётся как single source of truth.
if [[ ! -f "$EXPORTER_CNF" ]]; then
  MYSQL_EXPORTER_PASSWORD="${MYSQL_EXPORTER_PASSWORD:-$(read_env "${STACK_DIR}/.env" MYSQL_EXPORTER_PASSWORD)}"
  if [[ -n "${MYSQL_EXPORTER_PASSWORD:-}" ]]; then
    cat > "$EXPORTER_CNF" <<EOF
[client]
user=exporter
password=${MYSQL_EXPORTER_PASSWORD}
EOF
    # mode 644: mysqld-exporter container runs as 'nobody', не сможет читать 600.
    # Защита через директорию secrets/ (mode 700).
    chmod 644 "$EXPORTER_CNF"
    echo "[INFO] сгенерирован ${EXPORTER_CNF} из .env (миграция со старого бэкапа)"
  else
    echo "[ERROR] не найден ${EXPORTER_CNF} и MYSQL_EXPORTER_PASSWORD в .env"
    echo "[ERROR] запустите install.sh для генерации или восстановите .cnf вручную"
    exit 1
  fi
fi

# Парсим пароль из my.cnf — single source of truth для exporter'а.
MYSQL_EXPORTER_PASSWORD="$(awk -F'=' '/^password[[:space:]]*=/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' "$EXPORTER_CNF")"

if [[ -z "${MYSQL_EXPORTER_PASSWORD:-}" ]]; then
  echo "[ERROR] не удалось прочитать password= из ${EXPORTER_CNF}"
  exit 1
fi

# Подождать пока MariaDB станет healthy
echo "[INFO] Жду MariaDB..."
for i in {1..30}; do
  if docker exec mariadb healthcheck.sh --connect &>/dev/null; then
    break
  fi
  sleep 2
done

# Установить актуальный пароль для exporter.
# MYSQL_PWD передаётся через env, чтобы пароль НЕ попадал в `ps -ef`
# и /proc/<pid>/cmdline (в отличие от `-p<password>`).
# F-S1-011: пароль передаётся через временный SQL-файл с chmod 600, который
# bind-mount'ится в контейнер read-only. Старый here-doc делал interpolation
# на стороне bash — пароль был видим в `set -x` debug-output (если кто-то
# случайно включит) и в `bash -x` traces. Файл shred'ится в trap'е ниже.
#
# MYSQL_PWD env — для root login (не светится в argv docker exec).
# Грант сужен: только PROCESS, REPLICATION CLIENT, SLAVE MONITOR, плюс SELECT
# ограниченный performance_schema. mysqld-exporter с такими правами обеспечивает
# все стандартные коллекции (--collect.global_status, --collect.global_variables,
# --collect.info_schema.processlist, --collect.info_schema.innodb_metrics).

SETUP_SQL_FILE="$(mktemp /tmp/cashback-mariadb-setup.XXXXXX.sql)"
chmod 600 "${SETUP_SQL_FILE}"
# shred при любом выходе (включая ошибки/Ctrl+C). `command -v` чтобы fall back
# на простое rm если shred недоступен.
trap '
    if command -v shred >/dev/null 2>&1; then
        shred -u "${SETUP_SQL_FILE}" 2>/dev/null || rm -f "${SETUP_SQL_FILE}"
    else
        rm -f "${SETUP_SQL_FILE}"
    fi
' EXIT INT TERM

cat >"${SETUP_SQL_FILE}" <<SQL
CREATE USER IF NOT EXISTS 'exporter'@'%' IDENTIFIED BY '${MYSQL_EXPORTER_PASSWORD}';
ALTER USER 'exporter'@'%' IDENTIFIED BY '${MYSQL_EXPORTER_PASSWORD}';
REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'exporter'@'%';
GRANT PROCESS, REPLICATION CLIENT, SLAVE MONITOR ON *.* TO 'exporter'@'%';
GRANT SELECT ON performance_schema.* TO 'exporter'@'%';
-- information_schema автоматически доступен любому пользователю как read-only;
-- явный GRANT даже от root возвращает ERROR 1044 ("Access denied to db info_schema").
FLUSH PRIVILEGES;
SQL

# Передаём содержимое файла через stdin. Преимущество над here-doc:
# bash interpolation выполняется при `cat >FILE`, не в момент `docker exec`,
# поэтому `set -x` traces не показывают пароль; здесь только перенаправление.
docker exec -i -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb -u root <"${SETUP_SQL_FILE}"

echo "[OK] Пароль пользователя 'exporter' установлен"

# Пересоздать exporter чтобы он перечитал secrets/mysql_exporter.cnf.
# Docker secrets копируются в /run/secrets при старте контейнера; rotate-secret
# через restart не вступает в силу — нужен force-recreate.
docker compose -f "${STACK_DIR}/docker-compose.yml" up -d --force-recreate --no-deps mysqld-exporter
echo "[OK] mysqld-exporter пересоздан с актуальным паролем"
