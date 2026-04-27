#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════
# Быстрое восстановление обоих стеков из бэкапа,
# созданного scripts/backup-all.sh.
#
# Перед началом интерактивно спрашивает имена папок (можно
# короткое имя относительно ${ROOT_DIR} или абсолютный путь).
# Дефолты — из cashback.env или autodetect.
#
# Запуск:   sudo bash /home/igor/restore-all.sh /opt/backups/<timestamp>
# ═══════════════════════════════════════════════════════════

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Если STACK_DIR пришёл из caller-окружения (например, deploy-from-backup.sh) —
# не загружаем cashback.env и не делаем unset, иначе затрём явно переданные пути.
PATHS_FROM_CALLER=0
if [[ -n "${STACK_DIR:-}" ]]; then
  PATHS_FROM_CALLER=1
fi

if (( PATHS_FROM_CALLER == 0 )); then
  # cashback.env — только дефолты для prompts.
  if [[ -f "${ROOT_DIR}/cashback.env" ]]; then
    set -a; source "${ROOT_DIR}/cashback.env"; set +a
  fi
  DEFAULT_STACK_DIR="${STACK_DIR:-}"
  DEFAULT_WEBHOOK_DIR="${WEBHOOK_DIR:-}"
  DEFAULT_STACK_PROJECT="${STACK_PROJECT:-}"
  DEFAULT_WEBHOOK_PROJECT="${WEBHOOK_PROJECT:-}"
  DEFAULT_WEBHOOK_VOL="${WEBHOOK_VOL:-}"
  unset STACK_DIR WEBHOOK_DIR STACK_PROJECT WEBHOOK_PROJECT WEBHOOK_VOL
fi

WAIT_HEALTHY_TIMEOUT=240
WAIT_HEALTHY_INTERVAL=3

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[1;33m'; CYN=$'\033[0;36m'; NC=$'\033[0m'
log()  { printf '%s[✓]%s %s\n' "$GRN" "$NC" "$*"; }
warn() { printf '%s[!]%s %s\n' "$YLW" "$NC" "$*"; }
err()  { printf '%s[✗]%s %s\n' "$RED" "$NC" "$*" >&2; }
info() { printf '%s[i]%s %s\n' "$CYN" "$NC" "$*"; }

# ─── Helpers ────────────────────────────────────────────────
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
autodetect_stack() {
  local c
  for c in service site site1 stack wordpress wp cashback; do
    [[ -d "${ROOT_DIR}/${c}" ]] && { printf '%s' "$c"; return; }
  done
}
autodetect_webhook() {
  local c
  for c in postback webhook-receiver webhook hooks; do
    [[ -d "${ROOT_DIR}/${c}" ]] && { printf '%s' "$c"; return; }
  done
}
ensure_env_var() {
  local file="$1" key="$2" val="$3"
  if [[ -f "$file" ]] && grep -qE "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  else
    printf '\n# auto-set by restore-all.sh — путь к .env stack для SMTP в worker\n%s=%s\n' "$key" "$val" >> "$file"
  fi
}
containers_healthy() {
  local n s h
  for n in "$@"; do
    s="$(docker inspect -f '{{.State.Status}}' "$n" 2>/dev/null || echo missing)"
    [[ "$s" == "running" ]] || return 1
    h="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$n" 2>/dev/null || echo none)"
    [[ "$h" == "healthy" || "$h" == "none" ]] || return 1
  done
}
wait_healthy() {
  local e=0; info "жду healthy: $* (timeout ${WAIT_HEALTHY_TIMEOUT}s)"
  while ! containers_healthy "$@"; do
    (( e >= WAIT_HEALTHY_TIMEOUT )) && { err "таймаут healthy: $*"; return 1; }
    sleep "$WAIT_HEALTHY_INTERVAL"; e=$(( e + WAIT_HEALTHY_INTERVAL ))
  done
  log "healthy: $*"
}

# ─── Аргументы ──────────────────────────────────────────────
BACKUP_DIR="${1:-}"
[[ -n "$BACKUP_DIR" ]] || { err "укажите путь к папке бэкапа: $0 /opt/backups/<timestamp>"; exit 1; }
[[ -d "$BACKUP_DIR" ]] || { err "папка бэкапа не существует: $BACKUP_DIR"; exit 1; }
BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"

# ─── Pre-flight ─────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { err "запуск только от root: sudo bash $0 $BACKUP_DIR"; exit 1; }
command -v docker >/dev/null || { err "docker не найден"; exit 1; }
docker compose version >/dev/null 2>&1 || { err "docker compose v2 не найден"; exit 1; }

# ─── Валидация архивов ──────────────────────────────────────
need_files=(db.sql.gz stack-configs.tar.gz webhook-configs.tar.gz webhook-app_data.tar.gz)
for f in "${need_files[@]}"; do
  [[ -f "${BACKUP_DIR}/${f}" ]] || { err "в бэкапе отсутствует: ${f}"; exit 1; }
done
HAS_WP_FILES=0
WP_ARCHIVE=""
WP_ARCHIVE_KIND=""   # "full" — весь /var/www/html; "content-only" — только wp-content (legacy)
if [[ -f "${BACKUP_DIR}/wordpress-files.tar.gz" ]]; then
  HAS_WP_FILES=1
  WP_ARCHIVE="${BACKUP_DIR}/wordpress-files.tar.gz"
  WP_ARCHIVE_KIND="full"
elif [[ -f "${BACKUP_DIR}/wp-content.tar.gz" ]]; then
  HAS_WP_FILES=1
  WP_ARCHIVE="${BACKUP_DIR}/wp-content.tar.gz"
  WP_ARCHIVE_KIND="content-only"
fi

HAS_GRAFANA_DATA=0
[[ -f "${BACKUP_DIR}/grafana-data.tar.gz" ]] && HAS_GRAFANA_DATA=1

if (( PATHS_FROM_CALLER == 1 )); then
  # Caller (deploy-from-backup.sh) уже определил абсолютные пути и project-имена.
  STACK_PROJECT="${STACK_PROJECT:-$(basename "$STACK_DIR")}"
  WEBHOOK_PROJECT="${WEBHOOK_PROJECT:-$(basename "$WEBHOOK_DIR")}"
  WEBHOOK_VOL="${WEBHOOK_VOL:-${WEBHOOK_PROJECT}_app_data}"
  GRAFANA_VOL="${GRAFANA_VOL:-${STACK_PROJECT}_grafana_data}"
else
  # ─── Интерактивный выбор папок ──────────────────────────────
  echo
  info "Куда восстанавливать стеки?"
  info "Введите имя папки (искать в ${ROOT_DIR}) или абсолютный путь."
  info "Папки могут не существовать — будут созданы при распаковке."

  stack_default="${DEFAULT_STACK_DIR:+$(basename "$DEFAULT_STACK_DIR")}"
  stack_default="${stack_default:-$(autodetect_stack)}"
  stack_default="${stack_default:-service}"
  stack_input=$(ask "  папка stack (WordPress + MariaDB)" "$stack_default")
  STACK_DIR=$(resolve_dir "$stack_input")

  webhook_default="${DEFAULT_WEBHOOK_DIR:+$(basename "$DEFAULT_WEBHOOK_DIR")}"
  webhook_default="${webhook_default:-$(autodetect_webhook)}"
  webhook_default="${webhook_default:-postback}"
  webhook_input=$(ask "  папка webhook-receiver" "$webhook_default")
  WEBHOOK_DIR=$(resolve_dir "$webhook_input")

  # Project names и WEBHOOK_VOL — из cashback.env, если задано, иначе basename.
  # ВАЖНО: для уже работающих installs project name должен совпадать с префиксом
  # существующих named volumes (docker volume ls | grep _vm_data).
  STACK_PROJECT="${DEFAULT_STACK_PROJECT:-$(basename "$STACK_DIR")}"
  WEBHOOK_PROJECT="${DEFAULT_WEBHOOK_PROJECT:-$(basename "$WEBHOOK_DIR")}"
  WEBHOOK_VOL="${DEFAULT_WEBHOOK_VOL:-${WEBHOOK_PROJECT}_app_data}"
  GRAFANA_VOL="${GRAFANA_VOL:-${STACK_PROJECT}_grafana_data}"
fi

dc_stack()   { docker compose --project-directory "$STACK_DIR"   -f "${STACK_DIR}/docker-compose.yml"   -p "$STACK_PROJECT"   "$@"; }
dc_webhook() { docker compose --project-directory "$WEBHOOK_DIR" -f "${WEBHOOK_DIR}/docker-compose.yml" -p "$WEBHOOK_PROJECT" "$@"; }

echo
info "восстановление из:   ${BACKUP_DIR}"
info "STACK_DIR:           ${STACK_DIR}    (project: ${STACK_PROJECT})"
info "WEBHOOK_DIR:         ${WEBHOOK_DIR}  (project: ${WEBHOOK_PROJECT})"
info "WEBHOOK_VOL:         ${WEBHOOK_VOL}"
info "GRAFANA_VOL:         ${GRAFANA_VOL}$( ((HAS_GRAFANA_DATA)) || echo '  (бэкапа нет — пропуск)')"
echo
warn "ОПЕРАЦИЯ ПЕРЕЗАПИШЕТ:"
warn "  - содержимое ${STACK_DIR}/ и ${WEBHOOK_DIR}/ (configs, secrets, wp-content)"
warn "  - БД в MariaDB"
warn "  - docker volume ${WEBHOOK_VOL} (будет удалён и пересоздан)"
echo
if [[ "${RESTORE_CONFIRMED:-0}" == "1" ]]; then
  info "RESTORE_CONFIRMED=1 — non-interactive режим, prompt пропущен"
else
  read -rp "введите 'RESTORE' для подтверждения: " ans
  [[ "$ans" == "RESTORE" ]] || { info "отмена"; exit 0; }
fi

# ─── 1. Стопаем стеки (если запущены) ───────────────────────
info "останавливаю стеки (volumes сохраняются)"
[[ -f "${WEBHOOK_DIR}/docker-compose.yml" ]] && dc_webhook down --remove-orphans 2>/dev/null || true
[[ -f "${STACK_DIR}/docker-compose.yml"   ]] && dc_stack   down --remove-orphans 2>/dev/null || true

# ─── 2. Конфиги stack ───────────────────────────────────────
info "распаковка stack-configs.tar.gz → ${STACK_DIR}/"
mkdir -p "$STACK_DIR"
tar xzf "${BACKUP_DIR}/stack-configs.tar.gz" -C "$STACK_DIR" --same-owner --same-permissions

# ─── 3. Конфиги webhook ─────────────────────────────────────
info "распаковка webhook-configs.tar.gz → ${WEBHOOK_DIR}/"
mkdir -p "$WEBHOOK_DIR"
tar xzf "${BACKUP_DIR}/webhook-configs.tar.gz" -C "$WEBHOOK_DIR" --same-owner --same-permissions

# Перепривязка SMTP worker'а (в бэкапе мог лежать путь со старого хоста).
ensure_env_var "${WEBHOOK_DIR}/.env" SMTP_ENV_FILE "${STACK_DIR}/.env"
log "SMTP_ENV_FILE в ${WEBHOOK_DIR}/.env → ${STACK_DIR}/.env"

ensure_env_var "${WEBHOOK_DIR}/.env" SMTP_PASSWORD_FILE_HOST "${STACK_DIR}/secrets/smtp_password.txt"
log "SMTP_PASSWORD_FILE_HOST в ${WEBHOOK_DIR}/.env → ${STACK_DIR}/secrets/smtp_password.txt"

# ─── 4. WordPress files (опционально) ───────────────────────
if (( HAS_WP_FILES )); then
  WP_ROOT="${STACK_DIR}/volumes/wordpress"
  mkdir -p "$WP_ROOT"
  if [[ -d "${WP_ROOT}/wp-content" ]]; then
    BACKUP_OLD="${WP_ROOT}/wp-content.before-restore-$(date +%Y%m%d_%H%M%S)"
    warn "сохраняю существующий wp-content → ${BACKUP_OLD}"
    mv "${WP_ROOT}/wp-content" "$BACKUP_OLD"
  fi

  if [[ "$WP_ARCHIVE_KIND" == "full" ]]; then
    info "распаковка wordpress-files.tar.gz → ${WP_ROOT}/ (полное ядро WP)"
  else
    warn "найден старый формат wp-content.tar.gz — ядро WP будет докопировано из образа (Hello Dolly/Akismet могут вернуться)"
    info "распаковка wp-content.tar.gz → ${WP_ROOT}/"
  fi
  tar xzf "$WP_ARCHIVE" -C "$WP_ROOT" --same-owner --same-permissions

  # Стандартный tar не сохраняет POSIX ACL — переприменяем после распаковки.
  if [[ -x "${STACK_DIR}/scripts/fix-wp-perms.sh" ]]; then
    info "переприменение прав и ACL на ${WP_ROOT} (fix-wp-perms.sh)"
    REAL_USER_OVERRIDE="${SUDO_USER:-root}" \
      bash "${STACK_DIR}/scripts/fix-wp-perms.sh" "${WP_ROOT}"
  else
    warn "${STACK_DIR}/scripts/fix-wp-perms.sh не найден — ACL не переприменены"
  fi
fi

# ─── 5. Пересоздание webhook volume ─────────────────────────
info "пересоздание volume ${WEBHOOK_VOL}"
docker volume rm "$WEBHOOK_VOL" 2>/dev/null || true
docker volume create "$WEBHOOK_VOL" >/dev/null
docker run --rm \
  -v "${WEBHOOK_VOL}:/data" \
  -v "${BACKUP_DIR}:/b:ro" \
  alpine:3.20 \
  sh -c "tar xzf /b/webhook-app_data.tar.gz -C /data" >/dev/null
log "${WEBHOOK_VOL} восстановлен"

# ─── 5b. Пересоздание grafana volume (если есть в бэкапе) ───
# Делаем до dc_stack up, чтобы grafana стартовала уже с данными.
if (( HAS_GRAFANA_DATA )); then
  info "пересоздание volume ${GRAFANA_VOL}"
  docker volume rm "$GRAFANA_VOL" 2>/dev/null || true
  docker volume create "$GRAFANA_VOL" >/dev/null
  docker run --rm \
    -v "${GRAFANA_VOL}:/data" \
    -v "${BACKUP_DIR}:/b:ro" \
    alpine:3.20 \
    sh -c "tar xzf /b/grafana-data.tar.gz -C /data" >/dev/null
  log "${GRAFANA_VOL} восстановлен"
else
  warn "grafana-data.tar.gz нет в бэкапе — Grafana стартует с пустым volume; пароль admin будет применён из secrets/"
fi

# ─── 6. Сети ────────────────────────────────────────────────
for net in proxy db-shared; do
  docker network inspect "$net" >/dev/null 2>&1 || { docker network create "$net" >/dev/null; log "сеть $net создана"; }
done

# ─── 7. Поднимаем только mariadb для restore БД ─────────────
info "стартую mariadb"
dc_stack up -d mariadb
wait_healthy mariadb || { err "mariadb не стартовала — проверьте secrets/db_root_password.txt"; exit 1; }

# ─── 8. Restore БД ──────────────────────────────────────────
DB_ROOT_PASS="$(cat "${STACK_DIR}/secrets/db_root_password.txt" 2>/dev/null || echo "")"
[[ -n "$DB_ROOT_PASS" ]] || { err "пустой ${STACK_DIR}/secrets/db_root_password.txt"; exit 1; }

set -a; source "${STACK_DIR}/.env"; set +a
DB_NAME="${MYSQL_DATABASE:-cashback_db}"

info "восстановление БД ${DB_NAME} из db.sql.gz"
zcat "${BACKUP_DIR}/db.sql.gz" | \
  docker exec -i -e MYSQL_PWD="$DB_ROOT_PASS" mariadb \
  mariadb -u root "$DB_NAME"
log "БД восстановлена"

# ─── 9. Поднимаем весь stack ────────────────────────────────
info "стартую остальной stack"
dc_stack up -d
wait_healthy mariadb redis || { err "stack не вышел в healthy"; exit 1; }

# ─── 9a. Синхронизировать пароль mysqld-exporter с .env ─────
# Если volume mariadb пересоздавался (полный teardown), grants.sql
# создаёт 'exporter'@% с placeholder-паролем 'changeme_set_by_install'.
# setup-mariadb-users.sh поднимает реальный из .env и пересоздаёт exporter.
if [[ -x "${STACK_DIR}/scripts/setup-mariadb-users.sh" ]]; then
  info "синхронизация пароля mysqld-exporter с .env"
  if bash "${STACK_DIR}/scripts/setup-mariadb-users.sh" >/dev/null 2>&1; then
    log "пароль 'exporter'@% синхронизирован, mysqld-exporter пересоздан"
  else
    warn "setup-mariadb-users.sh завершился с ошибкой — exporter может выдавать Access denied"
    warn "запусти вручную: sudo bash ${STACK_DIR}/scripts/setup-mariadb-users.sh"
  fi
else
  warn "${STACK_DIR}/scripts/setup-mariadb-users.sh не найден — пароль exporter может не совпадать с .env"
fi

# ─── 9b. Синхронизировать пароль Grafana с secrets ──────────
# Если grafana-data из бэкапа — пароль уже совпадает (там же лежит).
# Если volume пустой (нет в бэкапе) — Grafana создаёт admin/admin,
# а secrets/grafana_admin_password.txt содержит другое значение.
# В обоих случаях reset-admin-password идемпотентен и безопасен.
if [[ -f "${STACK_DIR}/secrets/grafana_admin_password.txt" ]]; then
  info "синхронизация пароля Grafana admin с secrets/"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if docker exec grafana sh -c \
        'grafana-cli admin reset-admin-password "$(cat /run/secrets/grafana_admin_password)"' \
        >/dev/null 2>&1; then
      log "пароль Grafana admin установлен из secrets/grafana_admin_password.txt"
      break
    fi
    sleep 2
  done
else
  warn "secrets/grafana_admin_password.txt не найден — пропускаю синхронизацию пароля Grafana"
fi

# ─── 10. Поднимаем webhook ──────────────────────────────────
info "стартую webhook-receiver"
dc_webhook up -d

echo
log "восстановление завершено"
info "проверка: docker ps --format '{{.Names}}\\t{{.Status}}'"
