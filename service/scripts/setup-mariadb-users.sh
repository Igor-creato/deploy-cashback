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

if [[ ! -f "${STACK_DIR}/.env" ]]; then
  echo "[ERROR] .env не найден: ${STACK_DIR}/.env"
  exit 1
fi

# Загрузить переменные
set -a
source "${STACK_DIR}/.env"
set +a

DB_ROOT_PASS="$(cat "${STACK_DIR}/secrets/db_root_password.txt")"

if [[ -z "${MYSQL_EXPORTER_PASSWORD:-}" ]]; then
  echo "[ERROR] MYSQL_EXPORTER_PASSWORD не задан в .env"
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
docker exec -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb -u root -e "
  CREATE USER IF NOT EXISTS 'exporter'@'%' IDENTIFIED BY '${MYSQL_EXPORTER_PASSWORD}';
  ALTER USER 'exporter'@'%' IDENTIFIED BY '${MYSQL_EXPORTER_PASSWORD}';
  GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'%';
  FLUSH PRIVILEGES;
"

echo "[OK] Пароль пользователя 'exporter' установлен"

# Пересоздать exporter чтобы он подхватил актуальный MYSQL_EXPORTER_PASSWORD из .env.
# `restart` тут не подходит — он использует env, зафиксированный в момент создания
# контейнера, а не текущее значение из .env. force-recreate перечитывает .env.
docker compose -f "${STACK_DIR}/docker-compose.yml" up -d --force-recreate --no-deps mysqld-exporter
echo "[OK] mysqld-exporter пересоздан с актуальным паролем"
