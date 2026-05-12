#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════
# Быстрая установка С НУЛЯ обоих стеков.
# Перед началом интерактивно спрашивает имена папок:
#   - короткое имя (например "site") → ищется в ${ROOT_DIR}
#   - абсолютный путь (например "/srv/wp") → используется как есть
# Дефолты берутся из cashback.env (если есть) или auto-detect соседей.
#
# Запуск:   sudo bash /home/igor/install-all.sh
# ═══════════════════════════════════════════════════════════

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# cashback.env — только источник ДЕФОЛТОВ для prompts (не финальные значения).
if [[ -f "${ROOT_DIR}/cashback.env" ]]; then
  set -a; source "${ROOT_DIR}/cashback.env"; set +a
fi
DEFAULT_STACK_DIR="${STACK_DIR:-}"
DEFAULT_WEBHOOK_DIR="${WEBHOOK_DIR:-}"
unset STACK_DIR WEBHOOK_DIR

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

# Имя без / → сиблинг ROOT_DIR; абсолютный путь → как есть.
resolve_dir() {
  local v="$1"; v="${v%/}"
  if [[ "$v" == /* ]]; then printf '%s' "$v"; else printf '%s' "${ROOT_DIR}/${v}"; fi
}

# Авто-детект имён соседних папок с install.sh — для дефолта prompt.
autodetect_stack() {
  local c
  for c in service site site1 stack wordpress wp cashback; do
    [[ -f "${ROOT_DIR}/${c}/install.sh" ]] && { printf '%s' "$c"; return; }   # -f, executable-бит не нужен
  done
}
autodetect_webhook() {
  local c
  for c in postback webhook-receiver webhook hooks; do
    [[ -f "${ROOT_DIR}/${c}/install.sh" ]] && { printf '%s' "$c"; return; }   # -f, executable-бит не нужен
  done
}

# ─── Pre-flight ─────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { err "запуск только от root: sudo bash $0"; exit 1; }
command -v docker >/dev/null || { err "docker не найден"; exit 1; }
docker compose version >/dev/null 2>&1 || { err "docker compose v2 не найден"; exit 1; }

# ─── Интерактивный выбор папок ──────────────────────────────
echo
info "Где лежат стеки? Введите имя папки (искать в ${ROOT_DIR}) или абсолютный путь."

stack_default="${DEFAULT_STACK_DIR:+$(basename "$DEFAULT_STACK_DIR")}"
stack_default="${stack_default:-$(autodetect_stack)}"
stack_input=$(ask "  папка stack (WordPress + MariaDB)" "$stack_default")
STACK_DIR=$(resolve_dir "$stack_input")

webhook_default="${DEFAULT_WEBHOOK_DIR:+$(basename "$DEFAULT_WEBHOOK_DIR")}"
webhook_default="${webhook_default:-$(autodetect_webhook)}"
webhook_input=$(ask "  папка webhook-receiver (приём постбэков)" "$webhook_default")
WEBHOOK_DIR=$(resolve_dir "$webhook_input")

# Project names = basename(dir), если cashback.env явно их не задал.
STACK_PROJECT="${STACK_PROJECT:-$(basename "$STACK_DIR")}"
WEBHOOK_PROJECT="${WEBHOOK_PROJECT:-$(basename "$WEBHOOK_DIR")}"

echo
info "STACK_DIR    = ${STACK_DIR}    (project: ${STACK_PROJECT})"
info "WEBHOOK_DIR  = ${WEBHOOK_DIR}  (project: ${WEBHOOK_PROJECT})"

# Папки должны уже существовать (стеки скопированы), внутри — install.sh.
# Проверяем -f, а не -x: вызываем через `bash install.sh`, executable-бит не нужен
# (часто отсутствует после копирования с Windows / FAT / unzip).
[[ -f "${STACK_DIR}/install.sh"   ]] || { err "не найден ${STACK_DIR}/install.sh — скопируйте папку стека сначала"; exit 1; }
[[ -f "${WEBHOOK_DIR}/install.sh" ]] || { err "не найден ${WEBHOOK_DIR}/install.sh — скопируйте папку webhook сначала"; exit 1; }

# ─── Healthcheck-helpers ────────────────────────────────────
containers_healthy() {
  local name state health
  for name in "$@"; do
    state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)"
    [[ "$state" == "running" ]] || return 1
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null || echo none)"
    [[ "$health" == "healthy" || "$health" == "none" ]] || return 1
  done
}
wait_healthy() {
  local elapsed=0
  info "жду healthy: $* (timeout ${WAIT_HEALTHY_TIMEOUT}s)"
  while ! containers_healthy "$@"; do
    if (( elapsed >= WAIT_HEALTHY_TIMEOUT )); then
      err "таймаут ожидания healthy для: $*"
      for c in "$@"; do
        docker inspect -f "  {{.Name}}: state={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}" "$c" 2>/dev/null || echo "  $c: missing"
      done
      return 1
    fi
    sleep "$WAIT_HEALTHY_INTERVAL"
    elapsed=$(( elapsed + WAIT_HEALTHY_INTERVAL ))
  done
  log "healthy: $*"
}

# ─── 1. Сети ────────────────────────────────────────────────
for net in proxy db-shared; do
  docker network inspect "$net" >/dev/null 2>&1 || { docker network create "$net" >/dev/null; log "сеть $net создана"; }
done

# ─── 2. Установка stack ─────────────────────────────────────
info "═══ установка stack: ${STACK_DIR} ═══"
( cd "$STACK_DIR" && bash install.sh )

# ─── 3. Ждём healthy ────────────────────────────────────────
wait_healthy mariadb redis || { err "stack не вышел в healthy — не запускаю webhook-receiver"; exit 1; }

# ─── 4. Установка webhook-receiver ──────────────────────────
# SMTP_ENV_FILE / SMTP_PASSWORD_FILE_HOST через env-var: install.sh видит preset → не задаёт вопрос.
info "═══ установка webhook-receiver: ${WEBHOOK_DIR} ═══"
( cd "$WEBHOOK_DIR" \
  && SMTP_ENV_FILE="${STACK_DIR}/.env" \
     SMTP_PASSWORD_FILE_HOST="${STACK_DIR}/secrets/smtp_password.txt" \
     bash install.sh )

echo
log "оба стека установлены и запущены"
