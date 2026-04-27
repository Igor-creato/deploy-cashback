#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════
# Развёртывание ОБОИХ стеков на чистом сервере из бэкапа.
# Тонкая обёртка над restore-all.sh: pre-flight + smoke-test.
#
# Предусловия:
#   1. Папки stack/ и webhook-receiver/ уже скопированы (source code,
#      Dockerfile, install.sh) — обычно через git clone.
#   2. Бэкап перенесён на сервер (BACKUP_DIR содержит 4 обязательных
#      артефакта: db.sql.gz, stack-configs.tar.gz, webhook-configs.tar.gz,
#      webhook-app_data.tar.gz; wp-content.tar.gz опционален).
#
# Запуск:
#   sudo bash /home/igor/deploy-from-backup.sh /home/igor/backup/<timestamp>
# ═══════════════════════════════════════════════════════════

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Дефолты из cashback.env
if [[ -f "${ROOT_DIR}/cashback.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/cashback.env"
  set +a
fi

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[1;33m'; CYN=$'\033[0;36m'; NC=$'\033[0m'
log()  { printf '%s[✓]%s %s\n' "$GRN" "$NC" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YLW" "$NC" "$*"; }
err()  { printf '%s[✗]%s %s\n' "$RED" "$NC" "$*" >&2; }
info() { printf '%s[i]%s %s\n' "$CYN" "$NC" "$*"; }

# ─── Helpers (структура та же, что в install-all.sh) ───────
ask() {
  local prompt="$1" default="${2:-}" var
  if [[ -n "$default" ]]; then
    read -rp "$prompt [$default]: " var
    printf '%s' "${var:-$default}"
  else
    while :; do
      read -rp "$prompt: " var
      [[ -n "$var" ]] && { printf '%s' "$var"; return; }
      err "значение не может быть пустым"
    done
  fi
}
resolve_dir() {
  local v="$1"; v="${v%/}"
  if [[ "$v" == /* ]]; then printf '%s' "$v"; else printf '%s' "${ROOT_DIR}/${v}"; fi
}

# ─── Аргументы ──────────────────────────────────────────────
BACKUP_DIR="${1:-}"
[[ -n "$BACKUP_DIR" ]] || { err "укажите путь к бэкапу: $0 /home/igor/backup/<timestamp>"; exit 1; }
[[ -d "$BACKUP_DIR" ]] || { err "папка бэкапа не существует: $BACKUP_DIR"; exit 1; }
BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"

# ─── Pre-flight ─────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { err "запуск только от root: sudo bash $0 $BACKUP_DIR"; exit 1; }
command -v docker >/dev/null || { err "docker не найден"; exit 1; }
docker compose version >/dev/null 2>&1 || { err "docker compose v2 не найден"; exit 1; }

[[ -f "${ROOT_DIR}/restore-all.sh" ]] || { err "не найден ${ROOT_DIR}/restore-all.sh"; exit 1; }

# ─── Валидация артефактов бэкапа ────────────────────────────
need_files=(db.sql.gz stack-configs.tar.gz webhook-configs.tar.gz webhook-app_data.tar.gz)
for f in "${need_files[@]}"; do
  [[ -f "${BACKUP_DIR}/${f}" ]] || { err "в бэкапе отсутствует: ${f}"; exit 1; }
done

# ─── Выбор каталогов стеков ─────────────────────────────────
echo
info "Куда разворачивать стеки? (Enter — взять дефолт из cashback.env)"

stack_default="${STACK_DIR:-}"
if [[ -z "$stack_default" ]]; then
  for c in service site site1 stack wordpress wp cashback; do
    [[ -d "${ROOT_DIR}/${c}" ]] && { stack_default="$c"; break; }
  done
fi
stack_input=$(ask "  папка stack" "${stack_default:-service}")
STACK_DIR=$(resolve_dir "$stack_input")

webhook_default="${WEBHOOK_DIR:-}"
if [[ -z "$webhook_default" ]]; then
  for c in postback webhook-receiver webhook hooks; do
    [[ -d "${ROOT_DIR}/${c}" ]] && { webhook_default="$c"; break; }
  done
fi
webhook_input=$(ask "  папка webhook-receiver" "${webhook_default:-postback}")
WEBHOOK_DIR=$(resolve_dir "$webhook_input")

STACK_PROJECT="${STACK_PROJECT:-$(basename "$STACK_DIR")}"
WEBHOOK_PROJECT="${WEBHOOK_PROJECT:-$(basename "$WEBHOOK_DIR")}"
WEBHOOK_VOL="${WEBHOOK_VOL:-${WEBHOOK_PROJECT}_app_data}"

# ─── Source-code check ─────────────────────────────────────
# Папки должны быть на месте до restore: docker compose build требует
# Dockerfile/build-context, иначе up упадёт.
missing_src=0
if [[ ! -f "${STACK_DIR}/Dockerfile" ]] && [[ ! -f "${STACK_DIR}/docker-compose.yml" ]]; then
  err "${STACK_DIR}/ пуст или нет Dockerfile/docker-compose.yml"
  missing_src=1
fi
if [[ ! -f "${WEBHOOK_DIR}/install.sh" ]] && [[ ! -f "${WEBHOOK_DIR}/docker-compose.yml" ]]; then
  err "${WEBHOOK_DIR}/ пуст или нет install.sh/docker-compose.yml"
  missing_src=1
fi
if [[ "$missing_src" -ne 0 ]]; then
  err "сначала скопируйте папки стеков (git clone <repo> или scp), потом запускайте deploy"
  exit 1
fi

# ─── Резюме и подтверждение ────────────────────────────────
echo
info "восстановление из:   ${BACKUP_DIR}"
info "STACK_DIR:           ${STACK_DIR}    (project: ${STACK_PROJECT})"
info "WEBHOOK_DIR:         ${WEBHOOK_DIR}  (project: ${WEBHOOK_PROJECT})"
info "WEBHOOK_VOL:         ${WEBHOOK_VOL}"
echo
warn "ОПЕРАЦИЯ ПЕРЕЗАПИШЕТ:"
warn "  - configs/secrets/wp-content в ${STACK_DIR}/"
warn "  - configs/.env в ${WEBHOOK_DIR}/"
warn "  - БД в MariaDB"
warn "  - docker volume ${WEBHOOK_VOL} (будет удалён и пересоздан)"
[[ -f "${BACKUP_DIR}/grafana-data.tar.gz" ]] && \
  warn "  - docker volume ${STACK_PROJECT}_grafana_data (будет удалён и пересоздан из бэкапа)"
echo
read -rp "введите 'DEPLOY' для подтверждения: " ans
[[ "$ans" == "DEPLOY" ]] || { info "отмена"; exit 0; }

# ─── Делегируем restore-all.sh ─────────────────────────────
echo
info "═══ запуск restore-all.sh ═══"
export STACK_DIR WEBHOOK_DIR STACK_PROJECT WEBHOOK_PROJECT WEBHOOK_VOL
export RESTORE_CONFIRMED=1
bash "${ROOT_DIR}/restore-all.sh" "$BACKUP_DIR"

# ─── Smoke-test ────────────────────────────────────────────
echo
info "═══ smoke-test ═══"

echo
info "контейнеры:"
docker ps --format '  {{.Names}}\t{{.Status}}' | sort

echo
info "БД:"
DB_ROOT_PASS="$(cat "${STACK_DIR}/secrets/db_root_password.txt" 2>/dev/null || echo "")"
if [[ -n "$DB_ROOT_PASS" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${STACK_DIR}/.env"
  set +a
  DB_NAME="${MYSQL_DATABASE:-cashback_db}"
  if posts=$(docker exec -e MYSQL_PWD="$DB_ROOT_PASS" mariadb mariadb -u root -N -e \
       "SELECT COUNT(*) FROM ${DB_NAME}.wp_posts" 2>/dev/null); then
    log "wp_posts: ${posts} записей"
  else
    warn "не удалось прочитать wp_posts — проверьте логи mariadb"
  fi
else
  warn "secrets/db_root_password.txt не найден — пропускаю проверку БД"
fi

echo
info "webhook-receiver volume:"
if docker volume inspect "$WEBHOOK_VOL" >/dev/null 2>&1; then
  log "${WEBHOOK_VOL} существует"
  if docker exec webhook-receiver test -f /data/config.json 2>/dev/null; then
    log "/data/config.json на месте"
  else
    warn "/data/config.json не найден внутри webhook-receiver"
  fi
else
  warn "${WEBHOOK_VOL} не найден"
fi

# Возраст бэкапа — для контекста
if [[ -f "${BACKUP_DIR}/db.sql.gz" ]]; then
  backup_age_days=$(( ( $(date +%s) - $(stat -c %Y "${BACKUP_DIR}/db.sql.gz") ) / 86400 ))
  echo
  info "возраст данных в бэкапе: ${backup_age_days} дн."
fi

echo
log "deploy завершён"
echo
info "следующий шаг (если впервые на этом сервере):"
echo "    sudo bash ${STACK_DIR}/scripts/setup-cron.sh"
echo
info "проверка снаружи:"
echo "    curl -sk https://<домен>/wp-login.php | head"
