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

DB_ROOT_PASS="$(cat "${STACK_DIR}/secrets/db_root_password.txt")"
EXPORTER_CNF="${STACK_DIR}/secrets/mysql_exporter.cnf"

# Backwards compat: старые бэкапы (до перехода exporter'а на Docker secret)
# не содержат secrets/mysql_exporter.cnf, но содержат MYSQL_EXPORTER_PASSWORD
# в .env. Генерируем .cnf из .env для совместимости. После первого install.sh
# переменная из .env удаляется, но .cnf остаётся как single source of truth.
if [[ ! -f "$EXPORTER_CNF" ]]; then
  if [[ -f "${STACK_DIR}/.env" ]]; then
    # shellcheck disable=SC1091
    set -a; source "${STACK_DIR}/.env"; set +a
  fi
  if [[ -n "${MYSQL_EXPORTER_PASSWORD:-}" ]]; then
    cat > "$EXPORTER_CNF" <<EOF
[client]
user=exporter
password=${MYSQL_EXPORTER_PASSWORD}
EOF
    chmod 600 "$EXPORTER_CNF"
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
# Пароль передаём через stdin (here-doc), чтобы не светить его в argv `docker exec`
# (виден в `ps -ef` хоста и в /proc/<pid>/cmdline). MYSQL_PWD — для root login.
# Грант сужен: только PROCESS, REPLICATION CLIENT, SLAVE MONITOR, плюс SELECT
# ограниченный performance_schema. mysqld-exporter с такими правами обеспечивает
# все стандартные коллекции (--collect.global_status, --collect.global_variables,
# --collect.info_schema.processlist, --collect.info_schema.innodb_metrics).
docker exec -i -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb -u root <<SQL
CREATE USER IF NOT EXISTS 'exporter'@'%' IDENTIFIED BY '${MYSQL_EXPORTER_PASSWORD}';
ALTER USER 'exporter'@'%' IDENTIFIED BY '${MYSQL_EXPORTER_PASSWORD}';
REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'exporter'@'%';
GRANT PROCESS, REPLICATION CLIENT, SLAVE MONITOR ON *.* TO 'exporter'@'%';
GRANT SELECT ON performance_schema.* TO 'exporter'@'%';
GRANT SELECT ON information_schema.* TO 'exporter'@'%';
FLUSH PRIVILEGES;
SQL

echo "[OK] Пароль пользователя 'exporter' установлен"

# Пересоздать exporter чтобы он перечитал secrets/mysql_exporter.cnf.
# Docker secrets копируются в /run/secrets при старте контейнера; rotate-secret
# через restart не вступает в силу — нужен force-recreate.
docker compose -f "${STACK_DIR}/docker-compose.yml" up -d --force-recreate --no-deps mysqld-exporter
echo "[OK] mysqld-exporter пересоздан с актуальным паролем"
