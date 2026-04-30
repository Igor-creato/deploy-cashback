#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════
#  Cashback Stack — WP debug log toggle (E2E follow-up A1-4)
#
#  Идемпотентно включает/выключает запись plugin'овых error_log()
#  в /var/www/html/wp-content/debug.log через переменную
#  WP_DEBUG_ENABLE в service/.env.
#
#  Использование (из service/):
#    sudo bash scripts/wp-debug-log.sh on
#    sudo bash scripts/wp-debug-log.sh off
#    sudo bash scripts/wp-debug-log.sh status
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

KEY="WP_DEBUG_ENABLE"
SERVICE="wordpress"

usage() {
  cat <<EOF
Usage: sudo bash scripts/wp-debug-log.sh <command>

Commands:
  on       — set ${KEY}=1 в .env и перезапустить ${SERVICE}
  off      — set ${KEY}=0 в .env и перезапустить ${SERVICE}
  status   — показать текущее значение в .env и в running контейнере

Логи после включения:
  service/volumes/wordpress/wp-content/debug.log
EOF
  exit 1
}

[[ $# -ge 1 ]] || usage
ACTION="$1"

# Где находится .env — рядом с docker-compose.yml.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(dirname "${SCRIPT_DIR}")"
ENV_FILE="${SERVICE_DIR}/.env"
COMPOSE_FILE="${SERVICE_DIR}/docker-compose.yml"

[[ -f "${COMPOSE_FILE}" ]] || { err "docker-compose.yml не найден: ${COMPOSE_FILE}"; exit 1; }

# Создаём .env если нет.
if [[ ! -f "${ENV_FILE}" ]]; then
  touch "${ENV_FILE}"
  chmod 0600 "${ENV_FILE}"
  info ".env создан (0600)."
fi

current_value() {
  grep -E "^${KEY}=" "${ENV_FILE}" 2>/dev/null | tail -1 | sed -E "s/^${KEY}=//; s/^['\"]//; s/['\"]$//"
}

set_value() {
  local val="$1"
  # Удаляем все существующие строки с ключом, добавляем одну новую.
  if grep -qE "^${KEY}=" "${ENV_FILE}"; then
    # sed -i для idempotent правки.
    sed -i.bak -E "/^${KEY}=/d" "${ENV_FILE}"
    rm -f "${ENV_FILE}.bak"
  fi
  echo "${KEY}=${val}" >> "${ENV_FILE}"
}

restart_service() {
  info "Перезапуск ${SERVICE} с новой переменной..."
  ( cd "${SERVICE_DIR}" && docker compose up -d "${SERVICE}" )
  log "${SERVICE} перезапущен."
}

case "${ACTION}" in
  on)
    set_value "1"
    log "${KEY}=1 в .env."
    restart_service
    info "После первого error_log()-вызова появится файл:"
    info "  ${SERVICE_DIR}/volumes/wordpress/wp-content/debug.log"
    info "Тест:  docker exec wordpress sh -c 'php -r \"error_log(\\\"test \$(date)\\\");\"'"
    ;;
  off)
    set_value "0"
    log "${KEY}=0 в .env."
    restart_service
    info "Plugin'овые error_log() снова идут в stderr контейнера."
    info "  docker logs wordpress 2>&1 | tail"
    ;;
  status)
    val_env="$(current_value)"
    val_env="${val_env:-<не задан>}"
    info ".env (${ENV_FILE}): ${KEY}=${val_env}"
    if docker inspect "${SERVICE}" >/dev/null 2>&1; then
      val_container="$(docker exec "${SERVICE}" sh -c "echo \$${KEY}" 2>/dev/null || echo "?")"
      val_container="${val_container:-<пусто>}"
      info "running ${SERVICE} container: ${KEY}=${val_container}"
    else
      warn "${SERVICE} контейнер не запущен — статус container не проверен."
    fi
    log_file="${SERVICE_DIR}/volumes/wordpress/wp-content/debug.log"
    if [[ -f "${log_file}" ]]; then
      size="$(du -h "${log_file}" | cut -f1)"
      info "debug.log: существует, размер ${size}"
    else
      info "debug.log: отсутствует (либо отключено, либо ещё не было записей)"
    fi
    ;;
  *)
    usage
    ;;
esac
