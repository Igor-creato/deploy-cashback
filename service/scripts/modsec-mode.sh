#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════
#  Cashback Stack — ModSecurity rule engine toggle (A1-3)
#
#  Идемпотентно переключает MODSEC_RULE_ENGINE между
#  On / DetectionOnly через service/.env. Перезапускает только
#  modsecurity-сервис (другие контейнеры не трогаются).
#
#  Использование (из service/):
#    sudo bash scripts/modsec-mode.sh on
#    sudo bash scripts/modsec-mode.sh off
#    sudo bash scripts/modsec-mode.sh status
#
#  Перед `on` рекомендуется проверить modsec_audit.log на ложные
#  срабатывания (false positives) на admin-AJAX / WC-checkout /
#  cashback-extension. Скрипт `status` показывает последние
#  audit-сообщения если они есть.
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

KEY="MODSEC_RULE_ENGINE"
SERVICE="modsecurity"

usage() {
  cat <<EOF
Usage: sudo bash scripts/modsec-mode.sh <command>

Commands:
  on       — set ${KEY}=On в .env и перезапустить ${SERVICE}
             (XSS/SQLi блокируются с HTTP 403)
  off      — set ${KEY}=DetectionOnly в .env и перезапустить ${SERVICE}
             (только запись в audit log без блокировки)
  status   — показать текущее значение и последние audit-записи

Логи:
  docker logs modsecurity 2>&1 | tail -50
  service/volumes/modsec-logs/modsec_audit.log    (только при relevant 4xx/5xx)
EOF
  exit 1
}

[[ $# -ge 1 ]] || usage
ACTION="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$(dirname "${SCRIPT_DIR}")"
ENV_FILE="${SERVICE_DIR}/.env"
COMPOSE_FILE="${SERVICE_DIR}/docker-compose.yml"

[[ -f "${COMPOSE_FILE}" ]] || { err "docker-compose.yml не найден: ${COMPOSE_FILE}"; exit 1; }

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
  if grep -qE "^${KEY}=" "${ENV_FILE}"; then
    sed -i.bak -E "/^${KEY}=/d" "${ENV_FILE}"
    rm -f "${ENV_FILE}.bak"
  fi
  echo "${KEY}=${val}" >> "${ENV_FILE}"
}

restart_service() {
  info "Перезапуск ${SERVICE}..."
  ( cd "${SERVICE_DIR}" && docker compose up -d "${SERVICE}" )
  log "${SERVICE} перезапущен."
}

show_recent_audit() {
  local audit="${SERVICE_DIR}/volumes/modsec-logs/modsec_audit.log"
  if [[ -f "${audit}" && -s "${audit}" ]]; then
    info "Последние 5 audit-событий из ${audit#${SERVICE_DIR}/}:"
    if command -v jq >/dev/null 2>&1; then
      tail -5 "${audit}" | jq -r '
        .transaction.time_stamp
        + " " + .transaction.client_ip
        + " → " + (.transaction.request.uri // "?")
        + "  [" + (.transaction.response.http_code | tostring) + "]"
        + "  rules=" + ((.transaction.messages | length) | tostring)
      ' 2>/dev/null || tail -5 "${audit}"
    else
      tail -5 "${audit}"
    fi
  else
    info "Нет записей в modsec_audit.log (ничего relevant ещё не сработало)."
    info "  ModSec фильтрует по статусам ^(?:5|4(?!04|03)) — 200/302/404/403 не пишутся."
  fi
}

case "${ACTION}" in
  on)
    set_value "On"
    log "${KEY}=On в .env."
    restart_service
    sleep 2
    info "ModSec теперь блокирует подозрительные запросы (HTTP 403)."
    info "Тест:  curl -I 'https://${DOMAIN:-<your-domain>}/?test=<script>alert(1)</script>'"
    info "Если что-то ломается — откат:  sudo bash scripts/modsec-mode.sh off"
    show_recent_audit
    ;;
  off)
    set_value "DetectionOnly"
    log "${KEY}=DetectionOnly в .env."
    restart_service
    info "ModSec в режиме наблюдения, блокировки выключены."
    ;;
  status)
    val_env="$(current_value)"
    val_env="${val_env:-<не задан, используется default DetectionOnly>}"
    info ".env: ${KEY}=${val_env}"
    if docker inspect "${SERVICE}" >/dev/null 2>&1; then
      val_container="$(docker exec "${SERVICE}" sh -c "echo \$${KEY}" 2>/dev/null || echo "?")"
      val_container="${val_container:-<пусто>}"
      info "running ${SERVICE} container: ${KEY}=${val_container}"
    else
      warn "${SERVICE} контейнер не запущен."
    fi
    show_recent_audit
    ;;
  *)
    usage
    ;;
esac
