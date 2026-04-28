#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════
#  Чистит таблицу cashback_webhooks от успешно обработанных
#  записей старше 30 дней. Выполняется батчами LIMIT 5000,
#  пока есть что удалять — backlog после downtime тоже подчистится.
#  Failed/error-записи оставляем для форензики и ручного re-process'а.
#
#  Запускается из cron под root:
#     33 4 * * * /path/to/scripts/cleanup-webhooks.sh
# ═══════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STACK_DIR="$(dirname "$SCRIPT_DIR")"
SECRET_FILE="${STACK_DIR}/secrets/db_password.txt"

if [[ ! -r "$SECRET_FILE" ]]; then
  echo "[ERROR] $(date '+%F %T'): не читается ${SECRET_FILE}" >&2
  exit 1
fi

# Берём имя БД из .env, default = cashback_db
DB_NAME="cashback_db"
if [[ -f "${STACK_DIR}/.env" ]]; then
  v="$(grep -E '^MYSQL_DATABASE=' "${STACK_DIR}/.env" | cut -d= -f2-)"
  [[ -n "$v" ]] && DB_NAME="$v"
fi

DB_USER="cashback_user"
if [[ -f "${STACK_DIR}/.env" ]]; then
  v="$(grep -E '^MYSQL_USER=' "${STACK_DIR}/.env" | cut -d= -f2-)"
  [[ -n "$v" ]] && DB_USER="$v"
fi

BATCH=5000
MAX_BATCHES=20  # safety limit: до 100k строк за один запуск
total=0

for ((i=1; i<=MAX_BATCHES; i++)); do
  # MariaDB CLI выводит ROW_COUNT() как одну строку с числом.
  # Передаём пароль через MYSQL_PWD (не argv) и SQL через stdin (не -e).
  rows=$(docker exec -i -e MYSQL_PWD="$(cat "$SECRET_FILE")" \
    mariadb mariadb -u "$DB_USER" -N -B "$DB_NAME" <<SQL 2>&1
DELETE FROM cashback_webhooks
WHERE received_at < NOW() - INTERVAL 30 DAY
  AND processing_status = 'ok'
LIMIT ${BATCH};
SELECT ROW_COUNT();
SQL
)
  # последняя строка вывода — ROW_COUNT()
  affected=$(echo "$rows" | tail -1 | tr -dc '0-9')
  if [[ -z "$affected" ]]; then
    echo "[WARN] $(date '+%F %T'): batch $i: не удалось распарсить ROW_COUNT(): $rows" >&2
    break
  fi
  total=$((total + affected))
  if [[ "$affected" -lt "$BATCH" ]]; then
    break
  fi
done

echo "[OK] $(date '+%F %T'): cleanup-webhooks: удалено ${total} строк за ${i} батчей"
